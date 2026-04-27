#!/bin/bash
# NVIDIA Run:ai control plane artifacts from JFrog (legacy; see also NGC).
# https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/install-control-plane

runai_maybe_clean_helm_repos_for_artifact_flag() {
    # Only do a full cleanup when the user explicitly passed --jfrog or --ngc.
    if [ "${HELM_REPOS_CLEANED_FOR_SOURCE_FLAG:-false}" = true ]; then
        return 0
    fi
    if [ "${NGC_FLAG_COUNT:-0}" -eq 0 ] && [ "${JFROG_FLAG_COUNT:-0}" -eq 0 ]; then
        return 0
    fi

    echo -e "${BLUE}Explicit artifact-source flag detected; removing existing Run:ai Helm repos first...${NC}" >&2

    local repo_names_json repo_names repo_name
    echo -e "${BLUE}  (listing Helm repositories; if it hangs, try: helm repo list -o json)${NC}" >&2
    repo_names_json="$(helm repo list -o json 2>/dev/null || true)"
    repo_names="$(printf '%s' "$repo_names_json" | jq -r '.[] | select((.name == "runai") or (.name == "runai-backend") or (.url | test("runai\\.jfrog\\.io|helm\\.ngc\\.nvidia\\.com/nvidia/runai"))) | .name' 2>/dev/null || true)"

    if [ -z "$repo_names" ]; then
        echo -e "${BLUE}ℹ️ No existing Run:ai Helm repos found to remove.${NC}"
        HELM_REPOS_CLEANED_FOR_SOURCE_FLAG=true
        return 0
    fi

    while IFS= read -r repo_name; do
        [ -z "$repo_name" ] && continue
        if ! log_command "helm repo remove \"$repo_name\" > /dev/null 2>&1" "Remove Helm repo: $repo_name"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to remove Helm repo '$repo_name', continuing...${NC}"
        fi
    done <<< "$repo_names"

    local repos_remaining
    repos_remaining="$(helm repo list -o json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")"
    if [ "$repos_remaining" -gt 0 ]; then
        # helm repo update contacts every named repo; a slow/broken entry can make this look "stuck".
        local hru="helm repo update"
        if command -v timeout >/dev/null 2>&1; then
            hru="timeout 600 helm repo update"
        fi
        if ! log_command "$hru > /dev/null 2>&1" "Refresh Helm repos after cleanup (timeout 600s if GNU timeout is available)"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to refresh Helm repos after cleanup, continuing...${NC}"
        fi
    else
        echo -e "${BLUE}ℹ️ No Helm repos remain after cleanup; skipping repo refresh.${NC}"
    fi

    HELM_REPOS_CLEANED_FOR_SOURCE_FLAG=true
    return 0
}

runai_jfrog_add_repo() {
    runai_maybe_clean_helm_repos_for_artifact_flag

    if ! log_command "helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod" "Add Run.ai backend Helm repo (JFrog)"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add runai-backend helm repo, continuing...${NC}"
        return 1
    fi
    return 0
}

runai_jfrog_control_plane_chart() {
    printf '%s' "runai-backend/control-plane"
}
