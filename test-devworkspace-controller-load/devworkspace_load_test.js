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
import {check, sleep} from 'k6';
import {Trend, Counter, Gauge} from 'k6/metrics';
import { test, scenario } from 'k6/execution';
import {htmlReport} from "https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js";
import {textSummary} from "https://jslib.k6.io/k6-summary/0.0.1/index.js";
import {
  checkPodRestarts,
  parseCpuToMillicores,
  parseMemoryToBytes,
  generateDevWorkspaceToCreate,
  getDevWorkspacesFromApiServer,
  doHttpPostDevWorkspaceCreate,
  createAuthHeaders,
} from '../common/utils.js';

const inCluster = __ENV.IN_CLUSTER === 'true';
const apiServer = inCluster ? `https://kubernetes.default.svc` : __ENV.KUBE_API;
const token = inCluster ? open('/var/run/secrets/kubernetes.io/serviceaccount/token') : __ENV.KUBE_TOKEN;
const useSeparateNamespaces = __ENV.SEPARATE_NAMESPACES === "true";
const deleteDevWorkspaceAfterReady = __ENV.DELETE_DEVWORKSPACE_AFTER_READY === "true";
const runBackupTestHook = __ENV.RUN_BACKUP_TEST_HOOK === "true";
const operatorNamespace = __ENV.DWO_NAMESPACE || 'openshift-operators';
const shouldCreateAutomountResources = (__ENV.CREATE_AUTOMOUNT_RESOURCES || 'false') === 'true';
const maxVUs = Number(__ENV.MAX_VUS || 50);
const maxDevWorkspaces = Number(__ENV.MAX_DEVWORKSPACES || -1);
const devWorkspaceReadyTimeout = Number(__ENV.DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS || 600);
const pollWaitInterval = 10; // seconds between DevWorkspace status polls
const loadTestDurationInMinutes = Number(__ENV.TEST_DURATION_MINUTES || 180);
const executorMode = __ENV.EXECUTOR_MODE || 'shared-iterations'; // Options: 'shared-iterations', 'ramping-vus'
const autoMountConfigMapName = 'dwo-load-test-automount-configmap';
const autoMountSecretName = 'dwo-load-test-automount-secret';
const labelType = "test-type";
const labelKey = "load-test";
const loadTestNamespace = __ENV.LOAD_TEST_NAMESPACE || "loadtest-devworkspaces";
let ETCD_NAMESPACE = 'openshift-etcd';
let ETCD_POD_NAME_PATTERN = 'etcd';
const ETCD_POD_SELECTOR = `app=${ETCD_POD_NAME_PATTERN}`;
const OPERATOR_POD_SELECTOR = 'app.kubernetes.io/name=devworkspace-controller';

const headers = createAuthHeaders(token);

/**
 * Generate load test stages for ramping-vus executor
 * @param {number} maxVUs - Maximum number of virtual users
 * @returns {Array} Array of stage objects
 */
function generateLoadTestStages(maxVUs) {
  return [
    { duration: '2m', target: Math.floor(maxVUs * 0.25) },
    { duration: '5m', target: Math.floor(maxVUs * 0.5) },
    { duration: '8m', target: Math.floor(maxVUs * 0.75) },
    { duration: '10m', target: maxVUs },
    { duration: `${loadTestDurationInMinutes - 25}m`, target: maxVUs },
  ];
}

/**
 * Build k6 scenarios based on executor mode
 * @returns {Object} Scenarios configuration
 */
function buildScenarios() {
  const scenarios = {};

  if (executorMode === 'ramping-vus') {
    scenarios.create_and_delete_devworkspaces = {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: generateLoadTestStages(maxVUs),
      gracefulRampDown: '1m',
    };
    scenarios.final_cleanup = {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      startTime: `${loadTestDurationInMinutes}m`,
      exec: 'final_cleanup',
    };
  } else if (executorMode === 'shared-iterations') {
    scenarios.create_and_delete_devworkspaces = {
      executor: 'shared-iterations',
      vus: 20,
      iterations: maxDevWorkspaces,
      maxDuration: '3h',
    };
  } else {
    throw new Error(`Unknown executor mode: ${executorMode}. Use 'shared-iterations' or 'ramping-vus'`);
  }

  return scenarios;
}

