//
// Copyright (c) 2019-2025 Red Hat, Inc.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import http from 'k6/http';
import {sleep} from 'k6';
import {Trend, Counter, Gauge} from 'k6/metrics';
import {htmlReport} from "https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js";
import {textSummary} from "https://jslib.k6.io/k6-summary/0.0.1/index.js";
import {
  getDevWorkspacesFromApiServer,
  createAuthHeaders,
  detectClusterType,
  checkDevWorkspaceOperatorMetrics,
  checkEtcdMetrics,
  createFilteredSummaryData,
} from '../../common/utils.js';

const inCluster = __ENV.IN_CLUSTER === 'true';
const apiServer = inCluster ? `https://kubernetes.default.svc` : __ENV.KUBE_API;
const token = inCluster ? open('/var/run/secrets/kubernetes.io/serviceaccount/token') : __ENV.KUBE_TOKEN;
const useSeparateNamespaces = __ENV.SEPARATE_NAMESPACES === "true";
const operatorNamespace = __ENV.DWO_NAMESPACE || 'openshift-operators';
const loadTestNamespace = __ENV.LOAD_TEST_NAMESPACE || "loadtest-devworkspaces";
const backupMonitorDurationMinutes = Number(__ENV.BACKUP_MONITOR_DURATION_MINUTES || 30);
const dwocConfigType = __ENV.DWOC_CONFIG_TYPE || 'correct';
const verifyRestore = __ENV.VERIFY_RESTORE !== 'false'; // Default to true, can be disabled with VERIFY_RESTORE=false
const maxRestoreSamples = Number(__ENV.MAX_RESTORE_SAMPLES || 10); // Maximum number of workspaces to restore for verification
const backupJobLabel = "controller.devfile.io/backup-job=true";
let ETCD_NAMESPACE = 'openshift-etcd';
let ETCD_POD_NAME_PATTERN = 'etcd';
const ETCD_POD_SELECTOR = `app=${ETCD_POD_NAME_PATTERN}`;
const OPERATOR_POD_SELECTOR = 'app.kubernetes.io/name=devworkspace-controller';
const monitorPollInterval = 10; // seconds between monitoring polls

// Parse initial restart counts from environment variables
const initialEtcdRestarts = __ENV.INITIAL_ETCD_RESTARTS ? JSON.parse(__ENV.INITIAL_ETCD_RESTARTS) : {};
const initialOperatorRestarts = __ENV.INITIAL_OPERATOR_RESTARTS ? JSON.parse(__ENV.INITIAL_OPERATOR_RESTARTS) : {};

const headers = createAuthHeaders(token);

export const options = {
  scenarios: {
    backup_load_test: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      maxDuration: `${backupMonitorDurationMinutes + 30}m`,
      exec: 'runBackupLoadTest',
    },
  },
  thresholds: {
    'backup_jobs_total': ['count>0'],
    'backup_jobs_succeeded': dwocConfigType === 'incorrect' ? [] : ['count>0'],
    'backup_jobs_failed': dwocConfigType === 'incorrect' ? ['count>0'] : ['count==0'],
    'backup_pods_total': ['count>0'],
    'workspaces_stopped': ['count>0'],
    'workspaces_backed_up': dwocConfigType === 'incorrect' ? [] : ['count>0'],
    'backup_success_rate': dwocConfigType === 'incorrect' ? [] : ['value>=0.95'],
    // Restore thresholds only apply for correct/openshift-internal modes
    'restore_workspaces_total': dwocConfigType === 'incorrect' || !verifyRestore ? [] : ['count>0'],
    'restore_workspaces_succeeded': dwocConfigType === 'incorrect' || !verifyRestore ? [] : ['count>0'],
    'restore_workspaces_failed': dwocConfigType === 'incorrect' || !verifyRestore ? [] : ['count==0'],
    'restore_success_rate': dwocConfigType === 'incorrect' || !verifyRestore ? [] : ['value>=0.95'],
    'operator_cpu_violations': ['count==0'],
    'operator_mem_violations': ['count==0'],
  },
  insecureSkipTLSVerify: true,
};

