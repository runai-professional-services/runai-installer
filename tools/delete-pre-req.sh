#!/usr/bin/env bash
#
# Remove optional prerequisites that runai-installer.sh can install (Helm / Kustomize).
# Not invoked by the main installer. Destructive: deletes workloads, releases, and some namespaces.
#
# Usage:
#   ./delete-pre-req.sh              # prompt for confirmation
#   ./delete-pre-req.sh -y           # non-interactive
#   ./delete-pre-req.sh --dry-run    # print actions only
#
# Requires: kubectl (current context), helm. jq optional (used to find Prometheus chart releases).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN=false
AUTO_YES=false
TRAINING_OPERATOR_GIT_REF="${TRAINING_OPERATOR_GIT_REF:-v1.9.2}"

usage() {
    echo "Usage: $0 [-y] [--dry-run]"
    echo "  Removes: Prometheus (kube-prometheus-stack), Knative (operator + Serving),"
    echo "           GPU Operator, HAProxy Ingress (HAProxyTech), LWS (Local Workload Service),"
    echo "           Kubeflow Training Operator, NIM Operator."
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) AUTO_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}" >&2; usage ;;
    esac
done

if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "${RED}kubectl not found in PATH${NC}" >&2
    exit 1
fi
if ! command -v helm >/dev/null 2>&1; then
    echo -e "${RED}helm not found in PATH${NC}" >&2
    exit 1
fi

run() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run]${NC} $*"
        return 0
    fi
    "$@"
}

confirm() {
    if [ "$AUTO_YES" = true ] || [ "$DRY_RUN" = true ]; then
        return 0
    fi
    echo -e "${RED}This will uninstall Prometheus, Knative, GPU Operator, HAProxy Ingress, LWS, Training Operator, and NIM Operator from the current cluster context.${NC}"
    echo -n "Continue? [y/N] "
    read -r ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) echo "Aborted."; exit 1 ;;
    esac
}

confirm

echo -e "${BLUE}Cluster:${NC} $(kubectl config current-context 2>/dev/null || echo '?')"

# --- Helm: uninstall by release + namespace if present ---
helm_uninstall_if_exists() {
    local release=$1
    local ns=$2
    if helm status "$release" -n "$ns" >/dev/null 2>&1; then
        echo -e "${BLUE}Helm uninstall ${release} (ns ${ns})${NC}"
        run helm uninstall "$release" -n "$ns" --wait 2>/dev/null || run helm uninstall "$release" -n "$ns" || true
    else
        echo -e "${YELLOW}Skip Helm release ${release}/${ns} (not found)${NC}"
    fi
}

# --- Prometheus: installer uses release "prometheus" in monitoring + optional "prometheus-operator-crds" ---
uninstall_prometheus_stack() {
    echo -e "${BLUE}=== Prometheus (kube-prometheus-stack / operator CRDs chart) ===${NC}"
    if command -v jq >/dev/null 2>&1; then
        local pairs
        pairs=$(helm list -A -o json 2>/dev/null | jq -r '.[] | select(.chart | startswith("kube-prometheus-stack")) | "\(.name)\t\(.namespace)"' || true)
        while IFS=$'\t' read -r rel ns; do
            [ -z "${rel:-}" ] && continue
            echo -e "${BLUE}Helm uninstall ${rel} (ns ${ns}) [kube-prometheus-stack]${NC}"
            run helm uninstall "$rel" -n "$ns" --wait 2>/dev/null || run helm uninstall "$rel" -n "$ns" || true
        done <<< "$pairs"

        local crd_releases
        crd_releases=$(helm list -A -o json 2>/dev/null | jq -r '.[] | select(.chart | startswith("prometheus-operator-crds")) | "\(.name)\t\(.namespace)"' || true)
        while IFS=$'\t' read -r rel ns; do
            [ -z "${rel:-}" ] && continue
            echo -e "${BLUE}Helm uninstall ${rel} (ns ${ns}) [prometheus-operator-crds]${NC}"
            run helm uninstall "$rel" -n "$ns" --wait 2>/dev/null || run helm uninstall "$rel" -n "$ns" || true
        done <<< "$crd_releases"
    else
        helm_uninstall_if_exists prometheus monitoring
        helm_uninstall_if_exists prometheus-operator-crds monitoring
        echo -e "${YELLOW}jq not installed: skipping scan for other kube-prometheus-stack releases (install jq to remove all matches).${NC}"
    fi

    if [ "$DRY_RUN" != true ] && kubectl get ns monitoring >/dev/null 2>&1; then
        if [ -z "$(helm list -n monitoring -q 2>/dev/null)" ]; then
            echo -e "${BLUE}Deleting namespace monitoring (no Helm releases left)${NC}"
            kubectl delete ns monitoring --wait=false 2>/dev/null || true
        else
            echo -e "${YELLOW}Namespace monitoring retained (Helm releases still present).${NC}"
        fi
    elif [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run]${NC} Would delete ns monitoring if empty of Helm releases"
    fi
}

