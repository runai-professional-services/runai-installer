#!/bin/bash

echo "BCM module loaded at $(date)"
echo "Script path: $0"
echo "Current directory: $(pwd)"

# Function to check if BCM is available
check_bcm_available() {
    echo -e "${BLUE}Checking if Bright Cluster Manager is available...${NC}"
    
    # Check if cmsh command exists
    if ! command -v cmsh &> /dev/null; then
        echo -e "${RED}❌ Error: cmsh command not found. Please ensure Bright Cluster Manager is installed.${NC}"
        return 1
    fi
    
    # Check if we can connect to BCM
    if ! cmsh -c "device list" &> /dev/null; then
        echo -e "${RED}❌ Error: Could not connect to Bright Cluster Manager. Please check your BCM installation and permissions.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Bright Cluster Manager is available${NC}"
    return 0
}

# Function to configure Bright Cluster Manager
configure_bcm() {
    echo -e "${BLUE}Starting Bright Cluster Manager configuration...${NC}"
    
    # First check if BCM is available
    if ! check_bcm_available; then
        echo -e "${RED}❌ Bright Cluster Manager configuration failed: BCM not available${NC}"
        return 1
    fi

    # Step 1: Get the HTTPS port from ingress-nginx-controller
    echo -e "${BLUE}Getting HTTPS port from ingress-nginx-controller...${NC}"
    if ! kubectl get ns ingress-nginx &> /dev/null; then
        echo -e "${RED}❌ Error: ingress-nginx namespace not found. Please ensure Nginx Ingress Controller is installed.${NC}"
        return 1
    fi

    local nginx_ports=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')

    if [ -z "$nginx_ports" ]; then
        echo -e "${RED}❌ Error: Could not find HTTPS nodePort in ingress-nginx-controller${NC}"
        return 1
    fi

    local https_port=$nginx_ports
    echo -e "${GREEN}✅ Found HTTPS nodePort: $https_port${NC}"

    # Step 2: Get the last node name from kubectl get nodes
    echo -e "${BLUE}Getting the last worker node name...${NC}"
    local last_node=$(kubectl get nodes --sort-by=.metadata.name -o jsonpath='{.items[-1:].metadata.name}')

    if [ -z "$last_node" ]; then
        echo -e "${RED}❌ Error: Could not find any nodes in the cluster${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ Found last node: $last_node${NC}"

    # Step 3: Verify the node exists in Bright Cluster Manager
    echo -e "${BLUE}Verifying node exists in Bright Cluster Manager...${NC}"
    if ! cmsh -c "device list" | grep -q "$last_node"; then
        echo -e "${RED}❌ Error: Node $last_node not found in Bright Cluster Manager${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ Node $last_node found in Bright Cluster Manager${NC}"

    # Step 4: Configure nginx reverse proxy in Bright Cluster Manager
    echo -e "${BLUE}Configuring nginx reverse proxy in Bright Cluster Manager...${NC}"
    local headnode=$(cmsh -c "device list" | grep -i headnode | awk '{print $2}')

    if [ -z "$headnode" ]; then
        echo -e "${RED}❌ Error: Could not find headnode in Bright Cluster Manager${NC}"
        return 1
    fi

    # Create a temporary file with cmsh commands
    local bcm_temp="$TEMP_DIR/bcm-temp"
    cat > "$bcm_temp" << EOF
device use $headnode
roles
use nginx
nginxreverseproxy
add 443 $last_node $https_port 'runai'
commit
EOF

    # Execute the cmsh commands from the file
    if ! cmsh -q -x -f "$bcm_temp"; then
        echo -e "${RED}❌ Error: Failed to configure Bright Cluster Manager nginx reverse proxy${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ Successfully configured Bright Cluster Manager nginx reverse proxy${NC}"
    echo -e "${GREEN}✅ Run.ai is now accessible via Bright Cluster Manager at https://$DNS_NAME${NC}"

    return 0
} 