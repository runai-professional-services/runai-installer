#!/bin/bash

# Function to create nginx values file
create_nginx_values() {
    local values_file="/tmp/nginx-values.yaml"
    
    cat > "$values_file" << 'EOF'
controller:
  allowSnippetAnnotations: true
  extraArgs:
    default-ssl-certificate: $(POD_NAMESPACE)/default-ingress-tls
    enable-ssl-passthrough: ""
    publish-service: $(POD_NAMESPACE)/ingress-nginx-controller
  replicaCount: 2
  service:
    externalTrafficPolicy: Cluster
    nodePorts:
      http: "30080"
      https: "30443"
    type: NodePort
  tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
      operator: Exists
    - effect: NoSchedule
      key: node-role.kubernetes.io/control-plane
      operator: Exists
EOF

    echo "$values_file"
}

# Function to install Nginx Ingress Controller
install_nginx() {
    echo -e "${BLUE}Installing Nginx Ingress Controller...${NC}"

    # Check if Nginx Ingress is already installed
    local existing_service=$(get_nginx_service_name)
    if kubectl get ns ingress-nginx &> /dev/null && [ -n "$existing_service" ]; then
        echo -e "${BLUE}Nginx Ingress Controller already installed.${NC}"
        if [ -n "$IP_ADDRESS" ]; then
            patch_nginx_service
        fi
        return 0
    fi

    # Create nginx values file
    local values_file=$(create_nginx_values)
    echo -e "${BLUE}Created nginx values file: $values_file${NC}"

    # Install Nginx Ingress Controller with specific version and values
    if ! log_command "helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --version 4.12.2 --namespace ingress-nginx --create-namespace -f $values_file > /dev/null 2>&1" "Install Nginx Ingress Controller"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install nginx ingress, continuing...${NC}"
        return 1
    else
        echo -e "${GREEN}✅ Nginx Ingress Controller installed successfully!${NC}"

        # Wait a moment for the service to be created
        echo -e "${BLUE}Waiting for nginx ingress service to be ready...${NC}"
        sleep 10

        # Double-check that externalIPs is set correctly if IP_ADDRESS is provided
        local service_name=$(get_nginx_service_name)
        if [ -n "$IP_ADDRESS" ] && [ -n "$service_name" ]; then
            if ! kubectl get svc -n ingress-nginx "$service_name" -o jsonpath='{.spec.externalIPs[0]}' | grep -q "$IP_ADDRESS"; then
                echo -e "${YELLOW}⚠️ Warning: externalIPs not set correctly during installation, attempting to patch...${NC}"
                patch_nginx_service
            fi
        fi
    fi

    # Clean up temporary values file
    rm -f "$values_file"

    return 0
}

# Function to get the actual nginx ingress controller service name
get_nginx_service_name() {
    local service_name=""
    
    # Try different possible service names in the correct namespace
    for name in "ingress-nginx-controller" "nginx-ingress-ingress-nginx-controller" "ingress-nginx-controller-admission"; do
        if kubectl get svc -n ingress-nginx "$name" &> /dev/null; then
            service_name="$name"
            break
        fi
    done
    
    echo "$service_name"
}

# Function to patch Nginx Ingress Controller service
patch_nginx_service() {
    # Validate IP_ADDRESS is set
    if [ -z "$IP_ADDRESS" ]; then
        echo -e "${RED}❌ Error: IP address is required for patching Nginx Ingress Controller${NC}"
        echo -e "${YELLOW}Please provide the IP address using the --ip parameter${NC}"
        return 1
    fi

    echo -e "${BLUE}Patching Nginx Ingress Controller service with IP: $IP_ADDRESS${NC}"

    # Get the actual service name
    local service_name=$(get_nginx_service_name)
    if [ -z "$service_name" ]; then
        echo -e "${RED}❌ Error: Could not find nginx ingress controller service${NC}"
        echo -e "${YELLOW}Available services in ingress-nginx namespace:${NC}"
        kubectl get svc -n ingress-nginx 2>/dev/null || echo "No services found"
        return 1
    fi

    echo -e "${BLUE}Found nginx service: $service_name${NC}"

    # Check if the externalIP is already set to our IP
    local current_ip=$(kubectl get svc -n ingress-nginx "$service_name" -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
    if [ "$current_ip" = "$IP_ADDRESS" ]; then
        echo -e "${GREEN}✅ Nginx Ingress Controller already has the correct externalIP: $IP_ADDRESS${NC}"
        return 0
    fi

    # If there's a different IP set, show a warning
    if [ -n "$current_ip" ]; then
        echo -e "${YELLOW}⚠️ Warning: Nginx Ingress Controller currently has externalIP: $current_ip${NC}"
        echo -e "${YELLOW}⚠️ This will be changed to: $IP_ADDRESS${NC}"
    fi

    # Apply the patch directly
    if ! log_command "kubectl patch svc -n ingress-nginx \"$service_name\" --type='merge' -p '{\"spec\":{\"externalIPs\":[\"$IP_ADDRESS\"]}}'" "Patch Nginx Ingress Controller service"; then
        echo -e "${RED}❌ Failed to patch Nginx Ingress service${NC}"
        echo -e "${YELLOW}⚠️ You may need to manually set externalIPs to $IP_ADDRESS${NC}"
        return 1
    fi

    # Verify the patch was applied
    local new_ip=$(kubectl get svc -n ingress-nginx "$service_name" -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
    if [ "$new_ip" = "$IP_ADDRESS" ]; then
        echo -e "${GREEN}✅ Successfully patched Nginx Ingress Controller with externalIP: $IP_ADDRESS${NC}"
    else
        echo -e "${RED}❌ Patch appeared to succeed but IP was not updated correctly${NC}"
        echo -e "${YELLOW}⚠️ Current IP: $new_ip, Expected: $IP_ADDRESS${NC}"
        return 1
    fi

    return 0
} 