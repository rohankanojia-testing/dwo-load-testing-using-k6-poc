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
  detectClusterType,
  checkDevWorkspaceOperatorMetrics,
  checkEtcdMetrics,
  createFilteredSummaryData,
} from '../common/utils.js';

const inCluster = __ENV.IN_CLUSTER === 'true';
const apiServer = inCluster ? `https://kubernetes.default.svc` : __ENV.KUBE_API;
const token = inCluster ? open('/var/run/secrets/kubernetes.io/serviceaccount/token') : __ENV.KUBE_TOKEN;
const useSeparateNamespaces = __ENV.SEPARATE_NAMESPACES === "true";
const deleteDevWorkspaceAfterReady = __ENV.DELETE_DEVWORKSPACE_AFTER_READY === "true";
const skipCleanup = __ENV.SKIP_CLEANUP === "true";
const operatorNamespace = __ENV.DWO_NAMESPACE || 'openshift-operators';
const shouldCreateAutomountResources = (__ENV.CREATE_AUTOMOUNT_RESOURCES || 'false') === 'true';
const maxVUs = Number(__ENV.MAX_VUS || 20);
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

// Parse initial restart counts from environment variables
const initialEtcdRestarts = __ENV.INITIAL_ETCD_RESTARTS ? JSON.parse(__ENV.INITIAL_ETCD_RESTARTS) : {};
const initialOperatorRestarts = __ENV.INITIAL_OPERATOR_RESTARTS ? JSON.parse(__ENV.INITIAL_OPERATOR_RESTARTS) : {};

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
      vus: maxVUs,
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

export function setup() {
  const clusterInfo = detectClusterType(apiServer, headers);
  ETCD_NAMESPACE = clusterInfo.etcdNamespace;
  ETCD_POD_NAME_PATTERN = clusterInfo.etcdPodPattern;

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
  // Skip cleanup if SKIP_CLEANUP flag is set
  if (skipCleanup) {
    console.log("Skipping final_cleanup - SKIP_CLEANUP flag is enabled");
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
  const allowedMetrics = [
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

  const filteredData = createFilteredSummaryData(data, allowedMetrics);

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
  // Skip cleanup if SKIP_CLEANUP flag is set
  if (skipCleanup) {
    console.log("Skipping cleanup - SKIP_CLEANUP flag is enabled");
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

    checkOperatorMetrics();
    checkSystemEtcdMetrics();
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

