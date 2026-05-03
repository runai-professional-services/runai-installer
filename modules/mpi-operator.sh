#!/bin/bash

# Kubeflow MPI Operator (MPIJob / mpijobs.kubeflow.org).
# Uses the upstream single-file manifest (same operator family as Bright "mpi-operator" Helm chart ~0.7.x).
# Default namespace in the manifest: mpi-operator (BCM may install via Helm into "cm" instead — we skip if the CRD already exists).
#
# NVIDIA Run:ai self-hosted preparations (registry secrets, air-gapped artifacts, private registry):
# https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/preparations
install_mpi_operator() {
    echo -e "${BLUE}Installing Kubeflow MPI Operator...${NC}"

    if kubectl get crd mpijobs.kubeflow.org &>/dev/null; then
        echo -e "${BLUE}MPI Operator already installed (mpijobs.kubeflow.org CRD present).${NC}"
        return 0
    fi

    local tag url
    tag="${MPI_OPERATOR_MANIFEST_TAG:-v0.7.0}"
    url="https://raw.githubusercontent.com/kubeflow/mpi-operator/${tag}/deploy/v2beta1/mpi-operator.yaml"

    # If Kubeflow Training Operator (or another tool) already applied mpijobs.kubeflow.org, SSA can conflict with "kubectl-client-side-configuration" etc.
    if ! log_command "kubectl apply --server-side --force-conflicts -f \"${url}\"" "Install Kubeflow MPI Operator (manifest ${tag})"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install MPI Operator, continuing...${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ Kubeflow MPI Operator applied successfully!${NC}"
    if kubectl get crd mpijobs.kubeflow.org &>/dev/null; then
        echo -e "${GREEN}✅ mpijobs.kubeflow.org CRD verified${NC}"
    else
        echo -e "${YELLOW}⚠️ Warning: MPIJob CRD not found yet; installation may still be progressing${NC}"
    fi
    return 0
}