export const options = {
  scenarios: buildScenarios(),
  thresholds: {
    'checks': ['rate>0.95'],
    'devworkspace_create_duration': ['p(95)<15000'],
    'devworkspace_delete_duration': ['p(95)<10000'],
    'devworkspace_ready_duration': ['p(95)<60000'],
    'devworkspace_ready_failed': ['count<5'],
    'operator_cpu_violations': ['count==0'],
    'operator_mem_violations': ['count==0'],
    'operator_pod_restarts_total': ['value == 0'],
    'etcd_pod_restarts_total': ['value==0'],
  },
  insecureSkipTLSVerify: true,  // trust self-signed certs like in CRC
};

const devworkspaceCreateDuration = new Trend('devworkspace_create_duration');
const devworkspaceReady = new Counter('devworkspace_ready');
const devworkspaceDeleteDuration = new Trend('devworkspace_delete_duration');
const devworkspaceReadyDuration = new Trend('devworkspace_ready_duration');
const devworkspaceReadyFailed = new Counter('devworkspace_ready_failed');
const devworkspaceStarting = new Counter('devworkspace_starting'); // Tracks current count in Starting phase (increments on create, decrements on ready/failed)
const operatorCpu = new Trend('average_operator_cpu'); // in milli cores
const operatorMemory = new Trend('average_operator_memory'); // in Mi
const etcdCpu = new Trend('average_etcd_cpu'); // in milli cores
const etcdMemory = new Trend('average_etcd_memory'); // in Mi
const devworkspacesCreated = new Counter('devworkspace_create_count');
const operatorCpuViolations = new Counter('operator_cpu_violations');
const operatorMemViolations = new Counter('operator_mem_violations');
const operatorPodRestarts = new Gauge('operator_pod_restarts_total');
const etcdPodRestarts = new Gauge('etcd_pod_restarts_total');

const maxCpuMillicores = 250;
const maxMemoryBytes = 200 * 1024 * 1024;

function detectClusterType() {
  const apiGroupsUrl = `${apiServer}/apis`;
  const res = http.get(apiGroupsUrl, {headers});
  
  if (res.status === 200) {
    try {
      const data = JSON.parse(res.body);
      const groups = data.groups || [];
      const hasOpenShiftRoutes = groups.some(g => g.name === 'route.openshift.io');
      
      if (!hasOpenShiftRoutes) {
        ETCD_NAMESPACE = __ENV.ETCD_NAMESPACE || 'kube-system';
        ETCD_POD_NAME_PATTERN = __ENV.ETCD_POD_NAME_PATTERN || 'kube-proxy';
        console.log('Detected Kubernetes cluster - using kube-system namespace with kube-proxy');
      }
    } catch (e) {
      console.warn(`Failed to detect cluster type: ${e.message}, using defaults`);
    }
  }
}

export function setup() {
  detectClusterType();

  if (shouldCreateAutomountResources) {
    createNewAutomountConfigMap();
    createNewAutomountSecret();
  }
}

export default function () {
  const vuId = __VU;
  const iteration = __ITER;

  // In ramping-vus mode, use iteration count to enforce max limit
  // This is much more efficient than querying the API every time
  if (maxDevWorkspaces > 0 && executorMode === 'ramping-vus') {
    const totalIterations = scenario.iterationInTest;
    if (totalIterations >= maxDevWorkspaces) {
      // Max iterations reached, skip this creation
      return;
    }
  }
  const crName = `dw-test-${vuId}-${iteration}`;
  const namespace = useSeparateNamespaces
      ? `load-test-ns-${__VU}-${__ITER}`
      : loadTestNamespace;

  if (!apiServer) {
    throw new Error('KUBE_API env var is required');
  }
  try {
    if (useSeparateNamespaces) {
      createNewNamespace(namespace);
    }
    const devWorkspaceCreated = createNewDevWorkspace(namespace, vuId, iteration);
    if (devWorkspaceCreated) {
      waitUntilDevWorkspaceIsReady(vuId, crName, namespace);
      if (deleteDevWorkspaceAfterReady) {
        deleteDevWorkspace(crName, namespace);
      }
    }
  } catch (error) {
    console.error(`Load test for ${vuId}-${iteration} failed:`, error.message);
  }
}

export function final_cleanup() {
  // Skip cleanup if backup testing hook is enabled - backup tests need the workspaces
  if (runBackupTestHook) {
    console.log("Skipping final_cleanup - backup testing hook will run after k6 completes");
    return;
  }

  if (useSeparateNamespaces) {
    deleteAllSeparateNamespaces();
  } else {
    deleteAllDevWorkspacesInCurrentNamespace();
  }

  if (shouldCreateAutomountResources) {
    deleteConfigMap();
    deleteSecret();
  }
}

