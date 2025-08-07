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
    
    # Get all headnodes and handle cluster mode
    local all_headnodes=$(cmsh -c "device list" | grep -i headnode | awk '{print $2}')
    local headnode_count=$(echo "$all_headnodes" | wc -l)
    
    if [ -z "$all_headnodes" ]; then
        echo -e "${RED}❌ Error: Could not find headnode in Bright Cluster Manager${NC}"
        return 1
    fi
    
    # Always use the current node (where --BCM is run from)
    local current_hostname=$(hostname)
    local headnode="$current_hostname"
    
    # Verify current node is a headnode
    if ! echo "$all_headnodes" | grep -q "$current_hostname"; then
        echo -e "${RED}❌ Error: Current node ($current_hostname) is not a headnode in Bright Cluster Manager${NC}"
        echo -e "${YELLOW}Available headnodes:${NC}"
        echo "$all_headnodes" | while read -r hn; do
            echo -e "${YELLOW}  - $hn${NC}"
        done
        return 1
    fi
    
    echo -e "${GREEN}✅ Using current node: $headnode${NC}"
    
    # If other headnodes exist, provide manual commands
    if [ "$headnode_count" -gt 1 ]; then
        echo -e "${YELLOW}⚠️ Detected BCM cluster mode with $headnode_count headnodes${NC}"
        echo -e "${YELLOW}   Additional headnodes found:${NC}"
        echo "$all_headnodes" | grep -v "$current_hostname" | while read -r other_headnode; do
            echo -e "${YELLOW}     - $other_headnode${NC}"
        done
        echo -e "${YELLOW}   Run this command on each additional headnode:${NC}"
        echo -e "${CYAN}     cmsh -c 'device use $other_headnode; roles; use nginx; nginxreverseproxy; add 443 $last_node $https_port \"runai\"; commit'${NC}"
    fi

    # Check if nginx reverse proxy entry already exists for port 443
    echo -e "${BLUE}Checking for existing nginx reverse proxy entries...${NC}"
    local existing_entries=$(cmsh -c "device use $headnode; roles; use nginx; nginxreverseproxy; list" 2>/dev/null | grep "443" || true)
    
    if [ -n "$existing_entries" ]; then
        echo -e "${YELLOW}⚠️ Nginx reverse proxy entry already exists for port 443${NC}"
        echo -e "${YELLOW}   Existing entries:${NC}"
        echo "$existing_entries" | while read -r entry; do
            echo -e "${YELLOW}     $entry${NC}"
        done
        echo -e "${GREEN}✅ Run.ai is already accessible via Bright Cluster Manager at https://$DNS_NAME${NC}"
        return 0
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
        echo -e "${YELLOW}⚠️ Warning: Failed to add nginx reverse proxy entry${NC}"
        echo -e "${YELLOW}This might be due to an existing entry. Checking current configuration...${NC}"
        
        # Show current nginx reverse proxy configuration
        local current_config=$(cmsh -c "device use $headnode; roles; use nginx; nginxreverseproxy; list" 2>/dev/null || echo "No configuration found")
        echo -e "${YELLOW}Current nginx reverse proxy configuration:${NC}"
        if [ "$current_config" = "No configuration found" ]; then
            echo -e "${YELLOW}  No nginx reverse proxy entries found${NC}"
        else
            echo "$current_config" | while read -r line; do
                echo -e "${YELLOW}  $line${NC}"
            done
        fi
        
        echo -e "${GREEN}✅ Continuing with installation - Run.ai may already be accessible${NC}"
        return 0
    fi

    echo -e "${GREEN}✅ Successfully configured Bright Cluster Manager nginx reverse proxy${NC}"
    echo -e "${GREEN}✅ Run.ai is now accessible via Bright Cluster Manager at https://$DNS_NAME${NC}"

    return 0
} 