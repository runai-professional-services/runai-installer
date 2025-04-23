#!/bin/bash

# Function to install Prometheus Stack
install_prometheus() {
    echo -e "${BLUE}Installing Prometheus Stack...${NC}"

    # Check if Prometheus is already installed
    if kubectl get ns monitoring &> /dev/null && kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus &> /dev/null; then
        echo -e "${BLUE}Prometheus Stack already installed.${NC}"
        return 0
    fi

    # Install Prometheus Stack
    if ! log_command "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts" "Add Prometheus Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add prometheus helm repo, continuing...${NC}"
        return 1
    fi

    if ! log_command "helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace --set grafana.enabled=false" "Install Prometheus Stack"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install prometheus stack, continuing...${NC}"
        return 1
    else
        echo -e "${GREEN}✅ Prometheus Stack installed successfully!${NC}"
    fi

    return 0
}

# Function to install NVIDIA GPU Operator
install_gpu_operator() {
    echo -e "${BLUE}Installing NVIDIA GPU Operator...${NC}"

    # Check if GPU Operator is already installed
    if kubectl get ns gpu-operator &> /dev/null; then
        echo -e "${BLUE}NVIDIA GPU Operator already installed.${NC}"
        return 0
    fi

    # Install NVIDIA GPU Operator
    if ! log_command "helm repo add nvidia https://helm.ngc.nvidia.com/nvidia" "Add NVIDIA Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add NVIDIA helm repo, continuing...${NC}"
        return 1
    fi

    if ! log_command "helm install --wait --generate-name -n gpu-operator --create-namespace nvidia/gpu-operator" "Install NVIDIA GPU Operator"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install NVIDIA GPU operator, continuing...${NC}"
        return 1
    else
        echo -e "${GREEN}✅ NVIDIA GPU Operator installed successfully!${NC}"
    fi

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