export function handleSummary(data) {
  const allowed = [
    'devworkspace_create_count',
    'devworkspace_create_duration',
    'devworkspace_delete_duration',
    'devworkspace_ready_duration',
    'devworkspace_ready',
    'devworkspace_ready_failed',
    'devworkspace_starting',
    'operator_cpu_violations',
    'operator_mem_violations',
    'average_operator_cpu',
    'average_operator_memory',
    'operator_pod_restarts_total',
    'etcd_pod_restarts_total',
    'average_etcd_cpu',
    'average_etcd_memory'
  ];

  const filteredData = JSON.parse(JSON.stringify(data));
  for (const key of Object.keys(filteredData.metrics)) {
    if (!allowed.includes(key)) {
      delete filteredData.metrics[key];
    }
  }

  let loadTestSummaryReport = {
    stdout: textSummary(filteredData, {indent: ' ', enableColors: true})
  }
  // Only generate HTML report when running outside the cluster
  if (!inCluster) {
    loadTestSummaryReport["devworkspace-load-test-report.html"] = htmlReport(data, {
      title: "DevWorkspace Operator Load Test Report (HTTP)",
    });
  }
  return loadTestSummaryReport;
}

export function teardown(data) {
  // Skip cleanup if backup testing hook is enabled - backup tests need the workspaces
  if (runBackupTestHook) {
    console.log("Skipping cleanup - backup testing hook will run after k6 completes");
    return;
  }

  // Only run cleanup in teardown for shared-iterations mode
  // For ramping-vus mode, cleanup is handled by final_cleanup scenario
  if (executorMode === 'shared-iterations') {
    console.log("Running final cleanup after all DevWorkspace creation finished...");
    final_cleanup();
  } else {
    console.log("Cleanup will be handled by final_cleanup scenario");
  }
}

function createNewDevWorkspace(namespace, vuId, iteration) {
  const manifest = generateDevWorkspaceToCreate(vuId, iteration, namespace);

  const createStart = Date.now();
  const createRes = doHttpPostDevWorkspaceCreate(apiServer, headers, namespace, manifest);
  check(createRes, {
    'DevWorkspace created': (r) => r.status === 201 || r.status === 409,
  });

  if (createRes.status !== 201 && createRes.status !== 409) {
    console.error(`[VU ${vuId}] Failed to create DevWorkspace: ${createRes.status}, ${createRes.body}`);
    return false;
  }
  devworkspaceCreateDuration.add(Date.now() - createStart);
  devworkspacesCreated.add(1);
  devworkspaceStarting.add(1); // Track DevWorkspace entering Starting phase
  return true;
}

function waitUntilDevWorkspaceIsReady(vuId, crName, namespace) {
  const dwUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces/${crName}`;
  const readyStart = Date.now();
  let isReady = false;
  let isFailed = false;
  let attempts = 0;
  let lastPhase = '';
  const maxAttempts = devWorkspaceReadyTimeout / pollWaitInterval;

  while (!isReady && !isFailed && attempts < maxAttempts) {
    const res = http.get(`${dwUrl}`, {headers});

    if (res.status === 200) {
      try {
        const body = JSON.parse(res.body);
        const phase = body?.status?.phase;
        lastPhase = phase;
        if (phase === 'Ready' || phase === 'Running') {
          isReady = true;
          break;
        } else if (phase === 'Failing' || phase === 'Failed' || phase === 'Error') {
          isFailed = true;
          break;
        }
      } catch (e) {
        console.error(`GET [VU ${vuId}] Failed to parse DevWorkspace from API: ${res.body} : ${e.message}`);
      }
    }

    checkDevWorkspaceOperatorMetrics();
    checkEtcdMetrics();
    sleep(pollWaitInterval);
    attempts++;
  }

  if (!isReady && !isFailed && attempts >= maxAttempts) {
    console.error(
        `GET [VU ${vuId}] Timed out waiting for DevWorkspace '${crName}' in namespace '${namespace}' ` +
        `after ${attempts} attempts (${devWorkspaceReadyTimeout}s). Last known phase: '${lastPhase}'`
    );
  }

  // Record metrics based on final state, not on API call success
  if (isReady) {
    devworkspaceReady.add(1);
    devworkspaceReadyDuration.add(Date.now() - readyStart);
    devworkspaceStarting.add(-1); // DevWorkspace left Starting phase (now Ready)
  } else if (isFailed) {
    devworkspaceReadyFailed.add(1);
    devworkspaceStarting.add(-1); // DevWorkspace left Starting phase (Failed)
  } else {
    // Timed out or interrupted - decrement starting counter but don't count as failed
    // These workspaces may still become ready after the test ends
    devworkspaceStarting.add(-1);
  }
}

function deleteDevWorkspace(crName, namespace) {
  const dwUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces/${crName}`;
  const deleteStart = Date.now();
  const delRes = http.del(`${dwUrl}`, null, {headers});
  devworkspaceDeleteDuration.add(Date.now() - deleteStart);

  check(delRes, {
    'DevWorkspace deleted or not found': (r) => r.status === 200 || r.status === 404,
  });
}

