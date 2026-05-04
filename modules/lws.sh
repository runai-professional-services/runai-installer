#!/bin/bash

# Function to install Local Workload Service (LWS)
install_lws() {
    echo -e "${BLUE}Installing Local Workload Service (LWS)...${NC}"

    # Check if LWS is already installed
    if kubectl get ns lws-system &> /dev/null && (kubectl get deployment -n lws-system lws &> /dev/null || kubectl get deployment -n lws-system lws-controller &> /dev/null); then
        echo -e "${BLUE}Local Workload Service (LWS) already installed.${NC}"
        return 0
    fi

    # Helm --version uses semver (no "v"); matches upstream release v0.8.0 — https://sigs.k8s.io/lws/docs/installation/
    local CHART_VERSION="0.8.0"
    local lws_tmp crd_dir helm_skip_crds=""
    echo -e "${BLUE}Installing LWS chart version: $CHART_VERSION${NC}"

    # Always apply CRDs from this chart version with kubectl (SSA + force-conflicts) so upgrades get the right
    # OpenAPI/schema even when a CRD already exists without Helm ownership (Helm would refuse to adopt it).
    # Then install chart manifests with Helm --skip-crds so this release does not try to own those CRD objects.
    lws_tmp=$(mktemp -d "${TMPDIR:-/tmp}/runai-lws.XXXXXX") || return 1

    if ! log_command "helm pull oci://registry.k8s.io/lws/charts/lws --version \"${CHART_VERSION}\" --untar --untardir \"${lws_tmp}\"" "Pull LWS chart ${CHART_VERSION} (CRD prep)"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to pull LWS chart, continuing...${NC}"
        rm -rf "${lws_tmp}"
        return 1
    fi

    local chart_root=""
    chart_root=$(find "${lws_tmp}" -name Chart.yaml -print -quit 2>/dev/null)
    chart_root="${chart_root:+$(dirname "${chart_root}")}"
    if [ -z "${chart_root}" ] || [ ! -f "${chart_root}/Chart.yaml" ]; then
        echo -e "${YELLOW}⚠️ Warning: Could not locate chart root after LWS pull.${NC}"
        rm -rf "${lws_tmp}"
        return 1
    fi

    crd_dir=$(find "${chart_root}" -type d -name crds 2>/dev/null | head -1)
    if [ -n "${crd_dir}" ] && compgen -G "${crd_dir}/*.yaml" >/dev/null 2>&1; then
        if ! log_command "kubectl apply --server-side --force-conflicts -f \"${crd_dir}\"" "Apply LWS CRDs from chart ${CHART_VERSION} (server-side, force conflicts)"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to apply LWS CRDs, continuing...${NC}"
            rm -rf "${lws_tmp}"
            return 1
        fi
        helm_skip_crds=" --skip-crds"
    else
        echo -e "${YELLOW}⚠️ No crds/ in pulled LWS chart — Helm will try to install CRDs (unexpected for official chart).${NC}"
    fi

    # Install from the same unpacked chart (one pull; CRDs already match this tree).
    if ! log_command "helm upgrade --install lws \"${chart_root}\" --namespace lws-system --create-namespace --wait --timeout 300s${helm_skip_crds}" "Install Local Workload Service (LWS)"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Local Workload Service (LWS), continuing...${NC}"
        rm -rf "${lws_tmp}"
        return 1
    else
        rm -rf "${lws_tmp}"
        echo -e "${GREEN}✅ Local Workload Service (LWS) installed successfully!${NC}"
        
        # Wait a moment for the deployment to be ready
        echo -e "${BLUE}Waiting for LWS deployment to be ready...${NC}"
        sleep 10
        
        # Verify installation by checking deployment status
        local deployment_name=""
        if kubectl get deployment -n lws-system lws &> /dev/null; then
            deployment_name="lws"
        elif kubectl get deployment -n lws-system lws-controller &> /dev/null; then
            deployment_name="lws-controller"
        fi
        
        if [ -n "$deployment_name" ]; then
            echo -e "${GREEN}✅ LWS deployment verified successfully (found: $deployment_name)${NC}"
            
            # Check if deployment is ready
            local ready_replicas=$(kubectl get deployment -n lws-system "$deployment_name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
            local desired_replicas=$(kubectl get deployment -n lws-system "$deployment_name" -o jsonpath='{.spec.replicas}' 2>/dev/null)
            
            if [ "$ready_replicas" = "$desired_replicas" ] && [ -n "$ready_replicas" ]; then
                echo -e "${GREEN}✅ LWS deployment is ready (${ready_replicas}/${desired_replicas} replicas)${NC}"
            else
                echo -e "${YELLOW}⚠️ LWS deployment is still starting up (${ready_replicas:-0}/${desired_replicas} replicas ready)${NC}"
            fi
        else
            echo -e "${BLUE}LWS installation completed${NC}"
        fi
    fi

    return 0
} 