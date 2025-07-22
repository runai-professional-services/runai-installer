#!/bin/bash

# Function to install Local Workload Service (LWS)
install_lws() {
    echo -e "${BLUE}Installing Local Workload Service (LWS)...${NC}"

    # Check if LWS is already installed
    if kubectl get ns lws-system &> /dev/null && (kubectl get deployment -n lws-system lws &> /dev/null || kubectl get deployment -n lws-system lws-controller &> /dev/null); then
        echo -e "${BLUE}Local Workload Service (LWS) already installed.${NC}"
        return 0
    fi

    # Set chart version
    local CHART_VERSION="0.6.2"
    echo -e "${BLUE}Installing LWS chart version: $CHART_VERSION${NC}"

    # Install Local Workload Service (LWS)
    if ! log_command "helm install lws oci://registry.k8s.io/lws/charts/lws --version=$CHART_VERSION --namespace lws-system --create-namespace --wait --timeout 300s > /dev/null 2>&1" "Install Local Workload Service (LWS)"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Local Workload Service (LWS), continuing...${NC}"
        return 1
    else
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