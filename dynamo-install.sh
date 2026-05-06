#!/usr/bin/env bash
#
# dynamo-install.sh — explore or install NVIDIA AI Dynamo on Kubernetes (standalone helper).
#
# Docs (quickstart): https://docs.nvidia.com/dynamo/dev/getting-started/kubernetes-deployment
#
# Do you need an NGC key?
#   Yes. Pass it as NGC_API_KEY. Username for NGC is always the literal string: $oauthtoken
#
# Install methods (DYNAMO_INSTALL_METHOD):
#   tgz (default) — helm pull https://helm.ngc.nvidia.com/.../dynamo-platform-VERSION.tgz
#                 with --username '$oauthtoken' --password "$NGC_API_KEY".
#                 Works with Helm 4.x (helm registry login helm.ngc.nvidia.com often errors:
#                 "authenticating ... not found" — that host is not a normal OCI login endpoint).
#   oci          — helm upgrade --install from oci://... (needs helm registry login; use nvcr.io
#                 OCI ref + nvcr login; helm.ngc OCI + login is unreliable in Helm 4).
#
# Separate from NGC: HuggingFace token secret for model downloads (optional for chart install only).
#
# Prerequisites (from NVIDIA): Kubernetes 1.24+, kubectl, Helm 3+, GPU Operator recommended.
#
# Usage:
#   ./dynamo-install.sh              # default: dry-run
#   ./dynamo-install.sh --apply      # install (default: tgz method)
#   ./dynamo-install.sh --dry-run
#
# Environment (optional):
#   NGC_API_KEY                 — required for --apply
#   DYNAMO_INSTALL_METHOD       — tgz (default) | oci
#   DYNAMO_RELEASE_VERSION      — default 1.0.2
#   DYNAMO_PLATFORM_NAMESPACE   — default dynamo-system
#   DYNAMO_HELM_CHART_TGZ_URL   — override tgz URL (default helm.ngc path for dynamo-platform)
#   DYNAMO_PLATFORM_OCI_REF     — for oci method; default oci://nvcr.io/nvidia/ai-dynamo/dynamo-platform
#   DYNAMO_BUNDLE_GROVE         — true|false, default true

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

APPLY=false
DRY_RUN=true

usage() {
    sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=true; DRY_RUN=false; shift ;;
        --dry-run) DRY_RUN=true; APPLY=false; shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}" >&2; exit 1 ;;
    esac
done

VER="${DYNAMO_RELEASE_VERSION:-1.0.2}"
VER="${VER#v}"
NS="${DYNAMO_PLATFORM_NAMESPACE:-dynamo-system}"
METHOD="${DYNAMO_INSTALL_METHOD:-tgz}"
BUNDLE_GROVE="${DYNAMO_BUNDLE_GROVE:-true}"

# NVIDIA deployment guide / quickstart chart location (HTTPS tarball; Basic auth with NGC key).
DEFAULT_TGZ_URL="https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${VER}.tgz"
TGZ_URL="${DYNAMO_HELM_CHART_TGZ_URL:-$DEFAULT_TGZ_URL}"

DEFAULT_OCI='oci://nvcr.io/nvidia/ai-dynamo/dynamo-platform'
OCI_REF="${DYNAMO_PLATFORM_OCI_REF:-$DEFAULT_OCI}"

echo -e "${BLUE}=== NVIDIA Dynamo install helper ===${NC}"
echo -e "Mode: ${GREEN}$([ "$APPLY" = true ] && echo apply || echo dry-run)${NC}  Method: ${GREEN}${METHOD}${NC}"
echo -e "Chart version: ${VER}  Namespace: ${NS}"
echo ""

helm_grove_args() {
    if [ "$BUNDLE_GROVE" = true ] || [ "$BUNDLE_GROVE" = 1 ]; then
        echo '--set grove.enabled=true --set global.grove.install=true'
    fi
}

helm_pass_creds_flag() {
    if helm upgrade --help 2>/dev/null | grep -q -- '--pass-credentials'; then
        echo '--pass-credentials'
    fi
}

print_plan_tgz() {
    echo -e "${BLUE}--- 1) Download chart (HTTPS + NGC Basic auth) ---${NC}"
    echo -e "NGC API key as Helm password; ${GREEN}--username${NC} must be the literal NGC username ${GREEN}'\$oauthtoken'${NC} (see NVIDIA NGC docs)."
    if [ -z "${NGC_API_KEY:-}" ]; then
        echo -e "${YELLOW}NGC_API_KEY is not set.${NC} For --apply, export it first."
    else
        echo -e "${GREEN}NGC_API_KEY is set (value not printed).${NC}"
    fi
    echo "helm pull \"${TGZ_URL}\" \\"
    echo "  --username '\$oauthtoken' --password \"\$NGC_API_KEY\" \\"
    echo "  --destination /tmp/dynamo-chart-XXXX"
    echo ""
    echo -e "${BLUE}--- 2) Helm install (from .tgz file) ---${NC}"
    local grove pc
    grove=$(helm_grove_args)
    pc=$(helm_pass_creds_flag)
    echo "helm upgrade --install dynamo-platform /tmp/dynamo-chart-XXXX/dynamo-platform-${VER}.tgz \\"
    echo "  --namespace \"${NS}\" --create-namespace \\"
    if [ -n "$grove" ]; then
        echo "  ${grove} \\"
    fi
    if [ -n "$pc" ]; then
        echo "  ${pc} \\"
    fi
    echo "  --wait --timeout 30m"
}

