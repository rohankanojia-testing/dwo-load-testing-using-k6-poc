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
    return http.post(baseUrl, payload, {headers});
}

export function doHttpPatchDevWorkspaceUpdate(apiServer, headers, namespace, dwManifest, dwName) {
    const baseUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces/${dwName}`;

    const payload = JSON.stringify(dwManifest);
    return http.patch(baseUrl, payload, {headers});
}

export function doHttpPatchPodDevWorkspaceUpdate(apiServer, headers, namespace, dwManifest, pod) {
    const baseUrl = `${apiServer}/api/v1/namespaces/${namespace}/pods/${pod.metadata?.name}`;

    const payload = JSON.stringify(dwManifest);
    return http.patch(baseUrl, payload, {headers});
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
 * @param {Object} restartCounterMetric - k6 Counter metric to track restarts (optional)
 * @returns {Object} Object with totalRestarts count and details array
 */
export function checkPodRestarts(apiServer, headers, namespace, labelSelector, restartCounterMetric = null) {
    const currentRestartCounts = getPodRestartCounts(apiServer, headers, namespace, labelSelector);

    Object.entries(currentRestartCounts).forEach(([, currentRestartCount]) => {
        if (restartCounterMetric) {
            restartCounterMetric.add(currentRestartCount);
        }
    });
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