#!/bin/bash

# Function to install Nginx Ingress Controller
install_nginx() {
    echo -e "${BLUE}Installing Nginx Ingress Controller...${NC}"

    # Check if Nginx Ingress is already installed
    if kubectl get ns ingress-nginx &> /dev/null && kubectl get svc -n ingress-nginx ingress-nginx-controller &> /dev/null; then
        echo -e "${BLUE}Nginx Ingress Controller already installed.${NC}"
        if [ -n "$IP_ADDRESS" ]; then
            patch_nginx_service
        fi
        return 0
    fi

    # Install Nginx Ingress Controller
    if ! log_command "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx" "Add Nginx Ingress Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add nginx helm repo, continuing...${NC}"
        return 1
    fi

    if ! log_command "helm repo update" "Update Helm repos"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to update helm repos, continuing...${NC}"
        return 1
    fi

    # Set Helm install options
    HELM_OPTS="--namespace ingress-nginx --create-namespace --set controller.kind=DaemonSet"
    if [ -n "$IP_ADDRESS" ]; then
        HELM_OPTS="$HELM_OPTS --set controller.service.externalIPs=\"{$IP_ADDRESS}\""
    fi

    if ! log_command "helm upgrade -i nginx-ingress ingress-nginx/ingress-nginx $HELM_OPTS" "Install Nginx Ingress Controller"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install nginx ingress, continuing...${NC}"
        return 1
    else
        echo -e "${GREEN}✅ Nginx Ingress Controller installed successfully!${NC}"

        # Double-check that externalIPs is set correctly
        if [ -n "$IP_ADDRESS" ] && ! kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.externalIPs[0]}' | grep -q "$IP_ADDRESS"; then
            echo -e "${YELLOW}⚠️ Warning: externalIPs not set correctly during installation, attempting to patch...${NC}"
            patch_nginx_service
        fi
    fi

    return 0
}

# Function to patch Nginx Ingress Controller service
patch_nginx_service() {
    echo -e "${BLUE}Patching Nginx Ingress Controller service with IP: $IP_ADDRESS${NC}"

    # First, check if the service exists
    if ! kubectl get svc -n ingress-nginx ingress-nginx-controller &> /dev/null; then
        echo -e "${YELLOW}⚠️ Warning: Nginx Ingress Controller service not found${NC}"
        return 1
    fi

    # Check if the externalIP is already set to our IP
    CURRENT_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
    if [ "$CURRENT_IP" = "$IP_ADDRESS" ]; then
        echo -e "${GREEN}✅ Nginx Ingress Controller already has the correct externalIP: $IP_ADDRESS${NC}"
        return 0
    fi

    # Simple direct patch
    if ! log_command "kubectl -n ingress-nginx patch svc ingress-nginx-controller --type='merge' -p \"{\\\"spec\\\":{\\\"externalIPs\\\":[\\\"$IP_ADDRESS\\\"]}}\"" "Patch Nginx Ingress Controller service"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to patch Nginx Ingress service, you may need to manually set externalIPs to $IP_ADDRESS${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ Successfully patched Nginx Ingress Controller with externalIP: $IP_ADDRESS${NC}"
    return 0
} 