print_plan_oci() {
    echo -e "${BLUE}--- 1) Registry login (OCI only) ---${NC}"
    echo "OCI ref: ${OCI_REF}"
    if [ -z "${NGC_API_KEY:-}" ]; then
        echo -e "${YELLOW}NGC_API_KEY is not set.${NC}"
    else
        echo -e "${GREEN}NGC_API_KEY is set (value not printed).${NC}"
    fi
    case "$OCI_REF" in
        *nvcr.io*)
            echo "  printf '%s' \"\$NGC_API_KEY\" | helm registry login nvcr.io --username '\$oauthtoken' --password-stdin"
            ;;
        *)
            echo -e "${YELLOW}  For oci://helm.ngc.nvidia.com/... Helm 4 often cannot registry-login that host (not found).${NC}"
            echo -e "  ${YELLOW}Prefer:${NC} DYNAMO_INSTALL_METHOD=tgz (default)."
            ;;
    esac
    echo ""
    echo -e "${BLUE}--- 2) Helm install (OCI) ---${NC}"
    local grove pc
    grove=$(helm_grove_args)
    pc=$(helm_pass_creds_flag)
    echo "helm upgrade --install dynamo-platform \"${OCI_REF}\" \\"
    echo "  --version \"${VER}\" \\"
    echo "  --namespace \"${NS}\" --create-namespace \\"
    if [ -n "$grove" ]; then
        echo "  ${grove} \\"
    fi
    if [ -n "$pc" ]; then
        echo "  ${pc} \\"
    fi
    echo "  --wait --timeout 30m"
}

print_plan() {
    if [ "$METHOD" = oci ]; then
        print_plan_oci
    else
        print_plan_tgz
    fi
    echo ""
    echo -e "${BLUE}--- Optional: HuggingFace secret (models) ---${NC}"
    echo "  kubectl create secret generic hf-token-secret --from-literal=HF_TOKEN=\"\$HF_TOKEN\""
    echo ""
    echo -e "${BLUE}--- Verify ---${NC}"
    echo "  kubectl get pods -n ${NS}"
    echo ""
    echo "Reference: https://docs.nvidia.com/dynamo/dev/getting-started/kubernetes-deployment"
    echo -e "${YELLOW}OCI method:${NC} DYNAMO_INSTALL_METHOD=oci ./dynamo-install.sh [--apply]"
}

print_plan

if [ "$APPLY" != true ]; then
    echo -e "${YELLOW}Dry-run only. Re-run with ${NC}--apply${YELLOW}.${NC}"
    exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "${RED}kubectl not found${NC}" >&2
    exit 1
fi
if ! command -v helm >/dev/null 2>&1; then
    echo -e "${RED}helm not found${NC}" >&2
    exit 1
fi

if [ -z "${NGC_API_KEY:-}" ]; then
    echo -e "${RED}--apply requires NGC_API_KEY${NC}" >&2
    exit 1
fi

grove=$(helm_grove_args)
pc=$(helm_pass_creds_flag)

if [ "$METHOD" = oci ]; then
    echo -e "${BLUE}Helm registry login (OCI method)…${NC}"
    case "$OCI_REF" in
        *nvcr.io*)
            printf '%s\n' "$NGC_API_KEY" | helm registry login nvcr.io --username '$oauthtoken' --password-stdin
            ;;
        *)
            echo -e "${RED}OCI method with this ref needs nvcr.io OCI or use DYNAMO_INSTALL_METHOD=tgz.${NC}" >&2
            echo -e "${RED}helm registry login helm.ngc.nvidia.com is not supported reliably (Helm: not found).${NC}" >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2086
    helm upgrade --install dynamo-platform "${OCI_REF}" \
        --version "${VER}" \
        --namespace "${NS}" --create-namespace \
        ${grove:+$grove} \
        ${pc:+$pc} \
        --wait --timeout 30m
else
    echo -e "${BLUE}Pulling chart tarball…${NC}"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/dynamo-chart.XXXXXX")
    # shellcheck disable=SC2064
    trap 'rm -rf "$tmp"' EXIT

    # Literal NGC Helm username is $oauthtoken (do not expand as shell variable).
    if ! helm pull "$TGZ_URL" \
        --username '$oauthtoken' \
        --password "$NGC_API_KEY" \
        --destination "$tmp"; then
        echo -e "${RED}helm pull failed (check version ${VER} exists, URL, and NGC_API_KEY).${NC}" >&2
        exit 1
    fi

    chart_tgz="${tmp}/dynamo-platform-${VER}.tgz"
    if [ ! -f "$chart_tgz" ]; then
        chart_tgz=$(find "$tmp" -maxdepth 1 -name 'dynamo-platform-*.tgz' -print -quit 2>/dev/null || true)
    fi
    if [ -z "${chart_tgz:-}" ] || [ ! -f "$chart_tgz" ]; then
        echo -e "${RED}Could not find dynamo-platform-*.tgz under ${tmp}.${NC}" >&2
        ls -la "$tmp" >&2 || true
        exit 1
    fi

    echo -e "${BLUE}Installing from ${chart_tgz}…${NC}"
    # shellcheck disable=SC2086
    helm upgrade --install dynamo-platform "$chart_tgz" \
        --namespace "$NS" --create-namespace \
        ${grove:+$grove} \
        ${pc:+$pc} \
        --wait --timeout 30m
fi

echo -e "${GREEN}✅ dynamo-platform installed (release dynamo-platform, ns ${NS}).${NC}"
echo -e "${BLUE}kubectl get pods -n ${NS}${NC}"
