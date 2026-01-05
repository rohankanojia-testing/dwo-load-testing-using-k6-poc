import http from 'k6/http';
import {check, sleep} from 'k6';
import exec from 'k6/execution';
import {SharedArray} from 'k6/data';
import {Counter, Rate, Trend, Gauge} from 'k6/metrics';
import {textSummary} from "https://jslib.k6.io/k6-summary/0.0.1/index.js";
import {
    parseCpuToMillicores,
    parseMemoryToBytes,
    generateDevWorkspaceToCreate,
    getPodForDevWorkspace,
    getDevWorkspacesFromApiServer,
    doHttpPostDevWorkspaceCreate,
    doHttpPatchDevWorkspaceUpdate,
    doHttpPatchPodDevWorkspaceUpdate,
    doHttpGetDevWorkspacesFromApiServer, createAuthHeaders
} from '../common/utils.js';

export const devWorkspacesReady = new Gauge('devworkspaces_ready');
export const execAttempted = new Counter('exec_attempted');
export const execSkipped = new Counter('exec_skipped_due_to_pod_not_ready');
export const execAllowed = new Counter('exec_allowed_total');
export const execDenied = new Counter('exec_denied_total');
export const execUnexpectedAllowed = new Counter('exec_unexpected_allowed_total');
export const execUnexpectedDenied = new Counter('exec_unexpected_denied_total');
export const execAllowRate = new Rate('exec_allow_rate');
export const execDenyRate = new Rate('exec_deny_rate');
export const execLatency = new Trend('exec_latency_ms');
export const createLatency = new Trend('create_latency_ms');
export const invalidMutatingDeny = new Counter('invalid_mutating_deny_ms');
export const mutatingWebhookLatency = new Trend('mutating_latency_ms');
export const webhookCpuMillicores = new Trend('average_webhook_cpu_millicores');
export const webhookMemoryMB = new Trend('average_webhook_memory_mb');

const NUMBER_OF_USERS = Number(__ENV.N_USERS || 50);
const TEST_NAMESPACE = __ENV.LOAD_TEST_NAMESPACE || 'dw-webhook-loadtest';
const WEBHOOK_NAMESPACE = __ENV.WEBHOOK_NAMESPACE || 'openshift-operators';
const K8S_API = __ENV.KUBE_API || 'https://api.crc.testing:6443/';
const MIN_RUNNING_DEVWORKSPACES_FRACTION = Number(__ENV.MIN_RUNNING_FRACTION || 0.8);

const devWorkspaceReadyTimeout = Number(__ENV.DEV_WORKSPACE_READY_TIMEOUT_IN_SECONDS || 120);

const users = new SharedArray('users', () => {
    const usersJsonFile = __ENV.K6_USERS_FILE;
    if (!usersJsonFile) {
        throw new Error('K6_USERS_FILE environment variable is not set');
    }
    try {
        return JSON.parse(open(usersJsonFile));
    } catch (err) {
        throw new Error(`Failed to parse K6_USERS_JSON: ${err.message}`);
    }
});

export const options = {
    vus: NUMBER_OF_USERS ,
    iterations: NUMBER_OF_USERS,
    insecureSkipTLSVerify: true,
};

export function setup() {
    const userList = users; // Accessing the SharedArray
    const createdWorkspaces = [];

    userList.forEach((user, index) => {
        const headers = createAuthHeaders(user.token);

        // Pass index as VU ID equivalent for unique naming
        const dwName = createDevWorkspace(index + 1, 0, user, TEST_NAMESPACE, headers);
        if (dwName) {
            createdWorkspaces.push({ owner: user.user, dwName: dwName });
        }
    });

    // Use the first user's token to poll for cluster-wide readiness
    const adminHeaders = createAuthHeaders(userList[0].token);

    const readyCount = waitUntilAllDevWorkspacesAreRunning(TEST_NAMESPACE, adminHeaders, userList.length);
    if (readyCount < Math.ceil(users.length * MIN_RUNNING_DEVWORKSPACES_FRACTION)) {
        console.warn(`[WARN] Only ${readyCount}/${users.length} devworkspaces ready, skipping exec for missing ones`);
    }

    console.log(`[SETUP] Environment ready. ${readyCount}/${userList.length} workspaces running.`);

    // This returned object becomes the 'data' argument in the default function
    return {
        workspaces: createdWorkspaces,
        readyCount: readyCount
    };
}

// ---------------- Main test ----------------
export default function () {
    const user = users[exec.vu.idInTest - 1];
    const headers = {
        Authorization: `Bearer ${user.token}`,
        'Content-Type': 'application/json',
    };

    const dwName = `dw-test-${exec.vu.idInTest}-0`

    // -------- PHASE 4: Exec checks --------
    const allDwNames = getAllDevWorkspaceNames(TEST_NAMESPACE, headers);
    for (const name of allDwNames) {
        const isOwn = name === dwName;

        checkExecPermission(
            headers,
            user.user,
            TEST_NAMESPACE,
            name,
            isOwn // own DW → allow, others → forbid
        );

        // Monitor webhook pod metrics after each exec check
        collectWebhookPodMetrics(headers);
    }
}

