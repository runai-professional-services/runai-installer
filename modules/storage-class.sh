#!/bin/bash

# Function to install Local Path Provisioner and set as default storage class
install_storage_class() {
    echo -e "${BLUE}Installing Local Path Provisioner...${NC}"

    # Check if Local Path Provisioner is already installed
    if kubectl get storageclass local-path &> /dev/null; then
        echo -e "${BLUE}Local Path Provisioner already installed.${NC}"
        
        # Check if it's already the default
        if kubectl get storageclass local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -q "true"; then
            echo -e "${GREEN}✅ Local Path Provisioner is already set as default storage class${NC}"
            return 0
        else
            echo -e "${BLUE}Setting Local Path Provisioner as default storage class...${NC}"
        fi
    else
        # Install Local Path Provisioner
        echo -e "${BLUE}Installing Local Path Provisioner...${NC}"
        if ! log_command "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml" "Install Local Path Provisioner"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to install Local Path Provisioner, continuing...${NC}"
            return 1
        else
            echo -e "${GREEN}✅ Local Path Provisioner installed successfully!${NC}"
            
            # Wait for the storage class to be available
            echo -e "${BLUE}Waiting for storage class to be available...${NC}"
            sleep 10
        fi
    fi

    # Set Local Path Provisioner as default storage class
    echo -e "${BLUE}Setting Local Path Provisioner as default storage class...${NC}"
    
    # First, remove default annotation from any existing default storage class
    local current_default=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
    if [ -n "$current_default" ]; then
        echo -e "${BLUE}Removing default annotation from existing storage class: $current_default${NC}"
        if ! log_command "kubectl patch storageclass $current_default -p '{\"metadata\": {\"annotations\": {\"storageclass.kubernetes.io/is-default-class\": \"false\"}}}'" "Remove default from existing storage class"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to remove default annotation from $current_default${NC}"
        fi
    fi

    # Set Local Path Provisioner as default
    if ! log_command "kubectl patch storageclass local-path -p '{\"metadata\": {\"annotations\": {\"storageclass.kubernetes.io/is-default-class\": \"true\"}}}'" "Set Local Path Provisioner as default storage class"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to set Local Path Provisioner as default storage class${NC}"
        return 1
    fi

    # Verify the change
    if kubectl get storageclass local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -q "true"; then
        echo -e "${GREEN}✅ Local Path Provisioner successfully set as default storage class${NC}"
        
        return 0
    else
        echo -e "${RED}❌ Failed to verify Local Path Provisioner as default storage class${NC}"
        return 1
    fi
} 