function checkDevWorkspaceOperatorMetrics() {
  const metricsUrl = `${apiServer}/apis/metrics.k8s.io/v1beta1/namespaces/${operatorNamespace}/pods`;
  const res = http.get(metricsUrl, {headers});


  check(res, {
    'Fetched pod metrics successfully': (r) => r.status === 200,
  });

  if (res.status !== 200) {
    return;
  }

  const data = JSON.parse(res.body);
  const operatorPods = data.items.filter(p => p.metadata.name.includes("devworkspace-controller"));

  for (const pod of operatorPods) {
    const container = pod.containers[0]; // assuming single container
    const name = pod.metadata.name;

    const cpu = parseCpuToMillicores(container.usage.cpu);
    const memory = parseMemoryToBytes(container.usage.memory);

    operatorCpu.add(cpu);
    operatorMemory.add(memory / 1024 / 1024);

    const cpuOk = cpu <= maxCpuMillicores;
    const memOk = memory <= maxMemoryBytes;

    if (!cpuOk) {
      operatorCpuViolations.add(1);
    }
    if (!memOk) {
      operatorMemViolations.add(1);
    }

    check(null, {
      [`[${name}] CPU < ${maxCpuMillicores}m`]: () => cpuOk,
      [`[${name}] Memory < ${Math.round(maxMemoryBytes / 1024 / 1024)}Mi`]: () => memOk,
    });
  }

  // Check for pod restarts
  checkPodRestarts(apiServer, headers, operatorNamespace, OPERATOR_POD_SELECTOR, operatorPodRestarts);
}

function checkEtcdMetrics() {
  if (!ETCD_NAMESPACE || !ETCD_POD_NAME_PATTERN) {
    console.warn(`[ETCD METRICS] Variables not initialized: etcdNamespace=${ETCD_NAMESPACE}, etcdPodNamePattern=${ETCD_POD_NAME_PATTERN}`);
    return;
  }

  const metricsUrl = `${apiServer}/apis/metrics.k8s.io/v1beta1/namespaces/${ETCD_NAMESPACE}/pods`;
  const res = http.get(metricsUrl, {headers});

  check(res, {
    'Fetched etcd pod metrics successfully': (r) => r.status === 200,
  });

  if (res.status !== 200) {
    return;
  }

  const data = JSON.parse(res.body);
  const etcdPods = data.items.filter(p => p.metadata.name.includes(ETCD_POD_NAME_PATTERN));

  if (etcdPods.length === 0) {
    if (data.items && data.items.length > 0) {
      const podNames = data.items.map(p => p.metadata.name).join(', ');
      console.warn(`[ETCD METRICS] No pods found matching pattern '${ETCD_POD_NAME_PATTERN}' in namespace '${ETCD_NAMESPACE}'. Available pods: ${podNames}`);
    } else {
      console.warn(`[ETCD METRICS] No pods found in namespace '${ETCD_NAMESPACE}'`);
    }
    return;
  }

  for (const pod of etcdPods) {
    if (!pod.containers || pod.containers.length === 0) {
      console.warn(`[ETCD METRICS] Pod ${pod.metadata.name} has no containers`);
      continue;
    }
    const container = pod.containers[0];
    const name = pod.metadata.name;

    if (!container.usage?.cpu || !container.usage?.memory) {
      console.warn(
          `[ETCD METRICS] Pod ${name} has no usage data:`,
          JSON.stringify(container.usage)
      );
      continue;
    }

    const cpu = parseCpuToMillicores(container.usage.cpu);
    const memory = parseMemoryToBytes(container.usage.memory);

    etcdCpu.add(cpu);
    etcdMemory.add(memory / 1024 / 1024);
  }

  checkPodRestarts(apiServer, headers, ETCD_NAMESPACE, ETCD_POD_SELECTOR, etcdPodRestarts);
}

function createNewNamespace(namespaceName) {
  const url = `${apiServer}/api/v1/namespaces`;

  const namespaceObj = {
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: {
      name: namespaceName,
      labels: {
        [labelKey]: labelType
      }
    }
  }
  const res = http.post(url, JSON.stringify(namespaceObj), {headers});

  if (res.status !== 201 && res.status !== 409) {
    throw new Error(`Failed to create Namespace: ${res.status} - ${namespaceName}`);
  }
}