# --- Knative: KnativeServing CR, then operator Helm release, then common namespaces ---
uninstall_knative() {
    echo -e "${BLUE}=== Knative (operator + Serving) ===${NC}"
    if kubectl get knativeserving knative-serving -n knative-serving >/dev/null 2>&1; then
        echo -e "${BLUE}Delete KnativeServing knative-serving${NC}"
        run kubectl delete knativeserving knative-serving -n knative-serving --wait=false
    else
        echo -e "${YELLOW}No KnativeServing knative-serving in knative-serving${NC}"
    fi

    helm_uninstall_if_exists knative-operator knative-operator

    for ns in knative-serving knative-operator kourier-system; do
        if kubectl get ns "$ns" >/dev/null 2>&1; then
            echo -e "${BLUE}Delete namespace ${ns}${NC}"
            run kubectl delete ns "$ns" --wait=false 2>/dev/null || true
        fi
    done
}

uninstall_gpu_operator() {
    echo -e "${BLUE}=== NVIDIA GPU Operator ===${NC}"
    helm_uninstall_if_exists gpu-operator gpu-operator
    if [ "$DRY_RUN" != true ] && kubectl get ns gpu-operator >/dev/null 2>&1; then
        if [ -z "$(helm list -n gpu-operator -q 2>/dev/null)" ]; then
            kubectl delete ns gpu-operator --wait=false 2>/dev/null || true
        fi
    fi
}

uninstall_haproxy() {
    echo -e "${BLUE}=== HAProxy Kubernetes Ingress (HAProxyTech) ===${NC}"
    local ns="${HAPROXY_NAMESPACE:-haproxy-controller}"
    helm_uninstall_if_exists haproxy-kubernetes-ingress "$ns"
    if [ "$DRY_RUN" != true ] && kubectl get ns "$ns" >/dev/null 2>&1; then
        if [ -z "$(helm list -n "$ns" -q 2>/dev/null)" ]; then
            kubectl delete ns "$ns" --wait=false 2>/dev/null || true
        fi
    fi
}

uninstall_training_operator() {
    echo -e "${BLUE}=== Kubeflow Training Operator (Kustomize standalone) ===${NC}"
    local k="github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=${TRAINING_OPERATOR_GIT_REF}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[dry-run]${NC} kubectl delete -k \"$k\""
        return 0
    fi
    if kubectl get deployment training-operator -n kubeflow >/dev/null 2>&1 \
        || kubectl get crd pytorchjobs.kubeflow.org >/dev/null 2>&1; then
        echo -e "${BLUE}kubectl delete -k ${k}${NC}"
        if ! kubectl delete -k "$k" --wait=false 2>/dev/null; then
            echo -e "${YELLOW}delete -k failed (network or API). Try manually:${NC} kubectl delete -k \"$k\""
        fi
    else
        echo -e "${YELLOW}Training Operator markers not found; skipping kustomize delete${NC}"
    fi
}

uninstall_nim_operator() {
    echo -e "${BLUE}=== NVIDIA NIM Operator ===${NC}"
    local rel="${NIM_OPERATOR_HELM_RELEASE:-k8s-nim-operator}"
    helm_uninstall_if_exists "$rel" nim-operator
    helm_uninstall_if_exists nim-operator nim-operator
    if [ "$DRY_RUN" != true ] && kubectl get ns nim-operator >/dev/null 2>&1; then
        if [ -z "$(helm list -n nim-operator -q 2>/dev/null)" ]; then
            kubectl delete ns nim-operator --wait=false 2>/dev/null || true
        fi
    fi
}

# modules/lws.sh: helm upgrade --install lws ... --namespace lws-system
uninstall_lws() {
    echo -e "${BLUE}=== Local Workload Service (LWS) ===${NC}"
    helm_uninstall_if_exists lws lws-system
    if [ "$DRY_RUN" != true ] && kubectl get ns lws-system >/dev/null 2>&1; then
        if [ -z "$(helm list -n lws-system -q 2>/dev/null)" ]; then
            kubectl delete ns lws-system --wait=false 2>/dev/null || true
        fi
    fi
}

uninstall_prometheus_stack
uninstall_nim_operator
uninstall_gpu_operator
uninstall_haproxy
uninstall_knative
uninstall_lws
uninstall_training_operator

echo ""
echo -e "${GREEN}Done. Namespaces may still be Terminating; check: kubectl get ns${NC}"
echo -e "${YELLOW}Note: Prometheus / LWS / Training CRDs may remain until finalizers clear; remove manually if needed.${NC}"
