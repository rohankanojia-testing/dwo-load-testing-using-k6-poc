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
const backupJobLabel = "controller.devfile.io/backup-job=true";
let ETCD_NAMESPACE = 'openshift-etcd';
let ETCD_POD_NAME_PATTERN = 'etcd';
const ETCD_POD_SELECTOR = `app=${ETCD_POD_NAME_PATTERN}`;
const OPERATOR_POD_SELECTOR = 'app.kubernetes.io/name=devworkspace-controller';
const monitorPollInterval = 10; // seconds between monitoring polls

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
    'backup_jobs_succeeded': ['count>0'],
    'backup_jobs_failed': ['count==0'],
    'backup_pods_total': ['count>0'],
    'workspaces_stopped': ['count>0'],
    'workspaces_backed_up': ['count>0'],
    'backup_success_rate': ['value>=0.95'],
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
const operatorCpu = new Trend('average_operator_cpu');
const operatorMemory = new Trend('average_operator_memory');
const etcdCpu = new Trend('average_etcd_cpu');
const etcdMemory = new Trend('average_etcd_memory');
const operatorCpuViolations = new Counter('operator_cpu_violations');
const operatorMemViolations = new Counter('operator_mem_violations');
const operatorPodRestarts = new Gauge('operator_pod_restarts_total');
const etcdPodRestarts = new Gauge('etcd_pod_restarts_total');

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
  stopWorkspacesAndMonitorBackups(data);
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
  verifyBackupCoverage(devWorkspaces);

  // Step 6: Final metrics collection
  console.log("\nStep 6: Collecting final metrics...");
  collectFinalMetrics();

  console.log("\n======================================");
  console.log("Backup Load Test Completed");
  console.log("======================================\n");
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

    console.log(`  No backup Jobs yet... waiting (attempt ${attempts + 1}/${maxAttempts})`);
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

    if (status.succeeded === 1) {
      succeeded++;
    } else if (status.failed && status.failed >= 1) {
      failed++;
    } else {
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

    // Check operator and etcd metrics
    checkOperatorMetrics();
    checkSystemEtcdMetrics();

    // Check if all jobs are complete
    if (metrics.total > 0 && (metrics.succeeded + metrics.failed) >= metrics.total) {
      console.log("All backup Jobs have completed or failed");

      // Record final counts
      backupJobsSucceeded.add(metrics.succeeded);
      backupJobsFailed.add(metrics.failed);

      break;
    }

    sleep(monitorPollInterval);
  }
}

function verifyBackupCoverage(devWorkspaces) {
  const jobs = getBackupJobs();
  const backedUpWorkspaces = new Set();

  // Extract workspace names from backup job labels
  for (const job of jobs) {
    const labels = job.metadata?.labels || {};
    const workspaceName = labels['controller.devfile.io/devworkspace_name'];

    if (workspaceName && job.status?.succeeded === 1) {
      backedUpWorkspaces.add(workspaceName);
    }
  }

  // Count how many workspaces were backed up
  let backedUpCount = 0;
  for (const dw of devWorkspaces) {
    if (backedUpWorkspaces.has(dw.metadata.name)) {
      backedUpCount++;
    }
  }

  workspacesBackedUp.add(backedUpCount);

  console.log(`Backup Coverage: ${backedUpCount}/${devWorkspaces.length} workspaces backed up`);

  if (backedUpCount < devWorkspaces.length) {
    console.warn(`Warning: ${devWorkspaces.length - backedUpCount} workspaces were not backed up`);

    // List workspaces that weren't backed up
    for (const dw of devWorkspaces) {
      if (!backedUpWorkspaces.has(dw.metadata.name)) {
        console.warn(`  Not backed up: ${dw.metadata.namespace}/${dw.metadata.name}`);
      }
    }
  }
}

function collectFinalMetrics() {
  const metrics = getBackupJobMetrics();

  console.log("\n======================================");
  console.log("Final Backup Job Metrics");
  console.log("======================================");
  console.log(`Total Jobs: ${metrics.total}`);
  console.log(`Succeeded: ${metrics.succeeded}`);
  console.log(`Failed: ${metrics.failed}`);
  console.log(`Running/Pending: ${metrics.running}`);

  if (metrics.total > 0) {
    const successRate = ((metrics.succeeded / metrics.total) * 100).toFixed(2);
    const failureRate = ((metrics.failed / metrics.total) * 100).toFixed(2);
    console.log(`Success Rate: ${successRate}%`);
    console.log(`Failure Rate: ${failureRate}%`);
  }
  console.log("======================================\n");

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
  checkDevWorkspaceOperatorMetrics(apiServer, headers, operatorNamespace, maxCpuMillicores, maxMemoryBytes, metrics, operatorPodRestarts, OPERATOR_POD_SELECTOR);
}

function checkSystemEtcdMetrics() {
  const metrics = {
    etcdCpu,
    etcdMemory,
  };
  checkEtcdMetrics(apiServer, headers, ETCD_NAMESPACE, ETCD_POD_NAME_PATTERN, metrics, etcdPodRestarts, ETCD_POD_SELECTOR);
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
