# DevWorkspace Operator Load testing using k6

## What is K6?

[k6](https://github.com/grafana/k6) is a modern load testing tool from Grafana. It can be run as a standalone CLI tool or 
as a Kubernetes Operator.

## Prerequisites
- Access to a Kubernetes Cluster
- DevWorkspace Operator should be installed on that cluster

## Installing K6
You can install k6 binary via various package managers on Linux/MacOS systems (see [installtion guide](https://grafana.com/docs/k6/latest/set-up/install-k6/))

If you want to install k6 as an operator, read [Install K6 Operator](https://grafana.com/docs/k6/latest/set-up/set-up-distributed-k6/install-k6-operator/) guide here.

## Running load test from outside Kubernetes Cluster
For defining load test in k6, you need to define load test in a javascript file. In this project you can find this in
- [devworkspace_load_test.js](./devworkspace_load_test.js)

Once you've defined test specifications in script you can run it with k6 binary:
```shell
k6 run devworkspace_load_test.js
```

In our case, I've created a script [runk6.sh](./runk6.sh) that runs load test. It does the following things:
- Create ClusterRole, ClusterRoleBinding and ServiceAccount for load testing (we create DevWorkspace using Kubenretes REST API)
- Define environment variables for Kubernetes APIServer, token, etc.
```shell
sh runk6.sh
```

In a separate terminal window, you can check DevWorkspaces getting created in `loadtest-devworkspaces` namespace
## Running load test as a Pod in Kubernetes Cluster
For running load test as a Pod in Kubernetes Cluster, you would need to load the test script into a ConfigMap first:
```shell
kubectl create configmap $CONFIGMAP_NAME \
  --from-file=script.js=$SCRIPT_FILE \
  --namespace $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -
```
In order to start running test, we need to create `TestRun` CustomResource like this:
```shell
cat <<EOF | kubectl apply -f -
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: $K6_CR_NAME
  namespace: $NAMESPACE
spec:
  parallelism: 1
  script:
    configMap:
      name: $CONFIGMAP_NAME
      file: script.js
  runner:
    serviceAccountName: $SA_NAME
EOF
```

You can inspect test logs like this:
```shell
kubectl get pods -n $NAMESPACE -l k6_cr=$K6_CR_NAME
```

In our case, I've created a script [runk6-in-cluster.sh](./runk6-in-cluster.sh) that runs load test. It does the following things:
- Create ClusterRole, ClusterRoleBinding and ServiceAccount for load testing (we create DevWorkspace using Kubernetes REST API)
- Create TestRun CustomResource
- Watch pod logs for test output
```shell
sh runk6-in-cluster.sh
```

In a separate terminal window, you can check DevWorkspaces getting created in `loadtest-devworkspaces` namespace

## Running load tests with auto mounted ConfigMap and Secret

In order to test DevWorkspace Operator to test its effect on memory usage by creating [automount configmaps and secrets](https://github.com/devfile/devworkspace-operator/blob/main/docs/additional-configuration.adoc#automatically-mounting-volumes-configmaps-and-secrets), use `CREATE_AUTOMOUNT_RESOURCES` environment variable while running 
load test like this:
```shell
CREATE_AUTOMOUNT_RESOURCES="true" runk6.sh
```