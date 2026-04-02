#!/bin/bash
# NVIDIA Run:ai artifacts from NGC (connected installs).
# Helm repo: https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/install-control-plane
# nvcr.io pull secret: https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/preparations

# Create/update docker-registry secret for nvcr.io in runai-backend and runai (NGC connected environments).
runai_ngc_apply_image_pull_secrets() {
    if [ -z "${NGC_API_KEY:-}" ]; then
        echo -e "${RED}❌ NGC_API_KEY is required for --ngc (nvcr.io pull secret)${NC}" >&2
        return 1
    fi
    # Same normalization as runai_ngc_add_repo / installer load_env
    NGC_API_KEY="$(printf '%s' "$NGC_API_KEY" | tr -d '\r\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^"//; s/"$//')"
    if [ -z "${NGC_API_KEY:-}" ]; then
        echo -e "${RED}❌ NGC_API_KEY is empty after normalization${NC}" >&2
        return 1
    fi
    export NGC_API_KEY

    # Email is not used for nvcr.io auth; NVIDIA examples use a placeholder (e.g. test@run.ai).
    local email="test@run.ai"

    {
        echo ""
        echo "==== NGC: docker-registry secret runai-reg-creds (nvcr.io) per preparations ===="
        echo "Reference: https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/preparations"
        echo "Namespaces: runai-backend, runai --docker-username='\$oauthtoken' --docker-password=<redacted> --docker-email=$email"
        echo "Executing at: $(date)"
    } >> "$LOG_FILE"

    local ns
    for ns in runai-backend runai; do
        kubectl create namespace "$ns" 2>/dev/null || true
        # Run kubectl apply with stderr to terminal on failure so errors are visible (not only in LOG_FILE).
        local apply_err
        apply_err=$(mktemp "${TMPDIR:-/tmp}/ngc-secret-err.XXXXXX")
        if ! kubectl create secret docker-registry runai-reg-creds \
            --docker-server=https://nvcr.io \
            --docker-username='$oauthtoken' \
            --docker-password="$NGC_API_KEY" \
            --docker-email="$email" \
            --namespace="$ns" \
            --dry-run=client -o yaml | kubectl apply -f - >>"$LOG_FILE" 2>"$apply_err"; then
            echo "Status: FAILED (namespace $ns)" >>"$LOG_FILE"
            if [ -s "$apply_err" ]; then cat "$apply_err" >>"$LOG_FILE"; echo -e "${RED}kubectl: $(cat "$apply_err")${NC}" >&2; fi
            rm -f "$apply_err"
            echo -e "${RED}❌ Failed to apply runai-reg-creds in namespace $ns${NC}" >&2
            return 1
        fi
        rm -f "$apply_err"
        echo "Status: SUCCESS (namespace $ns)" >>"$LOG_FILE"
    done

    echo -e "${GREEN}✅ NGC image pull secret runai-reg-creds applied (runai-backend, runai)${NC}"
    return 0
}

runai_ngc_add_repo() {
    if [ -z "${NGC_API_KEY:-}" ]; then
        echo -e "${RED}❌ NGC_API_KEY is required when using --ngc (set env NGC_API_KEY or pass --ngc-api-key)${NC}" >&2
        return 1
    fi
    # Normalize common copy/paste issues (spaces/newlines/quoted value).
    NGC_API_KEY="$(printf '%s' "$NGC_API_KEY" | tr -d '\r\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^"//; s/"$//')"
    if [ -z "${NGC_API_KEY:-}" ]; then
        echo -e "${RED}❌ NGC_API_KEY is empty after normalization${NC}" >&2
        return 1
    fi
    export NGC_API_KEY

    {
        echo ""
        echo "==== Add Run.ai NGC Helm repo ===="
        echo "Command: helm repo add runai https://helm.ngc.nvidia.com/nvidia/runai --force-update --username='\$oauthtoken' --password=<redacted> [--pass-credentials]"
        echo "Reference: https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/install-control-plane"
        echo "Executing at: $(date)"
    } >> "$LOG_FILE"

    # Preflight: verify NGC auth to the Run:ai Helm index before invoking helm.
    local status_code
    status_code="$(curl -sS -o /dev/null -w "%{http_code}" -u "\$oauthtoken:$NGC_API_KEY" "https://helm.ngc.nvidia.com/nvidia/runai/index.yaml" || true)"
    echo "NGC preflight index.yaml HTTP status: $status_code" >> "$LOG_FILE"
    if [ "$status_code" != "200" ]; then
        echo -e "${RED}❌ NGC auth preflight failed (index.yaml HTTP $status_code)${NC}" >&2
        echo -e "${YELLOW}Expected 200. 400/401/403 usually means invalid key format, expired key, or missing Run:ai entitlement in NGC.${NC}" >&2
        return 1
    fi

    # Must not write to stdout: get_latest_runai_version captures stdout from this function.
    # Drop stale repos so Helm does not keep a wrong URL/credentials for the same chart name.
    helm repo remove runai >>"$LOG_FILE" 2>&1 || true
    helm repo remove runai-backend >>"$LOG_FILE" 2>&1 || true

    local ok=1
    if helm repo add runai https://helm.ngc.nvidia.com/nvidia/runai --force-update \
        --username='$oauthtoken' \
        --password="$NGC_API_KEY" \
        --pass-credentials >>"$LOG_FILE" 2>&1; then
        ok=0
    elif helm repo add runai https://helm.ngc.nvidia.com/nvidia/runai --force-update \
        --username='$oauthtoken' \
        --password="$NGC_API_KEY" >>"$LOG_FILE" 2>&1; then
        ok=0
    fi

    if [ "$ok" -eq 0 ]; then
        echo "Status: SUCCESS" >>"$LOG_FILE"
        return 0
    fi

    echo "Status: FAILED" >>"$LOG_FILE"
    echo -e "${RED}❌ Failed to add Run.ai NGC Helm repo (check log: $LOG_FILE)${NC}" >&2
    echo -e "${YELLOW}Hints:${NC}" >&2
    echo -e "${YELLOW}  • Use an NGC API key with access to Run:ai Helm charts (see NGC API key / catalog access).${NC}" >&2
    echo -e "${YELLOW}  • Ensure nvcr.io pull secret matches preparations: ${BLUE}https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/preparations${NC}" >&2
    echo -e "${YELLOW}  • 403 Forbidden usually means an invalid/expired key or missing product entitlement.${NC}" >&2
    return 1
}

runai_ngc_control_plane_chart() {
    printf '%s' "runai/control-plane"
}
