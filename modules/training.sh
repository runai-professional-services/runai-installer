#!/bin/bash

# Function to install Kubeflow Training Operator
install_training_operator() {
    echo -e "${BLUE}Installing Kubeflow Training Operator...${NC}"

    # Check if Training Operator is already installed
    if kubectl get crd pytorchjobs.kubeflow.org &> /dev/null; then
        echo -e "${BLUE}Kubeflow Training Operator already installed.${NC}"
        return 0
    fi

    # Install Kubeflow Training Operator
    if ! log_command "kubectl apply -k \"github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=v1.9.2\"" "Install Kubeflow Training Operator"; then
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