// Metrics
const backupJobsTotal = new Counter('backup_jobs_total');
const backupJobsSucceeded = new Counter('backup_jobs_succeeded');
const backupJobsFailed = new Counter('backup_jobs_failed');
const backupJobsRunning = new Gauge('backup_jobs_running');
const backupPodsTotal = new Counter('backup_pods_total');
const workspacesStopped = new Counter('workspaces_stopped');
const workspacesBackedUp = new Counter('workspaces_backed_up');
const backupSuccessRate = new Gauge('backup_success_rate');
const backupJobDuration = new Trend('backup_job_duration');
const imageStreamsCreated = new Counter('imagestreams_created');
const imageStreamsExpected = new Counter('imagestreams_expected');
const operatorCpu = new Trend('average_operator_cpu');
const operatorMemory = new Trend('average_operator_memory');
const etcdCpu = new Trend('average_etcd_cpu');
const etcdMemory = new Trend('average_etcd_memory');
const operatorCpuViolations = new Counter('operator_cpu_violations');
const operatorMemViolations = new Counter('operator_mem_violations');
const operatorPodRestarts = new Gauge('operator_pod_restarts_total');
const etcdPodRestarts = new Gauge('etcd_pod_restarts_total');

// Restore verification metrics
const restoreWorkspacesTotal = new Counter('restore_workspaces_total');
const restoreWorkspacesSucceeded = new Counter('restore_workspaces_succeeded');
const restoreWorkspacesFailed = new Counter('restore_workspaces_failed');
const restoreDuration = new Trend('restore_duration');
const restoreSuccessRate = new Gauge('restore_success_rate');

const maxCpuMillicores = 250;
const maxMemoryBytes = 200 * 1024 * 1024;

export function setup() {
  const clusterInfo = detectClusterType(apiServer, headers);
  ETCD_NAMESPACE = clusterInfo.etcdNamespace;
  ETCD_POD_NAME_PATTERN = clusterInfo.etcdPodPattern;

  return {
    startTime: Date.now(),
  };
}

export function runBackupLoadTest(data) {
  console.log("\n======================================");
  console.log("Backup Load Test - Using Existing Workspaces");
  console.log("======================================\n");

  // Stop workspaces and monitor backups
  const backedUpWorkspaces = stopWorkspacesAndMonitorBackups(data);

  // Restore verification (if enabled and workspaces were backed up)
  if (verifyRestore) {
    // Don't attempt restore in incorrect mode - backups intentionally failed
    if (dwocConfigType === 'incorrect') {
      console.log("\nℹ️  Restore verification skipped - DWOC config type is 'incorrect' (backups intentionally failed)");
    } else if (backedUpWorkspaces.length > 0) {
      console.log("\n======================================");
      console.log("Restore Verification");
      console.log("======================================\n");
      verifyWorkspaceRestore(backedUpWorkspaces);
    } else {
      console.warn("\n⚠️  No workspaces were successfully backed up - skipping restore verification");
    }
  } else {
    console.log("\nℹ️  Restore verification is disabled (VERIFY_RESTORE=false)");
  }
}

function stopWorkspacesAndMonitorBackups(data) {
  // Step 1: Get all DevWorkspaces
  console.log("Step 1: Discovering existing DevWorkspaces...");
  const devWorkspaces = getAllDevWorkspaces();
  console.log(`Found ${devWorkspaces.length} DevWorkspaces\n`);

  if (devWorkspaces.length === 0) {
    const errorMsg = "No DevWorkspaces found. Workspaces should have been created in Phase 2.";
    console.error(errorMsg);
    throw new Error(errorMsg);
  }

  // Step 2: Stop all workspaces
  console.log("Step 2: Stopping all DevWorkspaces...");
  const stoppedCount = stopAllDevWorkspaces(devWorkspaces);
  workspacesStopped.add(stoppedCount);
  console.log(`Stopped ${stoppedCount} DevWorkspaces\n`);

  // Wait for workspaces to actually stop
  console.log("Waiting 30 seconds for workspaces to stop...");
  sleep(30);

  // Step 3: Wait for backup jobs to be created
  console.log("\nStep 3: Waiting for backup Jobs to be created...");
  const jobsCreated = waitForBackupJobsCreation(10, 10);
  if (!jobsCreated) {
    console.warn("No backup Jobs were created - backup may not be configured correctly");
    console.warn("Continuing to monitor anyway...\n");
  }

  // Step 4: Monitor backup jobs and operator/etcd metrics
  console.log("\nStep 4: Monitoring backup Jobs and system metrics...");
  monitorBackupJobsAndMetrics(backupMonitorDurationMinutes);

  // Step 5: Verify all workspaces were backed up
  console.log("\nStep 5: Verifying backup coverage...");
  const backedUpWorkspaces = verifyBackupCoverage(devWorkspaces);

  // Step 6: Final metrics collection
  console.log("\nStep 6: Collecting final metrics...");
  collectFinalMetrics();

  console.log("\n======================================");
  console.log("Backup Monitoring Completed");
  console.log("======================================\n");

  // Return list of backed up workspaces for restore verification
  return backedUpWorkspaces;
}

