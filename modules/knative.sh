#!/bin/bash

# Knative Serving via the Knative Operator (Helm).
#
# Reference install (captured from a one-click / lab cluster, kubeconfig not committed):
#   helm list -A  →  release knative-operator, ns knative-operator, chart knative-operator-1.18.3
#   helm get values knative-operator -n knative-operator  →  null (chart defaults only)
#   kubectl get knativeserving knative-serving -n knative-serving -o yaml  →
#     spec.version: 1.18.2
#     spec.ingress.kourier.enabled: true
#     spec.config.network.ingress-class: kourier.ingress.networking.knative.dev
#   (no spec.config.autoscaler / spec.config.features in CR; ConfigMaps carried defaults + _example only)
#
# Defaults below match that recipe. Override for air-gap, upgrades, or A/B:
#   KNATIVE_OPERATOR_HELM_REPO_URL, KNATIVE_OPERATOR_HELM_CHART_VERSION, KNATIVE_SERVING_VERSION
#   KNATIVE_OPERATOR_HELM_VALUES_FILE  — if set, passed as  -f "$file"  to helm upgrade --install
#   KNATIVE_SERVING_EXTENDED_RUNAI_CONFIG=true  — add autoscaler + feature flags (legacy YAML installer behavior)
#   KNATIVE_SERVING_INTERNAL_MANIFEST — path to KnativeServing patch after bootstrap (default: tools/knative-internal.yaml)

KNATIVE_OPERATOR_HELM_REPO_NAME="${KNATIVE_OPERATOR_HELM_REPO_NAME:-knative-operator}"
KNATIVE_OPERATOR_HELM_REPO_URL="${KNATIVE_OPERATOR_HELM_REPO_URL:-https://knative.github.io/operator}"
# Helm --version matches published chart tags (helm search repo knative-operator/knative-operator --versions).
KNATIVE_OPERATOR_HELM_CHART_VERSION="${KNATIVE_OPERATOR_HELM_CHART_VERSION:-v1.18.3}"
# Operator 1.18.3 on the reference cluster reconciled Serving 1.18.2 (see status.version / spec.version).
KNATIVE_SERVING_VERSION="${KNATIVE_SERVING_VERSION:-1.18.2}"
KNATIVE_OPERATOR_NAMESPACE="${KNATIVE_OPERATOR_NAMESPACE:-knative-operator}"
KNATIVE_OPERATOR_RELEASE="${KNATIVE_OPERATOR_RELEASE:-knative-operator}"

runai_knative_ensure_helm_repo() {
    if ! helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$KNATIVE_OPERATOR_HELM_REPO_NAME"; then
        if ! log_command "helm repo add \"$KNATIVE_OPERATOR_HELM_REPO_NAME\" \"$KNATIVE_OPERATOR_HELM_REPO_URL\"" "Add Knative Operator Helm repo"; then
            echo -e "${RED}❌ Failed to add Knative Operator Helm repo${NC}" >&2
            return 1
        fi
    fi
    if ! log_command "helm repo update \"$KNATIVE_OPERATOR_HELM_REPO_NAME\"" "Update Knative Operator Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: helm repo update failed for $KNATIVE_OPERATOR_HELM_REPO_NAME${NC}" >&2
        return 1
    fi
    return 0
}

