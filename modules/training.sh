#!/bin/bash

# Kubeflow Training Operator (PyTorchJob, TFJob, …) — standalone Kustomize overlay, not the MPI-only operator.
# For MPIJob support without the full training stack, use --mpi-operator (modules/mpi-operator.sh).
#
# NVIDIA Run:ai self-hosted: chart/image registry preparation (connected or air-gapped) is documented at:
# https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/preparations
# Operator images are pulled from public registries unless your cluster uses a mirror / imagePullSecret.

# Function to install Kubeflow Training Operator
install_training_operator() {
    echo -e "${BLUE}Installing Kubeflow Training Operator...${NC}"

    # Do not treat "CRD exists" alone as success — a failed apply can leave CRDs up while Deployment/webhooks never finished.
    if kubectl get crd pytorchjobs.kubeflow.org &>/dev/null \
        && kubectl get deployment -n kubeflow training-operator &>/dev/null; then
        local ready
        ready="$(kubectl get deployment -n kubeflow training-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
        case "$ready" in ''|*[!0-9]*) ready=0 ;; esac
        if [ "$ready" -ge 1 ] 2>/dev/null; then
            echo -e "${BLUE}Kubeflow Training Operator already installed (training-operator Deployment ready in kubeflow).${NC}"
            return 0
        fi
        echo -e "${BLUE}Training Operator CRD/Deployment present but not ready — re-applying manifest.${NC}"
    fi

    # Install Kubeflow Training Operator
    # Standalone overlay can touch CRDs (e.g. mpijobs) already owned by field manager "helm" (MPI operator chart).
    # Without --force-conflicts, server-side apply fails with conflicts on .metadata.annotations / .spec.versions.
    if ! log_command "kubectl apply --server-side --force-conflicts -k \"github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=v1.9.2\"" "Install Kubeflow Training Operator"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Kubeflow Training Operator, continuing...${NC}"
        return 1
    else
        echo -e "${GREEN}✅ Kubeflow Training Operator installed successfully!${NC}"
        
        # Wait for the operator to be ready
        echo -e "${BLUE}Waiting for Training Operator to be ready...${NC}"
        sleep 10
        
        # Verify installation by checking for CRDs
        if kubectl get crd pytorchjobs.kubeflow.org &> /dev/null; then
            echo -e "${GREEN}✅ Training Operator CRDs verified successfully${NC}"
        else
            echo -e "${YELLOW}⚠️ Warning: Training Operator CRDs not found, installation may still be in progress${NC}"
        fi
    fi

    return 0
} 