function getAllDevWorkspaces() {
  const result = getDevWorkspacesFromApiServer(apiServer, loadTestNamespace, headers, useSeparateNamespaces);

  if (result.error) {
    console.error(`Failed to get DevWorkspaces: ${result.error}`);
    return [];
  }

  return result.devWorkspaces || [];
}

function stopAllDevWorkspaces(devWorkspaces) {
  let stoppedCount = 0;

  for (const dw of devWorkspaces) {
    const namespace = dw.metadata.namespace;
    const name = dw.metadata.name;

    // Skip if already stopped
    if (!dw.spec?.started) {
      continue;
    }

    // Patch DevWorkspace to set started=false
    const patchUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces/${name}`;
    const patchPayload = JSON.stringify({
      spec: {
        started: false
      }
    });

    const mergeHeaders = createAuthHeaders(token, 'application/merge-patch+json');
    const res = http.patch(patchUrl, patchPayload, {headers: mergeHeaders});

    if (res.status === 200) {
      stoppedCount++;
    } else {
      console.warn(`  Failed to stop ${namespace}/${name}: ${res.status}`);
    }
  }

  return stoppedCount;
}

function waitForBackupJobsCreation(maxWaitMinutes, pollIntervalSeconds) {
  const maxAttempts = (maxWaitMinutes * 60) / pollIntervalSeconds;
  let attempts = 0;

  while (attempts < maxAttempts) {
    const jobs = getBackupJobs();

    if (jobs.length > 0) {
      console.log(`Backup Jobs created: ${jobs.length} found`);
      return true;
    }

    sleep(pollIntervalSeconds);
    attempts++;
  }

  return false;
}

function getBackupJobs() {
  const jobsUrl = `${apiServer}/apis/batch/v1/jobs?labelSelector=${encodeURIComponent(backupJobLabel)}`;
  const res = http.get(jobsUrl, {headers});

  if (res.status !== 200) {
    console.warn(`Failed to get backup Jobs: ${res.status}`);
    return [];
  }

  const data = JSON.parse(res.body);
  return data.items || [];
}

function getBackupJobMetrics() {
  const jobs = getBackupJobs();

  let succeeded = 0;
  let failed = 0;
  let running = 0;
  let totalPods = 0;

  for (const job of jobs) {
    const status = job.status || {};
    const conditions = status.conditions || [];

    // Check if job has succeeded
    if (status.succeeded === 1) {
      succeeded++;
    }
    // Check if job has permanently failed (hit backOffLimit)
    // A job is only permanently failed when it has a Failed condition
    else if (conditions.some(c => c.type === 'Failed' && c.status === 'True')) {
      failed++;
    }
    // Otherwise the job is still running/pending (may be retrying after pod failures)
    else {
      running++;
    }

    // Track pods created by this job
    const activePods = status.active || 0;
    const succeededPods = status.succeeded || 0;
    const failedPods = status.failed || 0;
    totalPods += activePods + succeededPods + failedPods;
  }

  return {
    total: jobs.length,
    succeeded,
    failed,
    running,
    totalPods,
    jobs,
  };
}

function monitorBackupJobsAndMetrics(durationMinutes) {
  const endTime = Date.now() + (durationMinutes * 60 * 1000);
  let iteration = 0;
  let previousTotal = 0;
  let previousPods = 0;
  let lastLoggedStatus = "";

  while (Date.now() < endTime) {
    iteration++;
    const metrics = getBackupJobMetrics();

    // Update counters (track new jobs as they are created)
    if (metrics.total > previousTotal) {
      backupJobsTotal.add(metrics.total - previousTotal);
      previousTotal = metrics.total;
    }

    // Update counters (track new pods as they are created)
    if (metrics.totalPods > previousPods) {
      backupPodsTotal.add(metrics.totalPods - previousPods);
      previousPods = metrics.totalPods;
    }

    // Update gauges
    backupJobsRunning.add(metrics.running);

    // Calculate success rate
    if (metrics.total > 0) {
      const successRate = metrics.succeeded / metrics.total;
      backupSuccessRate.add(successRate);
    }

    // Log progress every 10 iterations (100 seconds) or when status changes
    const currentStatus = `${metrics.succeeded}/${metrics.failed}/${metrics.running}`;
    if (iteration % 10 === 0 || currentStatus !== lastLoggedStatus) {
      const remainingMinutes = Math.ceil((endTime - Date.now()) / 60000);
      console.log(`  [${iteration}] Jobs - Succeeded: ${metrics.succeeded}, Failed: ${metrics.failed}, Running: ${metrics.running}, Pods: ${metrics.totalPods} (${remainingMinutes}m remaining)`);
      lastLoggedStatus = currentStatus;
    }

    // Check operator and etcd metrics
    checkOperatorMetrics();
    checkSystemEtcdMetrics();

    // Check if all jobs are complete
    if (metrics.total > 0 && (metrics.succeeded + metrics.failed) >= metrics.total) {
      console.log("All backup Jobs have completed or permanently failed");

      // Record final counts
      backupJobsSucceeded.add(metrics.succeeded);
      backupJobsFailed.add(metrics.failed);

      break;
    }

    sleep(monitorPollInterval);
  }
}

function getImageStreams(namespace) {
  const url = useSeparateNamespaces
    ? `${apiServer}/apis/image.openshift.io/v1/imagestreams`
    : `${apiServer}/apis/image.openshift.io/v1/namespaces/${namespace}/imagestreams`;

  const res = http.get(url, {headers});

  if (res.status !== 200) {
    console.warn(`Failed to get ImageStreams: ${res.status}`);
    return [];
  }

  const data = JSON.parse(res.body);
  return data.items || [];
}

function verifyBackupCoverage(devWorkspaces) {
  const jobs = getBackupJobs();
  const backedUpWorkspaceIds = new Set();

  // Extract workspace IDs from backup job labels
  for (const job of jobs) {
    const labels = job.metadata?.labels || {};
    const workspaceId = labels['controller.devfile.io/devworkspace_id'];

    if (workspaceId && job.status?.succeeded === 1) {
      backedUpWorkspaceIds.add(workspaceId);
    }
  }

  // Build list of successfully backed up workspaces
  const backedUpWorkspaces = [];
  for (const dw of devWorkspaces) {
    // Use bracket notation for devworkspaceId
    const dwId = dw.status && dw.status['devworkspaceId'];
    if (dwId && backedUpWorkspaceIds.has(dwId)) {
      backedUpWorkspaces.push({
        name: dw.metadata.name,
        namespace: dw.metadata.namespace,
        workspaceId: dwId,
        originalSpec: dw.spec,
      });
    }
  }

  workspacesBackedUp.add(backedUpWorkspaces.length);

  console.log(`Backup Coverage: ${backedUpWorkspaces.length}/${devWorkspaces.length} workspaces backed up`);

  if (backedUpWorkspaces.length < devWorkspaces.length) {
    console.warn(`Warning: ${devWorkspaces.length - backedUpWorkspaces.length} workspaces were not backed up`);

    // List workspaces that weren't backed up
    for (const dw of devWorkspaces) {
      // Use bracket notation for devworkspaceId
      const dwId = dw.status && dw.status['devworkspaceId'];
      if (!dwId || !backedUpWorkspaceIds.has(dwId)) {
        console.warn(`  Not backed up: ${dw.metadata.namespace}/${dw.metadata.name} (ID: ${dwId || 'unknown'})`);
      }
    }
  }

  // Verify ImageStreams for OpenShift internal registry mode
  if (dwocConfigType === 'openshift-internal') {
    console.log("\nVerifying ImageStream creation for OpenShift internal registry...");
    verifyImageStreams(devWorkspaces, backedUpWorkspaceIds);
  }

  return backedUpWorkspaces;
}

function verifyImageStreams(devWorkspaces, backedUpWorkspaceIds) {
  const imageStreamsByNamespace = new Map();

  // Get ImageStreams from all relevant namespaces
  if (useSeparateNamespaces) {
    // Collect ImageStreams from all workspace namespaces
    for (const dw of devWorkspaces) {
      const namespace = dw.metadata.namespace;
      if (!imageStreamsByNamespace.has(namespace)) {
        const imageStreams = getImageStreams(namespace);
        imageStreamsByNamespace.set(namespace, imageStreams);
      }
    }
  } else {
    // Single namespace mode
    const imageStreams = getImageStreams(loadTestNamespace);
    imageStreamsByNamespace.set(loadTestNamespace, imageStreams);
  }

  // Verify each backed-up workspace has a corresponding ImageStream
  let imageStreamCount = 0;
  let expectedImageStreams = 0;

  for (const dw of devWorkspaces) {
    const dwId = dw.status && dw.status['devworkspaceId'];

    // Only check ImageStreams for successfully backed up workspaces
    if (!dwId || !backedUpWorkspaceIds.has(dwId)) {
      continue;
    }

    expectedImageStreams++;
    const namespace = dw.metadata.namespace;
    const dwName = dw.metadata.name;
    const imageStreams = imageStreamsByNamespace.get(namespace) || [];

    // Look for ImageStream matching the DevWorkspace
    // ImageStream name typically matches the DevWorkspace name or ID
    const matchingIS = imageStreams.find(is => {
      const isName = is.metadata.name;
      return isName === dwName || isName === dwId || isName.includes(dwName) || isName.includes(dwId);
    });

    if (matchingIS) {
      imageStreamCount++;
    } else {
      console.warn(`  ⚠️  No ImageStream found for ${namespace}/${dwName} (ID: ${dwId})`);
    }
  }

  imageStreamsCreated.add(imageStreamCount);
  imageStreamsExpected.add(expectedImageStreams);

  console.log(`\nImageStream Coverage: ${imageStreamCount}/${expectedImageStreams} ImageStreams created`);

  if (imageStreamCount < expectedImageStreams) {
    console.warn(`Warning: ${expectedImageStreams - imageStreamCount} ImageStreams are missing`);
  }
}

function collectFinalMetrics() {
  const metrics = getBackupJobMetrics();

  console.log("\n======================================");
  console.log("Final Backup Job Metrics");
  console.log("======================================");
  console.log(`Total Jobs: ${metrics.total}`);
  console.log(`Succeeded: ${metrics.succeeded}`);
  console.log(`Failed (hit backOffLimit): ${metrics.failed}`);
  console.log(`Running/Pending: ${metrics.running}`);
  console.log(`Total Pods Created: ${metrics.totalPods}`);

  if (metrics.total > 0) {
    const successRate = ((metrics.succeeded / metrics.total) * 100).toFixed(2);
    const failureRate = ((metrics.failed / metrics.total) * 100).toFixed(2);
    console.log(`Success Rate: ${successRate}%`);
    console.log(`Failure Rate: ${failureRate}%`);
  }
  console.log("======================================\n");

  // Show details of permanently failed jobs
  if (metrics.failed > 0) {
    console.log("Failed Jobs Details:");
    for (const job of metrics.jobs) {
      const conditions = job.status?.conditions || [];
      const failedCondition = conditions.find(c => c.type === 'Failed' && c.status === 'True');

      if (failedCondition) {
        const namespace = job.metadata.namespace;
        const name = job.metadata.name;
        const podFailures = job.status?.failed || 0;
        const reason = failedCondition.reason || 'Unknown';
        const message = failedCondition.message || 'No message';

        console.log(`  ❌ ${namespace}/${name}`);
        console.log(`     Pod failures: ${podFailures}, Reason: ${reason}`);
        console.log(`     Message: ${message}`);
      }
    }
    console.log("");
  }

  // Calculate backup job durations
  for (const job of metrics.jobs) {
    const startTime = job.status?.startTime;
    const completionTime = job.status?.completionTime;

    if (startTime && completionTime) {
      const start = new Date(startTime).getTime();
      const end = new Date(completionTime).getTime();
      const duration = end - start;
      backupJobDuration.add(duration);
    }
  }
}

function checkOperatorMetrics() {
  const metrics = {
    operatorCpu,
    operatorMemory,
    operatorCpuViolations,
    operatorMemViolations,
  };
  checkDevWorkspaceOperatorMetrics(apiServer, headers, operatorNamespace, maxCpuMillicores, maxMemoryBytes, metrics, operatorPodRestarts, OPERATOR_POD_SELECTOR, initialOperatorRestarts);
}

function checkSystemEtcdMetrics() {
  const metrics = {
    etcdCpu,
    etcdMemory,
  };
  checkEtcdMetrics(apiServer, headers, ETCD_NAMESPACE, ETCD_POD_NAME_PATTERN, metrics, etcdPodRestarts, ETCD_POD_SELECTOR, initialEtcdRestarts);
}

function ensureRegistrySecretInNamespace(namespace) {
  const secretName = 'quay-push-secret';

  // Delete existing secret if present (to ensure fresh credentials)
  const deleteUrl = `${apiServer}/api/v1/namespaces/${namespace}/secrets/${secretName}`;
  http.del(deleteUrl, null, {headers});

  // Get secret from operator namespace
  const secretUrl = `${apiServer}/api/v1/namespaces/${operatorNamespace}/secrets/${secretName}`;
  const secretRes = http.get(secretUrl, {headers});

  if (secretRes.status !== 200) {
    console.warn(`  ⚠️  Registry secret not found in ${operatorNamespace}, restore may fail`);
    return false;
  }

  // Copy secret to workspace namespace
  const secret = JSON.parse(secretRes.body);
  secret.metadata.namespace = namespace;
  delete secret.metadata.resourceVersion;
  delete secret.metadata.uid;
  delete secret.metadata.creationTimestamp;

  const createUrl = `${apiServer}/api/v1/namespaces/${namespace}/secrets`;
  const createRes = http.post(createUrl, JSON.stringify(secret), {headers});

  if (createRes.status !== 201) {
    console.warn(`  ⚠️  Failed to create registry secret in ${namespace} (HTTP ${createRes.status})`);
    return false;
  }

  return true;
}

function verifyWorkspaceRestore(backedUpWorkspaces) {
  console.log(`Starting restore verification for ${backedUpWorkspaces.length} backed up workspaces`);

  const maxRestoreCount = Math.min(maxRestoreSamples, backedUpWorkspaces.length);
  const samplesToRestore = backedUpWorkspaces.slice(0, maxRestoreCount);

  console.log(`Restoring ${samplesToRestore.length} workspaces IN PARALLEL...\n`);

  // STEP 0: Ensure registry secrets (in parallel for unique namespaces)
  const uniqueNamespaces = [...new Set(samplesToRestore.map(ws => ws.namespace))];
  uniqueNamespaces.forEach(ns => ensureRegistrySecretInNamespace(ns));

  // STEP 1: Delete all workspaces in parallel using http.batch()
  console.log(`\nStep 1: Deleting ${samplesToRestore.length} workspaces in parallel...`);
  const deleteRequests = samplesToRestore.map(ws => ({
    method: 'DELETE',
    url: `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${ws.namespace}/devworkspaces/${ws.name}`,
    params: { headers }
  }));

  http.batch(deleteRequests);
  sleep(5);

  // STEP 2: Create all workspaces in parallel
  console.log(`\nStep 2: Creating ${samplesToRestore.length} restored workspaces in parallel...`);
  const createRequests = samplesToRestore.map(workspace => {
    const restoreSpec = JSON.parse(JSON.stringify(workspace.originalSpec));
    if (!restoreSpec.template) restoreSpec.template = {};
    if (!restoreSpec.template.attributes) restoreSpec.template.attributes = {};
    restoreSpec.template.attributes['controller.devfile.io/restore-workspace'] = 'true';

    // Remove projects to avoid git clone overwriting restore
    if (restoreSpec.template.projects) delete restoreSpec.template.projects;
    restoreSpec.started = true;

    return {
      method: 'POST',
      url: `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${workspace.namespace}/devworkspaces`,
      body: JSON.stringify({
        apiVersion: 'workspace.devfile.io/v1alpha2',
        kind: 'DevWorkspace',
        metadata: { name: workspace.name, namespace: workspace.namespace },
        spec: restoreSpec
      }),
      params: { headers }
    };
  });

  const createResponses = http.batch(createRequests);
  samplesToRestore.forEach(() => restoreWorkspacesTotal.add(1));

  // STEP 3: Poll all workspaces in parallel until Ready
  console.log(`\nStep 3: Monitoring ${samplesToRestore.length} workspaces in parallel...`);
  const startTime = Date.now();
  const maxWaitTime = 600 * 1000;
  const pollInterval = 5 * 1000;

  const status = samplesToRestore.map(ws => ({
    ...ws,
    phase: 'Unknown',
    done: false,
    startTime: Date.now()
  }));

  let successCount = 0;
  let failCount = 0;

  while (Date.now() - startTime < maxWaitTime && status.some(s => !s.done)) {
    const statusRequests = status
      .filter(s => !s.done)
      .map(ws => ({
        method: 'GET',
        url: `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${ws.namespace}/devworkspaces/${ws.name}`,
        params: { headers }
      }));

    if (statusRequests.length === 0) break;

    const statusResponses = http.batch(statusRequests);

    let activeIdx = 0;
    status.forEach((ws, idx) => {
      if (ws.done) return;

      const res = statusResponses[activeIdx++];
      if (res.status === 200) {
        const dw = JSON.parse(res.body);
        const phase = dw.status?.phase || 'Unknown';
        status[idx].phase = phase;

        if (phase === 'Running') {
          status[idx].done = true;
          const duration = Date.now() - ws.startTime;
          restoreDuration.add(duration);
          successCount++;
          restoreWorkspacesSucceeded.add(1);
        } else if (phase === 'Failed') {
          status[idx].done = true;
          failCount++;
          restoreWorkspacesFailed.add(1);
          console.error(`  ❌ ${ws.namespace}/${ws.name} failed`);
        }
      }
    });

    sleep(pollInterval / 1000);
  }

  // Handle timeouts
  status.forEach(ws => {
    if (!ws.done) {
      failCount++;
      restoreWorkspacesFailed.add(1);
      console.error(`  ❌ ${ws.namespace}/${ws.name} timed out (${ws.phase})`);
    }
  });

  const successRate = samplesToRestore.length > 0 ? (successCount / samplesToRestore.length) : 0;
  restoreSuccessRate.add(successRate);

  console.log("\n======================================");
  console.log("Restore Verification Summary");
  console.log("======================================");
  console.log(`Total: ${samplesToRestore.length}`);
  console.log(`Succeeded: ${successCount}`);
  console.log(`Failed: ${failCount}`);
  console.log(`Success Rate: ${(successRate * 100).toFixed(2)}%`);
  console.log("======================================\n");
}

export function handleSummary(data) {
  const allowedMetrics = [
    'backup_jobs_total',
    'backup_jobs_succeeded',
    'backup_jobs_failed',
    'backup_jobs_running',
    'backup_pods_total',
    'workspaces_stopped',
    'workspaces_backed_up',
    'backup_success_rate',
    'backup_job_duration',
    'imagestreams_created',
    'imagestreams_expected',
    'restore_workspaces_total',
    'restore_workspaces_succeeded',
    'restore_workspaces_failed',
    'restore_duration',
    'restore_success_rate',
    'operator_cpu_violations',
    'operator_mem_violations',
    'average_operator_cpu',
    'average_operator_memory',
    'operator_pod_restarts_total',
    'etcd_pod_restarts_total',
    'average_etcd_cpu',
    'average_etcd_memory'
  ];

  const filteredData = createFilteredSummaryData(data, allowedMetrics);

  let backupLoadTestSummaryReport = {
    stdout: textSummary(filteredData, {indent: ' ', enableColors: true})
  }

  if (!inCluster) {
    backupLoadTestSummaryReport["backup-load-test-report.html"] = htmlReport(data, {
      title: "DevWorkspace Backup Load Test Report",
    });
  }

  return backupLoadTestSummaryReport;
}
