#!/bin/bash

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/gpu-operator-values.sh"

# Function to install Prometheus Stack
install_prometheus() {
    echo -e "${BLUE}Installing Prometheus Stack...${NC}"

    # Check if Prometheus is already installed (installer default, or common kube-prometheus-stack elsewhere).
    if kubectl get ns monitoring &> /dev/null && kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus &> /dev/null; then
        echo -e "${BLUE}Prometheus Stack already installed.${NC}"
        return 0
    fi
    if helm list -A 2>/dev/null | grep -qF 'kube-prometheus-stack'; then
        echo -e "${BLUE}Prometheus Stack already installed (Helm chart kube-prometheus-stack).${NC}"
        return 0
    fi

    # Install Prometheus Stack
    if ! log_command "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts" "Add Prometheus Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add prometheus helm repo, continuing...${NC}"
        return 1
    fi

    # If Prometheus Operator CRDs are already in the cluster (leftover, another stack, or failed
    # partial install), Helm 3/4 server-side apply on CRDs can fail with:
    #   conflicts with "helm" on .metadata.annotations / .spec.versions
    # In that case install the release only; existing CRDs are used as-is.
    local prom_install_cmd="helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace --set grafana.enabled=false"
    if kubectl get crd -o name 2>/dev/null | grep -q 'monitoring\.coreos\.com'; then
        echo -e "${BLUE}Prometheus Operator CRDs already present — using ${YELLOW}--skip-crds${BLUE} to avoid CRD apply conflicts.${NC}"
        prom_install_cmd="$prom_install_cmd --skip-crds"
    fi

    if ! log_command "$prom_install_cmd > /dev/null 2>&1" "Install Prometheus Stack"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install prometheus stack, continuing...${NC}"
        return 1
    else
        echo -e "${GREEN}✅ Prometheus Stack installed successfully!${NC}"
    fi

    return 0
}

# Function to install NVIDIA GPU Operator
# Chart v25.10.1 by default; values file is BCM vs vanilla (see modules/gpu-operator-values.sh).
#   GPU_OPERATOR_CHART_VERSION          — Helm chart version (default v25.10.1)
#   GPU_OPERATOR_DEFAULT_VALUES_FILE    — skip auto profile; use this yaml path
#   GPU_OPERATOR_VALUES_PROFILE         — auto | vanilla | bcm (default auto: detect /cm containerd)
#   RUNAI_BCM_CLUSTER                     — true / 1 → use bcm values when profile is auto
#   GPU_OPERATOR_HELM_VALUES_FILE       — optional extra -f merged after the profile file
install_gpu_operator() {
    echo -e "${BLUE}Installing NVIDIA GPU Operator...${NC}"

    if helm status gpu-operator -n gpu-operator &>/dev/null; then
        echo -e "${BLUE}NVIDIA GPU Operator already installed (Helm release gpu-operator).${NC}"
        return 0
    fi

    local prereq_dir values_file chart_ver helm_cmd extra_f prof
    prereq_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    values_file="$(runai_gpu_operator_values_file_for_host "$prereq_dir")"
    if [ ! -f "$values_file" ]; then
        echo -e "${RED}❌ GPU Operator values file not found: $values_file${NC}" >&2
        return 1
    fi
    prof="$(runai_gpu_operator_values_profile_label "$values_file")"
    echo -e "${BLUE}GPU Operator Helm values profile:${NC} ${GREEN}${prof}${NC}  (${values_file})"

    chart_ver="${GPU_OPERATOR_CHART_VERSION:-v25.10.1}"

    if ! log_command "helm repo add nvidia https://helm.ngc.nvidia.com/nvidia" "Add NVIDIA Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add NVIDIA helm repo, continuing...${NC}"
        return 1
    fi

    if ! log_command "helm repo update nvidia" "Update NVIDIA Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to update NVIDIA helm repo, continuing...${NC}"
        return 1
    fi

    extra_f=""
    if [ -n "${GPU_OPERATOR_HELM_VALUES_FILE:-}" ] && [ -f "${GPU_OPERATOR_HELM_VALUES_FILE}" ]; then
        extra_f=" -f \"${GPU_OPERATOR_HELM_VALUES_FILE}\""
        echo -e "${BLUE}Applying additional GPU Operator values:${NC} ${GPU_OPERATOR_HELM_VALUES_FILE}"
    fi

    helm_cmd="helm upgrade --install gpu-operator nvidia/gpu-operator --namespace gpu-operator --create-namespace --version \"${chart_ver}\" --wait --timeout 25m -f \"${values_file}\"${extra_f}"

    if ! log_command "$helm_cmd" "Install NVIDIA GPU Operator (chart ${chart_ver})"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install NVIDIA GPU operator, continuing...${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ NVIDIA GPU Operator installed successfully!${NC}"
    return 0
}

# Function to install prerequisites
install_prerequisites() {
    # Check if Kubernetes is already installed
    if ! kubectl get nodes &> /dev/null; then
        echo -e "${RED}❌ Kubernetes cluster not found. Please install Kubernetes first or use --runai-only with an existing cluster.${NC}"
        exit 1
    fi

    echo -e "${BLUE}Installing prerequisites...${NC}"

    # Install Prometheus if requested
    if [ "$INSTALL_PROMETHEUS" = true ]; then
        install_prometheus
    fi

    # Install GPU Operator if requested
    if [ "$INSTALL_GPU_OPERATOR" = true ]; then
        install_gpu_operator
    fi

    # Check if local-path-storage is already installed
    if kubectl get ns local-path-storage &> /dev/null; then
        echo -e "${BLUE}Patching local-path-config ConfigMap...${NC}"
        kubectl -n local-path-storage patch cm local-path-config --type='merge' --patch='
        data:
          helperPod.yaml: |-
            apiVersion: v1
            kind: Pod
            metadata:
              name: helper-pod
            spec:
              containers:
              - name: helper-pod
                image: "docker.io/library/busybox:latest"
                imagePullPolicy: IfNotPresent
        ' 2>/dev/null || echo -e "${YELLOW}⚠️ Warning: Failed to patch local-path-config, continuing...${NC}"

        # Delete all pods in local-path-storage namespace
        echo -e "${BLUE}Deleting all pods in local-path-storage namespace to apply changes...${NC}"
        kubectl -n local-path-storage delete pods --all --force 2>/dev/null || echo -e "${YELLOW}⚠️ Warning: Failed to restart local-path-storage pods, continuing...${NC}"
    fi

    echo -e "${GREEN}✅ Prerequisites installation completed!${NC}"
} 