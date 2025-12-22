// common/k6-utils.js
import http from 'k6/http';

const labelType = "test-type";
const labelKey = "load-test";
const externalDevWorkspaceLink = __ENV.DEVWORKSPACE_LINK || '';

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