function createNewAutomountConfigMap() {
  const url = `${apiServer}/api/v1/namespaces/${loadTestNamespace}/configmaps`;

  const configMapManifest = {
    apiVersion: 'v1', kind: 'ConfigMap', metadata: {
      name: autoMountConfigMapName, namespace: loadTestNamespace, labels: {
        'controller.devfile.io/mount-to-devworkspace': 'true', 'controller.devfile.io/watch-configmap': 'true',
      }, annotations: {
        'controller.devfile.io/mount-path': '/etc/config/dwo-load-test-configmap',
        'controller.devfile.io/mount-access-mode': '0644',
        'controller.devfile.io/mount-as': 'file',
      },
    }, data: {
      'test.key': 'test-value',
    },
  };

  const res = http.post(url, JSON.stringify(configMapManifest), {headers});

  if (res.status !== 201 && res.status !== 409) {
    throw new Error(`Failed to create automount ConfigMap: ${res.status} - ${res.body}`);
  }
  console.log("Created automount configMap : " + autoMountConfigMapName);
}

function createNewAutomountSecret() {
  const manifest = {
    apiVersion: 'v1', kind: 'Secret', metadata: {
      name: autoMountSecretName, namespace: loadTestNamespace, labels: {
        'controller.devfile.io/mount-to-devworkspace': 'true', 'controller.devfile.io/watch-secret': 'true',
      }, annotations: {
        'controller.devfile.io/mount-path': `/etc/secret/dwo-load-test-secret`,
        'controller.devfile.io/mount-as': 'file',
      },
    }, type: 'Opaque', data: {
      'secret.key': __ENV.SECRET_VALUE_BASE64 || 'dGVzdA==', // base64-encoded 'test'
    },
  };

  const res = http.post(`${apiServer}/api/v1/namespaces/${loadTestNamespace}/secrets`, JSON.stringify(manifest), {headers});
  if (res.status !== 201 && res.status !== 409) {
    throw new Error(`Failed to create automount Secret: ${res.status} - ${res.body}`);
  }
}

function deleteConfigMap() {
  const url = `${apiServer}/api/v1/namespaces/${loadTestNamespace}/configmaps/${autoMountConfigMapName}`;
  const res = http.del(url, null, { headers });
  if (res.status !== 200 && res.status !== 404) {
    console.warn(`[CLEANUP] Failed to delete ConfigMap ${autoMountConfigMapName}: ${res.status}`);
  }
}

function deleteSecret() {
  const url = `${apiServer}/api/v1/namespaces/${loadTestNamespace}/secrets/${autoMountSecretName}`;
  const res = http.del(url, null, {headers});
  if (res.status !== 200 && res.status !== 404) {
    console.warn(`[CLEANUP] Failed to delete Secret ${autoMountSecretName}: ${res.status}`);
  }
}

function deleteNamespace(name) {
  const delRes = http.del(`${apiServer}/api/v1/namespaces/${name}`, null, {headers});
  if (delRes.status !== 200 && delRes.status !== 404) {
    console.warn(`[CLEANUP] Failed to delete Namespace ${name}: ${delRes.status}`);
  }
}

function deleteAllDevWorkspacesInCurrentNamespace() {
  const deleteByLabelSelectorUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${loadTestNamespace}/devworkspaces?labelSelector=${labelKey}%3D${labelType}`;
  console.log(`[CLEANUP] Deleting all DevWorkspaces in ${loadTestNamespace} containing label ${labelKey}=${labelType}`);

  const res = http.del(deleteByLabelSelectorUrl, null, {headers});
  if (res.status !== 200) {
    console.error(`[CLEANUP] Failed to delete DevWorkspaces: ${res.status}`);
  }
}

function deleteAllSeparateNamespaces() {
  const getNamespacesByLabel = `${apiServer}/api/v1/namespaces?labelSelector=${labelKey}%3D${labelType}`;
  console.log(`[CLEANUP] Deleting all Namespaces containing label ${labelKey}=${labelType}`);

  const res = http.get(getNamespacesByLabel, {headers});
  if (res.status !== 200) {
    console.error(`[CLEANUP] Failed to list DevWorkspaces: ${res.status}`);
    return;
  }

  const body = JSON.parse(res.body);
  if (!body.items || !Array.isArray(body.items)) return;

  for (const item of body.items) {
    deleteNamespace(item.metadata.name);
  }
}

