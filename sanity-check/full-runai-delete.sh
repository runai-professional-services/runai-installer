#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Non-interactive mode (for runai-installer.sh --uninstall -y)
UNINSTALL_AUTO_YES=false
if [ "${RUNAI_AUTO_YES:-false}" = true ] || [ "${RUNAI_AUTO_YES:-0}" = 1 ]; then
    UNINSTALL_AUTO_YES=true
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            UNINSTALL_AUTO_YES=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# One-line: what we're doing ... --> OK | skipped | FAIL
_runai_line_ok()    { echo -e "${BLUE}$1${NC} ${GREEN}--> OK${NC}"; }
# Nothing to remove (already uninstalled / not present) — not an error.
_runai_line_none()  { echo -e "${BLUE}$1${NC} ${GREEN}--> OK (nothing to remove)${NC}"; }
_runai_line_fail()  { echo -e "${BLUE}$1${NC} ${RED}--> FAIL${NC}"; }
_runai_line_warn()  { echo -e "${BLUE}$1${NC} ${YELLOW}--> $2${NC}"; }

confirm_or_auto_yes() {
    local prompt="$1"
    local mode="${2:-upper}"
    local response=""
    if [ "$UNINSTALL_AUTO_YES" = true ]; then
        return 0
    fi
    echo -e "${RED}${prompt}${NC}"
    read -r response
    if [ "$mode" = "upper" ]; then
        [[ "$response" = "Y" ]]
    else
        [[ "$response" =~ ^[Yy]$ ]]
    fi
}

if [ "$UNINSTALL_AUTO_YES" != true ]; then
    echo -e "${RED}WARNING: This removes all Run.ai resources from the cluster (cannot undo).${NC}"
fi

if ! confirm_or_auto_yes "Proceed? (Y/N)" "upper"; then
    echo -e "${YELLOW}Cancelled.${NC}"
    exit 1
fi

if ! confirm_or_auto_yes "Confirm again: delete ALL Run.ai resources? (Y/N)" "upper"; then
    echo -e "${YELLOW}Cancelled.${NC}"
    exit 1
fi

# Mutating/validating webhooks must go before runaiconfig patch if operator Service is gone.
_runai_delete_runai_admission_webhooks() {
    local obj
    for obj in $(kubectl get mutatingwebhookconfiguration -o name 2>/dev/null | grep -Ei 'runai|run\.ai' || true); do
        kubectl delete "$obj" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    for obj in $(kubectl get validatingwebhookconfiguration -o name 2>/dev/null | grep -Ei 'runai|run\.ai' || true); do
        kubectl delete "$obj" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    _runai_line_ok "Uninstalling Run.ai admission webhooks"
}
_runai_delete_runai_admission_webhooks

kubectl patch runaiconfigs.run.ai/runai -n runai -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
if kubectl -n runai get runaiconfig runai >/dev/null 2>&1; then
    if kubectl -n runai delete runaiconfig runai --force --grace-period=0 --wait=false >/dev/null 2>&1; then
        for _i in {1..10}; do
            if ! kubectl -n runai get runaiconfig runai >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
    fi
    if kubectl -n runai get runaiconfig runai >/dev/null 2>&1; then
        _runai_line_warn "Uninstalling RunAiConfig runai/runai" "still terminating (continuing)"
    else
        _runai_line_ok "Uninstalling RunAiConfig runai/runai"
    fi
else
    _runai_line_ok "Uninstalling RunAiConfig runai/runai"
fi

helm_release_exists() {
    local release="$1"
    local namespace="$2"
    helm list -n "$namespace" -q 2>/dev/null | grep -Fxq "$release"
}

# Discard Helm stdout/stderr on success (avoids release-secret WARN spam); show output only on failure.
safe_helm_uninstall() {
    local release="$1"
    local namespace="$2"
    local tmp rc
    tmp="$(mktemp "${TMPDIR:-/tmp}/runai-helm-un.XXXXXX")" || tmp=/tmp/runai-helm-un.$$

    if command -v timeout >/dev/null 2>&1; then
        timeout 180s helm uninstall "$release" -n "$namespace" --timeout 120s >"$tmp" 2>&1
    else
        helm uninstall "$release" -n "$namespace" --timeout 120s >"$tmp" 2>&1
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$tmp"
        return 0
    fi

    if command -v timeout >/dev/null 2>&1; then
        timeout 180s helm uninstall "$release" -n "$namespace" --no-hooks --timeout 120s >"$tmp" 2>&1
    else
        helm uninstall "$release" -n "$namespace" --no-hooks --timeout 120s >"$tmp" 2>&1
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$tmp"
        return 0
    fi
    cat "$tmp" >&2
    rm -f "$tmp"
    return 1
}

delete_helm_releases() {
    if helm_release_exists "runai-backend" "runai-backend"; then
        if safe_helm_uninstall "runai-backend" "runai-backend"; then
            _runai_line_ok "Uninstalling Helm release runai-backend (namespace runai-backend)"
        else
            _runai_line_fail "Uninstalling Helm release runai-backend (namespace runai-backend)"
        fi
    else
        _runai_line_none "Uninstalling Helm release runai-backend (namespace runai-backend)"
    fi

    local runai_release=""
    if helm_release_exists "runai" "runai"; then
        runai_release="runai"
    elif helm_release_exists "runai-cluster" "runai"; then
        runai_release="runai-cluster"
    fi

    if [ -n "$runai_release" ]; then
        if safe_helm_uninstall "$runai_release" "runai"; then
            _runai_line_ok "Uninstalling Helm release ${runai_release} (namespace runai)"
        else
            _runai_line_fail "Uninstalling Helm release ${runai_release} (namespace runai)"
        fi
    else
        _runai_line_none "Uninstalling Helm release runai / runai-cluster (namespace runai)"
    fi
}