export function handleSummary(data) {
    const keep = [
        'devworkspaces_ready',
        'exec_attempted',
        'exec_skipped_due_to_pod_not_ready',
        'exec_allow_rate',
        'exec_deny_rate',
        'create_latency_ms',
        'exec_latency_ms',
        'average_webhook_cpu_millicores',
        'average_webhook_memory_mb',
        'mutating_latency_ms',
        'invalid_mutating_deny_ms',
        'exec_allowed_total',
        'exec_denied_total',
        'exec_unexpected_allowed_total',
        'exec_unexpected_denied_total',
    ];

    for (const k of Object.keys(data.metrics)) {
        if (!keep.includes(k)) {
            delete data.metrics[k];
        }
    }
    return {
        stdout: textSummary(data, {indent: ' ', enableColors: true})
    }
}

// ---------------- Generic helpers ----------------
function createDevWorkspace(vuId, iteration, user, namespace, headers) {
    const dwPayload = generateDevWorkspaceToCreate(vuId, iteration, namespace);

    const startTime = Date.now();
    const res = doHttpPostDevWorkspaceCreate(K8S_API, headers, namespace, dwPayload);

    createLatency.add(Date.now() - startTime);

    if (res.status !== 201) {
        console.error(`[ERROR] DevWorkspace creation failed for ${user.user}: ${res.status}`);
        return null;
    }

    return res.json()?.metadata?.name ?? null;
}

function validateDevWorkspaceAndRelatedResourcesImmutability(user, headers, dwName) {
    validateDevWorkspaceIdentityImmutability(headers, dwName);
    validateDevWorkspacePodIdentityImmutability(headers, dwName);
}

function validateDevWorkspaceIdentityImmutability(headers, dwName) {
    const forbiddenPatch = [
        {
            op: 'replace',
            path: '/metadata/labels/controller.devfile.io~1devworkspace_id',
            value: `invalid-${Date.now()}`,
        },
        {
            op: 'replace',
            path: '/metadata/labels/controller.devfile.io~1creator',
            value: `00000000-0000-0000-0000-000000000000`,
        },
    ];

    const patchHeaders = {
        ...headers,
        'Content-Type': 'application/json-patch+json',
    };

    const mutateDevWorkspaceStartTime = Date.now();
    const res = doHttpPatchDevWorkspaceUpdate(K8S_API, patchHeaders, TEST_NAMESPACE, forbiddenPatch, dwName);
    mutatingWebhookLatency.add(Date.now() - mutateDevWorkspaceStartTime);
    assertForbidden(res, 'DevWorkspace', dwName, "admission webhook \"mutate.devworkspace-controller.svc\" denied the request:" +
        " label 'controller.devfile.io/creator' is assigned once devworkspace is created and is immutable");
}

function validateDevWorkspacePodIdentityImmutability(headers, dwName) {
    const forbiddenPatch = [
        {
            op: 'replace',
            path: '/metadata/labels/controller.devfile.io~1devworkspace_id',
            value: `invalid-${Date.now()}`,
        },
        {
            op: 'replace',
            path: '/metadata/labels/controller.devfile.io~1creator',
            value: `00000000-0000-0000-0000-000000000000`,
        },
    ];

    const patchHeaders = {
        ...headers,
        'Content-Type': 'application/json-patch+json',
    };

    let pod = getPodForDevWorkspace(K8S_API, headers, TEST_NAMESPACE, dwName);
    if (pod == null || pod.status?.phase !== 'Running') {
        return;
    }
    let validatePodIdentityImmutability = Date.now();
    const res = doHttpPatchPodDevWorkspaceUpdate(K8S_API, patchHeaders, TEST_NAMESPACE, forbiddenPatch, pod);
    mutatingWebhookLatency.add(Date.now() - validatePodIdentityImmutability);

    assertForbidden(res, 'Pod', pod.metadata?.name, "admission webhook \"mutate-ws-resources.devworkspace-controller.svc\" denied the request: " +
        "Label 'controller.devfile.io/creator' is set by the controller and cannot be updated");
}

function waitUntilAllDevWorkspacesAreRunning(namespace, headers, expectedCount) {
    const pollInterval = 5; // seconds
    const maxAttempts = devWorkspaceReadyTimeout / pollInterval;
    let attempts = 0;

    let runningDevWorkspaces = 0;
    while (attempts < maxAttempts) {
        const { error, devWorkspaces } = getDevWorkspacesFromApiServer(K8S_API, namespace, headers, false);
        if (error) {
            console.error(`[ERROR] GET DevWorkspaces returned status ${error}`);
        } else {
            try {
                runningDevWorkspaces = devWorkspaces.filter(dw => dw.status?.phase === 'Running' || dw.status?.phase === 'Ready').length;

                if (runningDevWorkspaces >= expectedCount) return expectedCount; // all ready
            } catch (e) {
                console.error(`[ERROR] Failed to parse DevWorkspaces: ${e.message}`);
            }
        }

        sleep(pollInterval);
        attempts++;
    }

    return runningDevWorkspaces;
}

