#!/bin/bash

# NVIDIA NIM Operator (NIMService / NIMCache CRs).
# Upstream: https://docs.nvidia.com/nim-operator/latest/install.html
#   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
#   helm upgrade --install <RELEASE> nvidia/k8s-nim-operator -n nim-operator --version=…
#
# Common Helm release names: k8s-nim-operator (matches chart name; seen in clusters) or nim-operator (NVIDIA doc example).
# Override: NIM_OPERATOR_HELM_RELEASE, NIM_OPERATOR_CHART_VERSION (chart semver only, e.g. 3.0.2 or 3.1.0).

nim_operator_helm_release_already_present() {
    local rel
    for rel in "${NIM_OPERATOR_HELM_RELEASE:-k8s-nim-operator}" nim-operator; do
        if helm status "$rel" -n nim-operator &>/dev/null; then
            printf '%s' "$rel"
            return 0
        fi
    done
    return 1
}

install_nim_operator() {
    echo -e "${BLUE}Installing NVIDIA NIM Operator...${NC}"

    local existing
    if existing=$(nim_operator_helm_release_already_present); then
        echo -e "${BLUE}NVIDIA NIM Operator already installed (Helm release ${existing} in nim-operator).${NC}"
        return 0
    fi

    if ! kubectl get ns gpu-operator &>/dev/null; then
        echo -e "${YELLOW}⚠️ Warning: GPU Operator namespace not found — NIM Operator expects NVIDIA GPU Operator (see NVIDIA NIM Operator prerequisites).${NC}"
    fi

    local chart_ver helm_cmd rel
    rel="${NIM_OPERATOR_HELM_RELEASE:-k8s-nim-operator}"
    chart_ver="${NIM_OPERATOR_CHART_VERSION:-3.1.0}"

    if ! log_command "helm repo add nvidia https://helm.ngc.nvidia.com/nvidia" "Add NVIDIA Helm repo (NIM Operator)"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add NVIDIA helm repo, continuing...${NC}"
        return 1
    fi

    if ! log_command "helm repo update nvidia" "Update NVIDIA Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to update NVIDIA helm repo, continuing...${NC}"
        return 1
    fi

    # Helm applies chart CRDs with server-side apply; existing CRDs (e.g. leftover from a prior release or
    # another chart) are often owned by field manager "helm" → conflict on kubebuilder annotations / spec.versions.
    # Pre-apply CRDs with --force-conflicts, then install the release with --skip-crds.
    local nim_tmp crd_dir helm_skip_crds=""
    nim_tmp=$(mktemp -d "${TMPDIR:-/tmp}/runai-nim-operator.XXXXXX") || return 1

    if ! log_command "helm pull nvidia/k8s-nim-operator --version \"${chart_ver}\" --untar --untardir \"${nim_tmp}\"" "Pull k8s-nim-operator chart ${chart_ver} (CRD prep)"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to pull NIM Operator chart, continuing...${NC}"
        rm -rf "${nim_tmp}"
        return 1
    fi

    crd_dir=$(find "${nim_tmp}" -type d -name crds 2>/dev/null | head -1)
    if [ -n "${crd_dir}" ] && compgen -G "${crd_dir}/*.yaml" >/dev/null 2>&1; then
        if ! log_command "kubectl apply --server-side --force-conflicts -f \"${crd_dir}\"" "Apply NIM Operator CRDs (server-side, force conflicts)"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to apply NIM Operator CRDs, continuing...${NC}"
            rm -rf "${nim_tmp}"
            return 1
        fi
        helm_skip_crds=" --skip-crds"
    fi

    helm_cmd="helm upgrade --install \"${rel}\" nvidia/k8s-nim-operator --namespace nim-operator --create-namespace --version \"${chart_ver}\"${helm_skip_crds} --wait --timeout 15m"

    if ! log_command "$helm_cmd" "Install NVIDIA NIM Operator (release ${rel}, chart ${chart_ver})"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install NIM Operator, continuing...${NC}"
        rm -rf "${nim_tmp}"
        return 1
    fi

    rm -rf "${nim_tmp}"
    echo -e "${GREEN}✅ NVIDIA NIM Operator installed successfully!${NC}"
    return 0
}
