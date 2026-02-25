provision_che_workspace_namespace() {
  local LOAD_TEST_NAMESPACE="$1"
  local CHE_NAMESPACE="$2"

  if [[ -z "${LOAD_TEST_NAMESPACE}" ]]; then
    echo "ERROR: LOAD_TEST_NAMESPACE argument is required"
    echo "Usage: provision_che_workspace_namespace <namespace> <che-namespace>"
    return 1
  fi

  if [[ -z "${CHE_NAMESPACE}" ]]; then
    echo "ERROR: CHE_NAMESPACE argument is required"
    echo "Usage: provision_che_workspace_namespace <namespace> <che-namespace>"
    return 1
  fi

  if ! command -v oc >/dev/null 2>&1; then
    echo "ERROR: oc CLI not found"
    return 1
  fi

  local USERNAME
  USERNAME="$(oc whoami)"

  local CHE_CLUSTER_NAME
  CHE_CLUSTER_NAME=$(oc get checluster -n "${CHE_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "${CHE_CLUSTER_NAME}" ]]; then
    echo "ERROR: No CheCluster found in namespace ${CHE_NAMESPACE}"
    return 1
  fi

  echo "Provisioning Che workspace namespace"
  echo "  User        : ${USERNAME}"
  echo "  Namespace   : ${LOAD_TEST_NAMESPACE}"
  echo "  CheCluster  : ${CHE_CLUSTER_NAME}"

  oc patch checluster "${CHE_CLUSTER_NAME}" \
    -n "${CHE_NAMESPACE}" \
    --type=merge \
    -p '{
      "spec": {
        "devEnvironments": {
          "defaultNamespace": {
            "autoProvision": false
          }
        }
      }
    }' >/dev/null

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${LOAD_TEST_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: che.eclipse.org
    app.kubernetes.io/component: workspaces-namespace
  annotations:
    che.eclipse.org/username: ${USERNAME}
EOF

  oc get namespace "${LOAD_TEST_NAMESPACE}" >/dev/null

  echo "✔ Namespace '${LOAD_TEST_NAMESPACE}' provisioned for user '${USERNAME}'"
}