function checkExecResponse(res) {
    if (!res?.body || typeof res.body !== 'string') {
        return false;
    }

    try {
        const parsedResponse = JSON.parse(res.body);
        // HTTP failure is expected here because `exec` is a WebSocket operation.
        // The API responds with 400 + "Upgrade request required" to signal success.
        return (
            parsedResponse.code === 400 &&
            typeof parsedResponse.message === 'string' &&
            parsedResponse.message.toLowerCase().includes('upgrade request required')
        );
    } catch (e) {
        // Assume failure to parse body as not allowed
        return false;
    }
}

function checkExecPermission(headers, userName, namespace, dwName, shouldAllow = true) {
    const pod = getPodForDevWorkspace(K8S_API, headers, namespace, dwName);
    if (!pod || pod.status?.phase !== 'Running') {
        return;
    }

    const podName = pod.metadata?.name;

    // Attempt exec
    execAttempted.add(1);
    const execStartTime = Date.now();
    const execUrl = `${K8S_API}/api/v1/namespaces/${namespace}/pods/${podName}/exec?command=echo&command=hello`;

    const res = http.post(execUrl, null, { headers, timeout: '30s' });
    if (!res?.status) {
        console.error(`[ERROR] Failed to parse exec response: ${JSON.stringify(res)}`);
        execSkipped.add(1);
        return;
    }
    execLatency.add(Date.now() - execStartTime);

    const allowed = checkExecResponse(res);

    if (shouldAllow) {
        execAllowRate.add(allowed);
        if (allowed) {
            execAllowed.add(1);
        } else if (res.status === 403) {
            execUnexpectedDenied.add(1);
        } else {
            // For Server Side errors, mark exec as skipped
            execSkipped.add(1);
        }
    } else {
        execDenyRate.add(!allowed);
        if (!allowed && res.status === 403) {
            execDenied.add(1);
        } else if (allowed && res.status === 200) {
            execUnexpectedAllowed.add(1);
            console.error(`[SECURITY] Cross-user exec ALLOWED for ${dwName} for user ${userName}`);
        } else {
            // For Server Side errors, mark exec as skipped
            execSkipped.add(1);
        }
    }

    const checkName = shouldAllow
        ? 'exec allowed for own workspace'
        : 'exec forbidden for foreign workspace';

    const checkFn = () => shouldAllow ? allowed : !allowed;

    check(res, {
        [checkName]: checkFn,
    });

    return res.status;
}

function getAllDevWorkspaceNames(namespace, headers) {
    const res = doHttpGetDevWorkspacesFromApiServer(K8S_API, headers, namespace);
    if (res.status !== 200) {
        console.error(`[ERROR] Failed to list DevWorkspaces: status=${res.status}, body=${res.body}`);
        return [];
    }

    let items = [];
    try {
        items = res.json()?.items || [];
    } catch (e) {
        console.error(`[ERROR] Failed to parse DevWorkspace list: ${e.message}`);
        return [];
    }

    return items.map(dw => dw.metadata?.name).filter(Boolean);
}

function assertForbidden(res, resourceKind, resourceName, expectedMessage) {
    const body = res.json?.();

    const statusOk = res.status === 403;
    const reasonOk = body?.reason === 'Forbidden';
    const messageOk =
        body?.message?.includes(expectedMessage);

    if (!statusOk || !reasonOk || !messageOk) {
        console.error(
            `[ERROR] Unauthorized ${resourceKind} modification allowed
resource=${resourceName}
status=${res.status}
reason=${body?.reason}
message=${body?.message}
expectedMessage=${expectedMessage}`
        );
    }
    invalidMutatingDeny.add(1);
}


/**
 * Collect CPU and memory metrics from webhook pods
 * @param {Object} headers - HTTP headers
 */
function collectWebhookPodMetrics(headers) {
    const metricsUrl = `${K8S_API}/apis/metrics.k8s.io/v1beta1/namespaces/${WEBHOOK_NAMESPACE}/pods?labelSelector=app.kubernetes.io/name=devworkspace-webhook-server`;
    const res = http.get(metricsUrl, {headers});

    check(res, {
      'Fetched webhook pod metrics successfully': (r) => r.status === 200,
    });

    if (res.status !== 200) {
      return;
    }
  
    const data = JSON.parse(res.body);
    const operatorPods = data.items.filter(p => p.metadata.name.includes("devworkspace-webhook-server"));
  
    for (const pod of operatorPods) {
      const container = pod.containers[0]; // assuming single container
  
      const cpu = parseCpuToMillicores(container.usage.cpu);
      const memory = parseMemoryToBytes(container.usage.memory);

      webhookCpuMillicores.add(cpu);
      webhookMemoryMB.add(memory / 1024 / 1024);
    }
}
