#!/bin/bash

# Subdomain Support Module for Run.ai Installer
# This module handles wildcard ingress creation for subdomain support

echo "Subdomain support module loaded at $(date)"

# Function to create wildcard ingress for subdomain support
create_subdomain_ingress() {
    echo -e "${BLUE}Creating wildcard ingress for subdomain support...${NC}"
    
    # Check if DNS_NAME is set
    if [ -z "$DNS_NAME" ]; then
        echo -e "${RED}❌ Error: DNS_NAME is required for subdomain support${NC}"
        return 1
    fi
    
    # Create the wildcard ingress YAML
    cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: runai-cluster-domain-star-ingress
  namespace: runai
spec:
  ingressClassName: nginx
  rules:
  - host: '*.$DNS_NAME'
  tls:
  - hosts:
    - '*.$DNS_NAME'
    secretName: runai-cluster-domain-star-tls-secret
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Wildcard ingress created successfully${NC}"
        
        # Log the command (don't re-execute, just log the success)
        if command -v log_command &> /dev/null; then
            log_command "echo 'Wildcard ingress applied successfully'" "Create wildcard ingress for subdomain support"
        fi
    else
        echo -e "${RED}❌ Failed to create wildcard ingress${NC}"
        return 1
    fi
}

# Function to enable subdomain support in RunaiConfig
enable_subdomain_support() {
    echo -e "${BLUE}Enabling subdomain support in RunaiConfig...${NC}"
    
    # Check if RunaiConfig already has subdomain support enabled
    echo -e "${BLUE}Checking current subdomain support status...${NC}"
    local current_subdomain=$(kubectl get runaiconfig runai -n runai -o jsonpath='{.spec.global.subdomainSupport}' 2>/dev/null)
    
    if [ "$current_subdomain" = "true" ]; then
        echo -e "${GREEN}✅ Subdomain support is already enabled in RunaiConfig${NC}"
        return 0
    fi
    
    # Wait for all Run.ai pods to be ready (simplified check)
    echo -e "${BLUE}Waiting for Run.ai pods to be ready...${NC}"
    local max_attempts=12  # 1 minute max wait
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        TOTAL_PODS=$(kubectl get pods -n runai --no-headers | wc -l)
        RUNNING_PODS=$(kubectl get pods -n runai --no-headers | grep "Running" | wc -l)
        NOT_READY=$((TOTAL_PODS - RUNNING_PODS))

        echo -e "${YELLOW}⏳ Waiting for Run.ai pods... ($RUNNING_PODS/$TOTAL_PODS ready, attempt $((attempt + 1))/$max_attempts)${NC}"

        if [ "$NOT_READY" -eq 0 ] && [ "$TOTAL_PODS" -gt 0 ]; then
            echo -e "${GREEN}✅ All Run.ai pods are ready, applying subdomain support patch${NC}"
            break
        fi
        
        sleep 5
        ((attempt++))
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo -e "${YELLOW}⚠️ Timeout waiting for all pods to be ready, proceeding with patch anyway${NC}"
    fi
    
    # Apply the patch
    if kubectl patch RunaiConfig runai -n runai --type="merge" \
        -p '{"spec":{"global":{"subdomainSupport": true}}}'; then
        echo -e "${GREEN}✅ Subdomain support enabled successfully${NC}"
        
        # Log the command
        if command -v log_command &> /dev/null; then
            log_command "kubectl patch RunaiConfig runai -n runai --type=\"merge\" -p '{\"spec\":{\"global\":{\"subdomainSupport\": true}}}'" "Enable subdomain support"
        fi
    else
        echo -e "${RED}❌ Failed to enable subdomain support${NC}"
        return 1
    fi
}

# Function to handle subdomain support setup
handle_subdomain_support() {
    echo -e "${BLUE}Setting up subdomain support...${NC}"
    
    # Create wildcard ingress
    if create_subdomain_ingress; then
        echo -e "${GREEN}✅ Wildcard ingress created${NC}"
    else
        echo -e "${RED}❌ Failed to create wildcard ingress${NC}"
        return 1
    fi
    
    # Enable subdomain support (patch will be applied after all pods are ready)
    if enable_subdomain_support; then
        echo -e "${GREEN}✅ Subdomain support enabled${NC}"
    else
        echo -e "${RED}❌ Failed to enable subdomain support${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Subdomain support setup completed successfully${NC}"
    return 0
}
