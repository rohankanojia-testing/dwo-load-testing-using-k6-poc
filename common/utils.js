// common/k6-utils.js
import http from 'k6/http';

const labelType = "test-type";
const labelKey = "load-test";
const externalDevWorkspaceLink = __ENV.DEVWORKSPACE_LINK || '';

export function createAuthHeaders(token, contentType = 'application/json') {
    return {
        Authorization: `Bearer ${token}`,
        'Content-Type': contentType,
    };
}


export function doHttpGetDevWorkspacesFromApiServer(apiServer, headers, namespace) {
    const url = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces`;
    return http.get(url, { headers, timeout: '30s' });
}

export function doHttpPostDevWorkspaceCreate(apiServer, headers, namespace, dwManifest) {
    const baseUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces`;

    const payload = JSON.stringify(dwManifest);
    return http.post(baseUrl, payload, {headers, timeout: '120s'});
}

export function doHttpPatchDevWorkspaceUpdate(apiServer, headers, namespace, dwManifest, dwName) {
    const baseUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces/${dwName}`;

    const payload = JSON.stringify(dwManifest);
    return http.patch(baseUrl, payload, {headers, timeout: '120s'});
}

export function doHttpPatchPodDevWorkspaceUpdate(apiServer, headers, namespace, dwManifest, pod) {
    const baseUrl = `${apiServer}/api/v1/namespaces/${namespace}/pods/${pod.metadata?.name}`;

    const payload = JSON.stringify(dwManifest);
    return http.patch(baseUrl, payload, {headers, timeout: '120s'});
}

/**
 * Get the first pod name for a given DevWorkspace
 * @param {string} apiServer - Kubernetes api server
 * @param {Object} headers - HTTP headers
 * @param {string} namespace - Kubernetes namespace
 * @param {string} dwName - DevWorkspace name
 * @returns {string|null} - Pod name or null if not found
 */
export function getPodForDevWorkspace(apiServer, headers, namespace, dwName) {
    const podListUrl = `${apiServer}/api/v1/namespaces/${namespace}/pods?labelSelector=controller.devfile.io/devworkspace_name=${dwName}`;
    const podListRes = http.get(podListUrl, { headers, timeout: '30s' });
    const pods = podListRes.json()?.items || [];

    if (!pods.length) {
        return null;
    }

    return pods[0];
}

export function parseMemoryToBytes(memStr) {
    if (memStr.endsWith("Ki")) return parseInt(memStr) * 1024;
    if (memStr.endsWith("Mi")) return parseInt(memStr) * 1024 * 1024;
    if (memStr.endsWith("Gi")) return parseInt(memStr) * 1024 * 1024 * 1024;
    if (memStr.endsWith("n")) return parseInt(memStr) / 1e9;
    if (memStr.endsWith("u")) return parseInt(memStr) / 1e6;
    if (memStr.endsWith("m")) return parseInt(memStr) / 1e3;
    return parseInt(memStr); // bytes
}

export function parseCpuToMillicores(cpuStr) {
    if (cpuStr.endsWith("n")) return Math.round(parseInt(cpuStr) / 1e6);
    if (cpuStr.endsWith("u")) return Math.round(parseInt(cpuStr) / 1e3);
    if (cpuStr.endsWith("m")) return parseInt(cpuStr);
    return Math.round(parseFloat(cpuStr) * 1000);
}

/**
 * Helper function to fetch and parse pod restart counts from Kubernetes API
 * @param {string} apiServer - Kubernetes API server URL
 * @param {Object} headers - HTTP headers with authentication
 * @param {string} namespace - Kubernetes namespace
 * @param {string} labelSelector - Label selector to filter pods (e.g., "app=my-app")
 * @returns {Object} Map of pod name to restart count
 */
export function getPodRestartCounts(apiServer, headers, namespace, labelSelector) {
    const podsUrl = `${apiServer}/api/v1/namespaces/${namespace}/pods?labelSelector=${labelSelector}`;
    const res = http.get(podsUrl, {headers});

    const restartCounts = {};
    if (res.status === 200) {
        const data = JSON.parse(res.body);
        data.items.forEach(pod => {
            const podName = pod.metadata.name;
            restartCounts[podName] = pod.status.containerStatuses?.[0]?.restartCount || 0;
        });
    }
    return restartCounts;
}

/**
 * Check for pod restarts compared to baseline and report new restarts
 * @param {string} apiServer - Kubernetes API server URL
 * @param {Object} headers - HTTP headers with authentication
 * @param {string} namespace - Kubernetes namespace
 * @param {string} labelSelector - Label selector to filter pods
 * @param {Object} restartCounterMetric - k6 Gauge metric to track restarts (optional)
 * @param {Object} initialRestartCounts - Initial restart counts to subtract (optional, default: empty object)
 * @returns {Object} Object with totalRestarts count and details array
 */
export function checkPodRestarts(apiServer, headers, namespace, labelSelector, restartCounterMetric = null, initialRestartCounts = {}) {
    const currentRestartCounts = getPodRestartCounts(apiServer, headers, namespace, labelSelector);

    let totalDelta = 0;
    Object.entries(currentRestartCounts).forEach(([podName, currentRestartCount]) => {
        const initialCount = initialRestartCounts[podName] || 0;
        const delta = currentRestartCount - initialCount;
        totalDelta += delta;
    });

    if (restartCounterMetric) {
        // For k6 Gauge metrics, add() sets the current value (not accumulative)
        restartCounterMetric.add(totalDelta);
    }
}

export function generateDevWorkspaceToCreate(vuId, iteration, namespace) {
    const name = `dw-test-${vuId}-${iteration}`;
    let devWorkspace = {};
    if (externalDevWorkspaceLink.length > 0) {
        devWorkspace = downloadAndParseExternalWorkspace(externalDevWorkspaceLink);
    } else {
        devWorkspace = createOpinionatedDevWorkspace();
    }
    devWorkspace.metadata.name = name;
    devWorkspace.metadata.namespace = namespace;
    devWorkspace.metadata.labels = {
        [labelKey]: labelType
    }
    return devWorkspace;
}

export function downloadAndParseExternalWorkspace(externalDevWorkspaceLink) {
    let manifest;
    if (externalDevWorkspaceLink) {
        const res = http.get(externalDevWorkspaceLink);

        if (res.status !== 200) {
            throw new Error(`[DW CREATE] Failed to fetch JSON content from ${externalDevWorkspaceLink}, got ${res.status}`);
        }
        manifest = parseJSONResponseToDevWorkspace(res);
    }

    return manifest;
}

export function getDevWorkspacesFromApiServer(apiServer, loadTestNamespace, headers, useSeparateNamespaces) {
    const basePath = useSeparateNamespaces
        ? `${apiServer}/apis/workspace.devfile.io/v1alpha2/devworkspaces`
        : `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${loadTestNamespace}/devworkspaces`;

    const url = `${basePath}?labelSelector=${labelKey}%3D${labelType}`;
    const res = http.get(url, { headers });

    if (res.status !== 200) {
        const errorMsg = `Failed to fetch DevWorkspaces: ${res.status} ${res.statusText || ''}`;
        console.error(errorMsg);

        return {
            error: errorMsg,
            devWorkspaces: null,
        };
    }

    const body = JSON.parse(res.body);

    return {
        error: null,
        devWorkspaces: body.items,
    };
}

function parseJSONResponseToDevWorkspace(response) {
    let devWorkspace;
    try {
        devWorkspace = response.json();
    } catch (e) {
        throw new Error(`[DW CREATE] Failed to parse JSON : ${response.body}: ${e.message}`);
    }
    return devWorkspace;
}

function createOpinionatedDevWorkspace(loadTestNamespace) {
    return {
        apiVersion: "workspace.devfile.io/v1alpha2", kind: "DevWorkspace", metadata: {
            name: "minimal-dw",
            namespace: loadTestNamespace,
            labels: {
                [labelKey]: labelType
            }
        }, spec: {
            started: true, template: {
                attributes: {
                    "controller.devfile.io/storage-type": "ephemeral",
                }, components: [{
                    name: "dev", container: {
                        image: "registry.access.redhat.com/ubi9/ubi-micro:9.6-1752751762",
                        command: ["sleep", "3600"],
                        imagePullPolicy: "IfNotPresent",
                        memoryLimit: "64Mi",
                        memoryRequest: "32Mi",
                        cpuLimit: "200m",
                        cpuRequest: "100m"
                    },
                },],
            },
        },
    };
}

/**
 * Detect cluster type (OpenShift vs Kubernetes) and set appropriate ETCD namespace/pod pattern
 * @param {string} apiServer - Kubernetes API server URL
 * @param {Object} headers - HTTP headers with authentication
 * @returns {Object} Object with etcdNamespace and etcdPodPattern
 */
export function detectClusterType(apiServer, headers) {
    const apiGroupsUrl = `${apiServer}/apis`;
    const res = http.get(apiGroupsUrl, {headers});

    let etcdNamespace = 'openshift-etcd';
    let etcdPodPattern = 'etcd';

    if (res.status === 200) {
        try {
            const data = JSON.parse(res.body);
            const groups = data.groups || [];
            const hasOpenShiftRoutes = groups.some(g => g.name === 'route.openshift.io');

            if (!hasOpenShiftRoutes) {
                etcdNamespace = __ENV.ETCD_NAMESPACE || 'kube-system';
                etcdPodPattern = __ENV.ETCD_POD_NAME_PATTERN || 'kube-proxy';
                console.log('Detected Kubernetes cluster - using kube-system namespace with kube-proxy');
            }
        } catch (e) {
            console.warn(`Failed to detect cluster type: ${e.message}, using defaults`);
        }
    }

    return {
        etcdNamespace,
        etcdPodPattern,
    };
}

/**
 * Check DevWorkspace operator metrics (CPU and memory)
 * @param {string} apiServer - Kubernetes API server URL
 * @param {Object} headers - HTTP headers with authentication
 * @param {string} operatorNamespace - Operator namespace
 * @param {number} maxCpuMillicores - Max CPU threshold in millicores
 * @param {number} maxMemoryBytes - Max memory threshold in bytes
 * @param {Object} metrics - Metrics object with operatorCpu, operatorMemory, operatorCpuViolations, operatorMemViolations
 * @param {Object} operatorPodRestarts - Pod restart counter metric
 * @param {string} operatorPodSelector - Label selector for operator pods
 * @param {Object} initialOperatorRestarts - Initial restart counts to subtract (optional)
 */
export function checkDevWorkspaceOperatorMetrics(apiServer, headers, operatorNamespace, maxCpuMillicores, maxMemoryBytes, metrics, operatorPodRestarts, operatorPodSelector, initialOperatorRestarts = {}) {
    const metricsUrl = `${apiServer}/apis/metrics.k8s.io/v1beta1/namespaces/${operatorNamespace}/pods`;
    const res = http.get(metricsUrl, {headers});

    if (res.status !== 200) {
        return;
    }

    const data = JSON.parse(res.body);
    const operatorPods = data.items.filter(p => p.metadata.name.includes("devworkspace-controller"));

    for (const pod of operatorPods) {
        const container = pod.containers[0];
        const name = pod.metadata.name;

        const cpu = parseCpuToMillicores(container.usage.cpu);
        const memory = parseMemoryToBytes(container.usage.memory);

        metrics.operatorCpu.add(cpu);
        metrics.operatorMemory.add(memory / 1024 / 1024);

        const cpuOk = cpu <= maxCpuMillicores;
        const memOk = memory <= maxMemoryBytes;

        if (!cpuOk) {
            metrics.operatorCpuViolations.add(1);
        }
        if (!memOk) {
            metrics.operatorMemViolations.add(1);
        }
    }

    checkPodRestarts(apiServer, headers, operatorNamespace, operatorPodSelector, operatorPodRestarts, initialOperatorRestarts);
}

/**
 * Check etcd metrics (CPU and memory)
 * @param {string} apiServer - Kubernetes API server URL
 * @param {Object} headers - HTTP headers with authentication
 * @param {string} etcdNamespace - ETCD namespace
 * @param {string} etcdPodPattern - ETCD pod name pattern
 * @param {Object} metrics - Metrics object with etcdCpu, etcdMemory
 * @param {Object} etcdPodRestarts - Pod restart counter metric
 * @param {string} etcdPodSelector - Label selector for etcd pods
 * @param {Object} initialEtcdRestarts - Initial restart counts to subtract (optional)
 */
export function checkEtcdMetrics(apiServer, headers, etcdNamespace, etcdPodPattern, metrics, etcdPodRestarts, etcdPodSelector, initialEtcdRestarts = {}) {
    if (!etcdNamespace || !etcdPodPattern) {
        console.warn(`[ETCD METRICS] Variables not initialized: etcdNamespace=${etcdNamespace}, etcdPodPattern=${etcdPodPattern}`);
        return;
    }

    const metricsUrl = `${apiServer}/apis/metrics.k8s.io/v1beta1/namespaces/${etcdNamespace}/pods`;
    const res = http.get(metricsUrl, {headers});

    if (res.status !== 200) {
        return;
    }

    const data = JSON.parse(res.body);
    const etcdPods = data.items.filter(p => p.metadata.name.includes(etcdPodPattern));

    if (etcdPods.length === 0) {
        if (data.items && data.items.length > 0) {
            const podNames = data.items.map(p => p.metadata.name).join(', ');
            console.warn(`[ETCD METRICS] No pods found matching pattern '${etcdPodPattern}' in namespace '${etcdNamespace}'. Available pods: ${podNames}`);
        } else {
            console.warn(`[ETCD METRICS] No pods found in namespace '${etcdNamespace}'`);
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

        metrics.etcdCpu.add(cpu);
        metrics.etcdMemory.add(memory / 1024 / 1024);
    }

    checkPodRestarts(apiServer, headers, etcdNamespace, etcdPodSelector, etcdPodRestarts, initialEtcdRestarts);
}

/**
 * Create filtered summary report with only allowed metrics
 * @param {Object} data - k6 summary data
 * @param {Array} allowedMetrics - Array of allowed metric names
 * @returns {Object} Filtered data object
 */
export function createFilteredSummaryData(data, allowedMetrics) {
    const filteredData = JSON.parse(JSON.stringify(data));
    for (const key of Object.keys(filteredData.metrics)) {
        if (!allowedMetrics.includes(key)) {
            delete filteredData.metrics[key];
        }
    }
    return filteredData;
}