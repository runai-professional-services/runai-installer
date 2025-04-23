#!/bin/bash

# Function to install Knative
install_knative() {
    echo -e "${BLUE}Installing Knative (optional component)...${NC}"
    
    # Install Knative CRDs
    if ! log_command "kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.17.0/serving-crds.yaml" "Install Knative CRDs"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Knative CRDs, continuing...${NC}"
        return 1
    fi

    # Install Knative Core
    if ! log_command "kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.17.0/serving-core.yaml" "Install Knative Core"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Knative Core, continuing...${NC}"
        return 1
    fi

    # Install Knative Kourier
    if ! log_command "kubectl apply -f https://github.com/knative/net-kourier/releases/download/knative-v1.17.0/kourier.yaml" "Install Knative Kourier"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Kourier, continuing...${NC}"
        return 1
    fi

    # Configure Knative networking
    if ! kubectl patch configmap/config-network \
        --namespace knative-serving \
        --type merge \
        --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}' > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Warning: Failed to configure Knative networking, continuing...${NC}"
        return 1
    fi

    # Configure autoscaler and features
    echo -e "${BLUE}Configuring Knative autoscaler and features...${NC}"
    
    # Configure autoscaler
    if ! log_command "kubectl patch configmap/config-autoscaler \
        --namespace knative-serving \
        --type merge \
        --patch '{\"data\":{\"enable-scale-to-zero\":\"true\"}}'" "Configure Knative autoscaler"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to configure Knative autoscaler${NC}"
        return 1
    fi

    # Configure features
    if ! log_command "kubectl patch configmap/config-features \
        --namespace knative-serving \
        --type merge \
        --patch '{\"data\":{\"kubernetes.podspec-schedulername\":\"enabled\",\"kubernetes.podspec-affinity\":\"enabled\",\"kubernetes.podspec-tolerations\":\"enabled\",\"kubernetes.podspec-volumes-emptydir\":\"enabled\",\"kubernetes.podspec-securitycontext\":\"enabled\",\"kubernetes.containerspec-addcapabilities\":\"enabled\",\"kubernetes.podspec-persistent-volume-claim\":\"enabled\",\"kubernetes.podspec-persistent-volume-write\":\"enabled\",\"multi-container\":\"enabled\",\"kubernetes.podspec-init-containers\":\"enabled\"}}'" "Configure Knative features"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to configure Knative features${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ Knative installation completed${NC}"
    return 0
} 