runai_knative_wait_serving_ready() {
    local max_s="${1:-600}"
    local elapsed=0
    echo -e "${BLUE}Waiting for KnativeServing (ready, up to ${max_s}s)...${NC}"
    while [ "$elapsed" -lt "$max_s" ]; do
        local st reason
        st=$(kubectl get knativeserving knative-serving -n knative-serving -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [ "$st" = "True" ]; then
            echo -e "${GREEN}✅ KnativeServing is Ready${NC}"
            return 0
        fi
        reason=$(kubectl get knativeserving knative-serving -n knative-serving -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason} {.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
        if [ -n "$reason" ] && [ "$elapsed" -ge 30 ]; then
            echo -e "${YELLOW}… KnativeServing not ready yet: ${reason}${NC}"
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo -e "${RED}❌ Timed out waiting for KnativeServing to become Ready${NC}" >&2
    if [ -n "${LOG_FILE:-}" ]; then
        { echo "==== KnativeServing status (debug) ===="; kubectl get knativeserving knative-serving -n knative-serving -o yaml 2>/dev/null | tail -n 120; } >>"$LOG_FILE" 2>/dev/null || true
    fi
    return 1
}

# Merge internal Serving profile (domain, HA, Kourier ClusterIP, config-features, …) from tools/knative-internal.yaml.
runai_knative_apply_internal_manifest() {
    local base_dir install_root src tmp
    base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    install_root="${RUNAI_INSTALLER_DIR:-$(cd "$base_dir/.." && pwd)}"
    src="${KNATIVE_SERVING_INTERNAL_MANIFEST:-$install_root/tools/knative-internal.yaml}"
    if [ ! -f "$src" ]; then
        echo -e "${YELLOW}⚠️ Knative internal manifest not found ($src); skipping${NC}" >&2
        return 0
    fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/runai-knative-internal.XXXXXX.yaml")" || return 1
    if ! sed "s|^  version: .*|  version: \"${KNATIVE_SERVING_VERSION}\"|" "$src" >"$tmp"; then
        rm -f "$tmp"
        echo -e "${RED}❌ Failed to prepare Knative internal manifest${NC}" >&2
        return 1
    fi
    if ! log_command "kubectl apply -f \"$tmp\"" "Apply KnativeServing internal profile ($src)"; then
        rm -f "$tmp"
        echo -e "${RED}❌ Failed to apply Knative internal manifest${NC}" >&2
        return 1
    fi
    rm -f "$tmp"
    return 0
}

# Write KnativeServing CR matching reference cluster, optionally with legacy Run.ai feature overrides.
runai_knative_write_serving_cr() {
    local out="$1"
    {
        cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: knative-serving
---
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: knative-serving
spec:
  version: "${KNATIVE_SERVING_VERSION}"
  ingress:
    kourier:
      enabled: true
  config:
    network:
      ingress-class: kourier.ingress.networking.knative.dev
EOF
        if [ "${KNATIVE_SERVING_EXTENDED_RUNAI_CONFIG:-false}" = true ] || [ "${KNATIVE_SERVING_EXTENDED_RUNAI_CONFIG:-0}" = 1 ]; then
            cat <<'EOF'
    autoscaler:
      enable-scale-to-zero: "true"
    features:
      kubernetes.podspec-schedulername: "enabled"
      kubernetes.podspec-nodeselector: "enabled"
      kubernetes.podspec-affinity: "enabled"
      kubernetes.podspec-tolerations: "enabled"
      kubernetes.podspec-volumes-emptydir: "enabled"
      kubernetes.podspec-securitycontext: "enabled"
      kubernetes.containerspec-addcapabilities: "enabled"
      kubernetes.podspec-persistent-volume-claim: "enabled"
      kubernetes.podspec-persistent-volume-write: "enabled"
      multi-container: "enabled"
      kubernetes.podspec-init-containers: "enabled"
      kubernetes.podspec-fieldref: "enabled"
EOF
        fi
    } >"$out"
}

# Install Knative Serving: Helm knative-operator (defaults) + KnativeServing CR (Kourier), same shape as reference cluster.
install_knative() {
    echo -e "${BLUE}Installing Knative (operator chart ${KNATIVE_OPERATOR_HELM_CHART_VERSION}, Serving ${KNATIVE_SERVING_VERSION})...${NC}"
    if [ "${KNATIVE_SERVING_EXTENDED_RUNAI_CONFIG:-false}" = true ] || [ "${KNATIVE_SERVING_EXTENDED_RUNAI_CONFIG:-0}" = 1 ]; then
        echo -e "${BLUE}  (KNATIVE_SERVING_EXTENDED_RUNAI_CONFIG: extra autoscaler + feature flags)${NC}"
    fi

    if ! runai_knative_ensure_helm_repo; then
        return 1
    fi

    local helm_install_cmd
    helm_install_cmd="helm upgrade --install \"$KNATIVE_OPERATOR_RELEASE\" \"$KNATIVE_OPERATOR_HELM_REPO_NAME/knative-operator\" \
        --namespace \"$KNATIVE_OPERATOR_NAMESPACE\" \
        --create-namespace \
        --version \"$KNATIVE_OPERATOR_HELM_CHART_VERSION\" \
        --wait --timeout 15m"
    if [ -n "${KNATIVE_OPERATOR_HELM_VALUES_FILE:-}" ] && [ -f "${KNATIVE_OPERATOR_HELM_VALUES_FILE}" ]; then
        helm_install_cmd="${helm_install_cmd} -f \"${KNATIVE_OPERATOR_HELM_VALUES_FILE}\""
    fi

    if ! log_command "$helm_install_cmd" "Helm install/upgrade Knative Operator"; then
        echo -e "${RED}❌ Knative Operator Helm install failed${NC}" >&2
        return 1
    fi

    if ! log_command "kubectl rollout status deployment/knative-operator -n \"$KNATIVE_OPERATOR_NAMESPACE\" --timeout=300s" "Wait for knative-operator deployment"; then
        echo -e "${RED}❌ knative-operator deployment did not become ready${NC}" >&2
        return 1
    fi

    local cr_file
    cr_file="$(mktemp "${TMPDIR:-/tmp}/runai-knative-serving.XXXXXX.yaml")" || return 1
    runai_knative_write_serving_cr "$cr_file"

    if ! log_command "kubectl apply -f \"$cr_file\"" "Apply KnativeServing CR (Kourier + network)"; then
        rm -f "$cr_file"
        echo -e "${RED}❌ Failed to apply KnativeServing${NC}" >&2
        return 1
    fi
    rm -f "$cr_file"

    if ! runai_knative_wait_serving_ready 600; then
        return 1
    fi

    echo -e "${BLUE}Applying internal KnativeServing profile (tools/knative-internal.yaml)...${NC}"
    if ! runai_knative_apply_internal_manifest; then
        return 1
    fi
    if ! runai_knative_wait_serving_ready 600; then
        return 1
    fi

    echo -e "${GREEN}✅ Knative installation completed (operator + Serving ${KNATIVE_SERVING_VERSION})${NC}"
    return 0
}
