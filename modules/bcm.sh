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
    
    # Log BCM configuration details
    log_command "echo 'BCM Configuration - Current node: $headnode'" "BCM headnode configuration"
    log_command "echo 'All headnodes: $all_headnodes'" "BCM headnode detection"
    log_command "echo 'Headnode count: $headnode_count'" "BCM cluster mode detection"
    
    # If other headnodes exist, provide manual commands
    if [ "$headnode_count" -gt 1 ]; then
        echo -e "${YELLOW}⚠️ Detected BCM cluster mode with $headnode_count headnodes${NC}"
        echo -e "${YELLOW}   Additional headnodes found:${NC}"
        echo "$all_headnodes" | grep -v "$current_hostname" | while read -r other_headnode; do
            echo -e "${YELLOW}     - $other_headnode${NC}"
        done
        echo -e "${YELLOW}   Run this command on each additional headnode:${NC}"
        echo -e "${CYAN}     cmsh -c 'device use $other_headnode; roles; use nginx; nginxreverseproxy; add 443 $last_node $https_port \"runai\"; commit'${NC}"
        
        log_command "echo 'BCM cluster mode detected - additional headnodes need manual configuration'" "BCM cluster mode warning"
    fi

    # Check if nginx reverse proxy entry already exists for Run.ai on port 443
    echo -e "${BLUE}Checking for existing nginx reverse proxy entries...${NC}"
    local all_entries=$(cmsh -c "device use $headnode; roles; use nginx; nginxreverseproxy; list" 2>/dev/null || true)
    local runai_entry=$(echo "$all_entries" | grep "443.*runai" || true)
    
    log_command "cmsh -c 'device use $headnode; roles; use nginx; nginxreverseproxy; list'" "Check existing nginx reverse proxy entries"
    
    # Show all existing entries for information
    if [ -n "$all_entries" ]; then
        echo -e "${YELLOW}   Existing entries:${NC}"
        echo "$all_entries" | while read -r entry; do
            echo -e "${YELLOW}     $entry${NC}"
        done
    fi
    
    # Check specifically for Run.ai entry
    if [ -n "$runai_entry" ]; then
        echo -e "${BLUE}Run.ai nginx reverse proxy entry found. Validating...${NC}"
        # Expected format example:
        # 0      443    metal-server3    30443   'runai'
        local entry_index existing_node existing_port
        entry_index=$(echo "$runai_entry" | awk '{print $1}')
        existing_node=$(echo "$runai_entry" | awk '{print $3}')
        existing_port=$(echo "$runai_entry" | awk '{print $4}')

        if [ -z "$entry_index" ] || [ -z "$existing_port" ]; then
            echo -e "${YELLOW}⚠️ Could not parse existing Run.ai entry. Will attempt to add a corrected entry.${NC}"
        elif [ "$existing_port" = "$https_port" ] && [ "$existing_node" = "$last_node" ]; then
            echo -e "${GREEN}✅ Existing Run.ai entry is correct (node: $existing_node, port: $existing_port)${NC}"
            log_command "echo 'Run.ai nginx reverse proxy entry is correct - nothing to change'" "BCM Run.ai entry validated"
            return 0
        else
            echo -e "${YELLOW}⚠️ Existing Run.ai entry uses node '$existing_node' and port '$existing_port', but service exposes nodePort '$https_port' on node '$last_node'.${NC}"
            echo -e "${BLUE}Updating BCM nginx reverse proxy entry to the correct nodePort...${NC}"

            # Prepare an update script: delete the wrong entry by index, then add the correct one
            local bcm_update="$TEMP_DIR/bcm-update-temp"
            cat > "$bcm_update" << EOF
device use $headnode
roles
use nginx
nginxreverseproxy
delete $entry_index
add 443 $last_node $https_port 'runai'
commit
EOF

            log_command "cat $bcm_update" "BCM nginx update commands"
            if ! log_command "cmsh -q -x -f $bcm_update" "Execute BCM nginx update"; then
                echo -e "${RED}❌ Failed to update nginx reverse proxy entry in BCM${NC}"
                return 1
            fi

            # Re-list and confirm
            local confirm_entries=$(cmsh -c "device use $headnode; roles; use nginx; nginxreverseproxy; list" 2>/dev/null || true)
            local confirm_runai=$(echo "$confirm_entries" | grep "443.*runai" || true)
            if echo "$confirm_runai" | awk '{print $3" "$4}' | grep -q "^$last_node $https_port$"; then
                echo -e "${GREEN}✅ BCM nginx reverse proxy entry updated (node: $last_node, port: $https_port)${NC}"
                return 0
            else
                echo -e "${RED}❌ BCM nginx reverse proxy entry did not update as expected${NC}"
                echo -e "${YELLOW}Current entries:${NC}"
                echo "$confirm_entries"
                return 1
            fi
        fi
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

    echo -e "${BLUE}BCM configuration commands:${NC}"
    cat "$bcm_temp"
    echo ""
    
    log_command "cat $bcm_temp" "BCM nginx configuration commands"
    
    # Execute the cmsh commands from the file
    echo -e "${BLUE}Executing BCM nginx configuration...${NC}"
    if ! log_command "cmsh -q -x -f $bcm_temp" "Execute BCM nginx configuration"; then
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

    # Verify the entry was added
    echo -e "${BLUE}Verifying nginx reverse proxy entry was added...${NC}"
    local updated_entries=$(cmsh -c "device use $headnode; roles; use nginx; nginxreverseproxy; list" 2>/dev/null || true)
    local new_runai_entry=$(echo "$updated_entries" | grep "443.*runai" || true)
    
    if [ -n "$new_runai_entry" ]; then
        echo -e "${GREEN}✅ Successfully configured Bright Cluster Manager nginx reverse proxy${NC}"
        echo -e "${GREEN}✅ Run.ai entry found: $new_runai_entry${NC}"
        echo -e "${GREEN}✅ Run.ai is now accessible via Bright Cluster Manager at https://$DNS_NAME${NC}"
    else
        echo -e "${RED}❌ Failed to add Run.ai nginx reverse proxy entry${NC}"
        echo -e "${YELLOW}Current nginx reverse proxy entries:${NC}"
        echo "$updated_entries" | while read -r entry; do
            echo -e "${YELLOW}  $entry${NC}"
        done
        return 1
    fi

    return 0
} 