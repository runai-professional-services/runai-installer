#!/bin/bash
# NVIDIA Run:ai control plane artifacts from JFrog (legacy; see also NGC).
# https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/install-control-plane

runai_jfrog_add_repo() {
    if ! log_command "helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod" "Add Run.ai backend Helm repo (JFrog)"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add runai-backend helm repo, continuing...${NC}"
        return 1
    fi
    return 0
}

runai_jfrog_control_plane_chart() {
    printf '%s' "runai-backend/control-plane"
}
