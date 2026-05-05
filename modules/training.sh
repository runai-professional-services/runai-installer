#!/bin/bash

# Run:ai compatibility: Kubeflow Training Operator v1.9.2 (override ref: TRAINING_OPERATOR_GIT_REF)
TRAINING_OPERATOR_GIT_REF="${TRAINING_OPERATOR_GIT_REF:-v1.9.2}"

# Kubeflow Training Operator (PyTorchJob, TFJob, MPIJob, …) — standalone Kustomize overlay (includes MPIJob CRD/controller).
#
# NVIDIA Run:ai self-hosted: chart/image registry preparation (connected or air-gapped) is documented at:
# https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/preparations
# Operator images are pulled from public registries unless your cluster uses a mirror / imagePullSecret.

# Training Operator v1.9.x updates mpijobs.kubeflow.org and may drop v2beta1 from spec.versions. If the CRD still has
# status.storedVersions=v2beta1 (common after kubeflow/mpi-operator or Helm mpi-operator), apply fails until the CRD is
# reconciled. Safe fix when no MPIJob resources exist: delete the CRD, then apply. Opt out: TRAINING_OPERATOR_SKIP_MPI_CRD_REPAIR=true
training_reconcile_mpijobs_crd_if_needed() {
    if [ "${TRAINING_OPERATOR_SKIP_MPI_CRD_REPAIR:-false}" = true ]; then
        return 0
    fi
    kubectl get crd mpijobs.kubeflow.org &>/dev/null || return 0

    local stored
    stored=$(kubectl get crd mpijobs.kubeflow.org -o jsonpath='{.status.storedVersions}' 2>/dev/null || true)
    case "$stored" in *v2beta1*) ;; *) return 0 ;; esac

    local cnt=0
    if kubectl get mpijobs.kubeflow.org -A --request-timeout=20s &>/dev/null; then
        cnt=$(kubectl get mpijobs.kubeflow.org -A -o name --request-timeout=20s 2>/dev/null | wc -l)
    fi
    cnt=$(printf '%s' "$cnt" | tr -d '[:space:]')
    case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac

    if [ "$cnt" -gt 0 ]; then
        echo -e "${RED}❌ mpijobs.kubeflow.org still lists storage version v2beta1; Training Operator cannot upgrade this CRD while MPIJob objects exist.${NC}" >&2
        echo -e "${YELLOW}   Migrate or delete those MPIJobs, then delete the CRD (${NC}kubectl delete crd mpijobs.kubeflow.org${YELLOW}) or uninstall the standalone MPI Operator Helm release, and re-run.${NC}" >&2
        echo -e "${YELLOW}   To skip this check (not recommended): ${NC}TRAINING_OPERATOR_SKIP_MPI_CRD_REPAIR=true${NC}" >&2
        return 1
    fi

    echo -e "${YELLOW}⚠️ Deleting legacy mpijobs.kubeflow.org CRD (storedVersions still v2beta1; no MPIJob resources) so Training Operator can apply.${NC}"
    echo -e "${BLUE}   If a Helm mpi-operator release is still installed, uninstall it first or it may recreate this CRD.${NC}"
    echo -e "${BLUE}   (MPIJob is included in Training Operator standalone; do not install the separate kubeflow/mpi-operator on the same cluster.)${NC}"
    if ! kubectl delete crd mpijobs.kubeflow.org --wait=true --timeout=120s; then
        echo -e "${RED}❌ Could not delete mpijobs.kubeflow.org CRD (finalizers or RBAC?). Remove it manually, then re-run.${NC}" >&2
        return 1
    fi
    return 0
}

# Function to install Kubeflow Training Operator
install_training_operator() {
    echo -e "${BLUE}Installing Kubeflow Training Operator...${NC}"

    if ! training_reconcile_mpijobs_crd_if_needed; then
        return 1
    fi

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
    # Matches upstream: kubectl apply --server-side -k "...?ref=v1.9.2". --force-conflicts avoids SSA failures over existing CRD field managers (e.g. Helm MPI installs).
    if ! log_command "kubectl apply --server-side --force-conflicts -k \"github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=${TRAINING_OPERATOR_GIT_REF}\"" "Install Kubeflow Training Operator (ref ${TRAINING_OPERATOR_GIT_REF})"; then
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