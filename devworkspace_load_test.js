import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { htmlReport } from "https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js";
import { textSummary } from "https://jslib.k6.io/k6-summary/0.0.1/index.js";

const apiServer = __ENV.KUBE_API;
const token = __ENV.KUBE_TOKEN;
const namespace = __ENV.NAMESPACE || 'default';

const headers = {
  Authorization: `Bearer ${token}`,
  'Content-Type': 'application/json',
};

export const options = {
  scenarios: {
    create_and_delete_devworkspaces: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 5 },
        { duration: '3m', target: 10 },
        { duration: '5m', target: 25 },
        { duration: '2m', target: 35 },
        { duration: '2m', target: 50 },
        { duration: '1m', target: 25 },
        { duration: '1m', target: 0 },
      ],
      gracefulRampDown: '5m',
    },
    final_cleanup: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      startTime: '15m',
      exec: 'final_cleanup',
    },
  },
  thresholds: {
    'checks': ['rate>0.95'],
    'devworkspace_create_duration': ['p(95)<15000'],
    'devworkspace_delete_duration': ['p(95)<10000'],
    'devworkspace_ready_duration': ['p(95)<60000'],
    'devworkspace_ready_failed': ['count<5'],
  },
  insecureSkipTLSVerify: true,  // trust self-signed certs like in CRC
};

const devworkspaceCreateDuration = new Trend('devworkspace_create_duration');
const devworkspaceDeleteDuration = new Trend('devworkspace_delete_duration');
const devworkspaceReadyDuration = new Trend('devworkspace_ready_duration');
const devworkspaceReadyFailed = new Counter('devworkspace_ready_failed');

function generateManifest(vuId, iteration, namespace) {
  const name = `dw-test-${vuId}-${iteration}`;

  return {
    apiVersion: "workspace.devfile.io/v1alpha2",
    kind: "DevWorkspace",
    metadata: {
      name: name,
      namespace: namespace,
    },
    spec: {
      started: true,
      template: {
        attributes: {
          "controller.devfile.io/storage-type": "ephemeral",
        },
        components: [
          {
            name: "dev",
            container: {
              image: "busybox:latest",
              command: ["sleep", "3600"],
              imagePullPolicy: "IfNotPresent",
              memoryLimit: "64Mi",
              memoryRequest: "32Mi",
              cpuLimit: "200m",
              cpuRequest: "100m"
            },
          },
        ],
      },
    },
  };
}

export default function () {
  const vuId = __VU;
  const iteration = __ITER;
  const crName = `dw-test-${vuId}-${iteration}`;
  const namespace = __ENV.NAMESPACE || 'default';
  const apiServer = __ENV.KUBE_API;
  if (!apiServer) {
      throw new Error('KUBE_API env var is required');
  }
  const baseUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces`;

  // Replace placeholders and create resource
  const manifest = generateManifest(vuId, iteration, namespace);

  const payload = JSON.stringify(manifest);

  const createStart = Date.now();
  const createRes = http.post(baseUrl, payload, { headers });
  devworkspaceCreateDuration.add(Date.now() - createStart);

  check(createRes, {
    'DevWorkspace created': (r) => r.status === 201 || r.status === 409,
  });

  if (createRes.status !== 201 && createRes.status !== 409) {
    console.error(`[VU ${vuId}] Failed to create DevWorkspace: ${createRes.status}, ${createRes.body}`);
    return;
  }

  // Wait until status.phase == "Ready"
  const readyStart = Date.now();
  let isReady = false;
  let isBeingDeleted = false;
  let attempts = 0;
  const maxAttempts = 60;

  while (!isReady && attempts < maxAttempts) {
    const res = http.get(`${baseUrl}/${crName}`, { headers });

    if (res.status === 200) {
      try {
        const body = JSON.parse(res.body);
        const phase = body?.status?.phase;
        isBeingDeleted = !!body.metadata?.deletionTimestamp;
        if (phase === 'Ready') {
          isReady = true;
          break;
        }
      } catch (_) {
        console.error(`GET [VU ${vuId}] Failed to parse DevWorkspace from API: ${res.body}`);
      }
    }

    sleep(5);
    attempts++;
  }

  if (!isBeingDeleted) {
    if (isReady) {
      devworkspaceReadyDuration.add(Date.now() - readyStart);
    } else {
      devworkspaceReadyFailed.add(1);
      console.warn(`[VU ${vuId}] DevWorkspace ${crName} not ready after ${maxAttempts * 5}s`);
    }
  }

  sleep(10);

  // Delete the DevWorkspace
  const deleteStart = Date.now();
  const delRes = http.del(`${baseUrl}/${crName}`, null, { headers });
  devworkspaceDeleteDuration.add(Date.now() - deleteStart);

  check(delRes, {
    'DevWorkspace deleted or not found': (r) => r.status === 200 || r.status === 404,
  });

  sleep(5);
}

export function final_cleanup() {
  const baseUrl = `${apiServer}/apis/workspace.devfile.io/v1alpha2/namespaces/${namespace}/devworkspaces`;
  console.log(`[CLEANUP] Deleting all DevWorkspaces in ${namespace}`);

  const res = http.get(baseUrl, { headers });

  if (res.status !== 200) {
    console.error(`[CLEANUP] Failed to list DevWorkspaces: ${res.status}`);
    return;
  }

  const body = JSON.parse(res.body);
  if (!body.items || !Array.isArray(body.items)) return;

  for (const item of body.items) {
    const name = item.metadata.name;
    const delRes = http.del(`${baseUrl}/${name}`, null, { headers });
    if (delRes.status !== 200 && delRes.status !== 404) {
      console.warn(`[CLEANUP] Failed to delete ${name}: ${delRes.status}`);
    }
  }
}

export function handleSummary(data) {
  return {
    "devworkspace-load-test-report.html": htmlReport(data, {
      title: "DevWorkspace Operator Load Test Report (HTTP)",
    }),
    stdout: textSummary(data, { indent: " ", enableColors: true }),
  };
}