delete_runai_cluster_rbac() {
    local obj
    for obj in $(kubectl get clusterrolebinding -o name 2>/dev/null | grep -Ei 'runai|run\.ai' || true); do
        kubectl delete "$obj" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    for obj in $(kubectl get clusterrole -o name 2>/dev/null | grep -Ei 'runai|run\.ai' || true); do
        kubectl delete "$obj" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    _runai_line_ok "Uninstalling Run.ai ClusterRoles / ClusterRoleBindings"
}

delete_helm_releases
delete_runai_cluster_rbac

if ! confirm_or_auto_yes "Full cleanup (namespaces, CRDs)? [y/N]" "lower"; then
    echo -e "${YELLOW}Stopped before namespace/CRD cleanup (not requested).${NC}"
    exit 0
fi

_purge_namespace_resources() {
    local ns=$1
    local timeout=${2:-30s}
    local rt remaining resource
    kubectl get namespace "$ns" &>/dev/null || return 0
    for rt in pods secrets jobs statefulsets persistentvolumeclaims deployments replicasets services roles rolebindings serviceaccounts configmaps; do
        if ! kubectl get "$rt" -n "$ns" --no-headers >/dev/null 2>&1; then
            continue
        fi
        if ! kubectl delete "$rt" -n "$ns" --all --timeout="$timeout" >/dev/null 2>&1; then
            remaining=$(kubectl get "$rt" -n "$ns" -o name 2>/dev/null)
            for resource in $remaining; do
                kubectl patch "$resource" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1
                kubectl delete "$resource" -n "$ns" --force --grace-period=0 >/dev/null 2>&1
            done
        fi
    done
}

delete_crds() {
    local crds crd_name resources resource
    crds=$(kubectl get crd -o name | grep -E "run\.ai|runai\.run\.ai" 2>/dev/null)
    if [ -z "$crds" ]; then
        _runai_line_none "Uninstalling Run.ai CRDs"
        return 0
    fi
    for crd in $crds; do
        crd_name=$(echo "$crd" | cut -d/ -f2)
        if kubectl get "$crd_name" &>/dev/null; then
            resources=$(kubectl get "$crd_name" -o name 2>/dev/null)
            for resource in $resources; do
                kubectl patch "$resource" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1
            done
        fi
        if ! kubectl delete "$crd" --timeout=30s >/dev/null 2>&1; then
            kubectl patch "$crd" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1
            kubectl delete "$crd" --force --grace-period=0 >/dev/null 2>&1
        fi
    done
    _runai_line_ok "Uninstalling Run.ai CRDs"
}

force_delete_namespace() {
    local namespace=$1
    local delete_pid

    if ! kubectl get namespace "$namespace" &>/dev/null; then
        _runai_line_none "Uninstalling namespace ${namespace}"
        return 0
    fi

    kubectl delete namespace "$namespace" --force --grace-period=0 >/dev/null 2>&1 &
    delete_pid=$!

    local _i
    for _i in {1..10}; do
        if ! kill -0 "$delete_pid" 2>/dev/null; then
            if ! kubectl get namespace "$namespace" &>/dev/null; then
                _runai_line_ok "Uninstalling namespace ${namespace}"
                return 0
            fi
            break
        fi
        sleep 1
    done

    if kill -0 "$delete_pid" 2>/dev/null; then
        kill "$delete_pid" 2>/dev/null || true
    fi

    if kubectl get namespace "$namespace" &>/dev/null; then
        kubectl proxy --port=8001 >/dev/null 2>&1 &
        local proxy_pid=$!
        sleep 2
        kubectl get namespace "$namespace" -o json | jq '.spec = {"finalizers":[]}' >temp.json 2>/dev/null || true
        curl -k -sS -H "Content-Type: application/json" -X PUT --data-binary @temp.json "127.0.0.1:8001/api/v1/namespaces/$namespace/finalize" &>/dev/null || true
        rm -f temp.json
        kill "$proxy_pid" 2>/dev/null || true

        for _i in {1..30}; do
            if ! kubectl get namespace "$namespace" &>/dev/null; then
                _runai_line_ok "Uninstalling namespace ${namespace}"
                return 0
            fi
            sleep 1
        done
        _runai_line_fail "Uninstalling namespace ${namespace}"
        return 1
    fi
    _runai_line_ok "Uninstalling namespace ${namespace}"
    return 0
}

_purge_namespace_resources runai
_runai_line_ok "Clearing API objects in namespace runai"

_purge_namespace_resources runai-backend
_runai_line_ok "Clearing API objects in namespace runai-backend"

delete_crds

force_delete_namespace runai
force_delete_namespace runai-backend
force_delete_namespace runai-cluster

_runai_line_ok "Run.ai uninstall finished"
