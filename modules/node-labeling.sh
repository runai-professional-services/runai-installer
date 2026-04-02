#!/bin/bash

# Node Labeling Module for Run.ai Installer
# This module handles node labeling functionality for Run.ai system roles

echo "Node labeling module loaded at $(date)"

# Function to detect GPU nodes in the cluster
detect_gpu_nodes() {
    echo -e "${BLUE}Detecting GPU nodes in the cluster...${NC}"
    
    # Get all nodes and check for GPU resources
    local gpu_nodes=()
    local all_nodes=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name)
    
    if [ -z "$all_nodes" ]; then
        echo -e "${RED}❌ Error: Could not retrieve nodes from cluster${NC}"
        return 1
    fi
    
    while read -r node; do
        # Check if node has GPU resources (multiple ways to detect GPUs)
        local gpu_count=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null)
        local gpu_product=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu\.product}' 2>/dev/null)
        local gpu_memory=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu\.memory}' 2>/dev/null)
        
        # Check GPU labels (alternative detection method)
        local gpu_label_count=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.count}' 2>/dev/null)
        local gpu_label_product=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null)
        local gpu_label_present=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.present}' 2>/dev/null)
        
        # Check if node has any GPU-related resources
        if [ -n "$gpu_count" ] && [ "$gpu_count" != "0" ]; then
            gpu_nodes+=("$node")
            echo -e "${GREEN}✅ Found GPU node: $node (GPUs: $gpu_count)${NC}"
        elif [ -n "$gpu_product" ] || [ -n "$gpu_memory" ]; then
            gpu_nodes+=("$node")
            echo -e "${GREEN}✅ Found GPU node: $node (GPU product: $gpu_product, GPU memory: $gpu_memory)${NC}"
        elif [ -n "$gpu_label_count" ] && [ "$gpu_label_count" != "0" ]; then
            gpu_nodes+=("$node")
            echo -e "${GREEN}✅ Found GPU node: $node (GPU count: $gpu_label_count, product: $gpu_label_product)${NC}"
        elif [ -n "$gpu_label_present" ] && [ "$gpu_label_present" = "true" ]; then
            gpu_nodes+=("$node")
            echo -e "${GREEN}✅ Found GPU node: $node (GPU present: $gpu_label_present, product: $gpu_label_product)${NC}"
        fi
    done <<< "$all_nodes"
    
    # Store GPU nodes count globally for use in other functions
    GPU_NODES_COUNT=${#gpu_nodes[@]}
    GPU_NODES_LIST=("${gpu_nodes[@]}")
    
    if [ "$GPU_NODES_COUNT" -eq 0 ]; then
        echo -e "${BLUE}ℹ️ No GPU nodes detected in the cluster${NC}"
        return 1
    else
        echo -e "${GREEN}✅ Found $GPU_NODES_COUNT GPU node(s)${NC}"
        return 0
    fi
}

# Function to label CPU nodes with runai-system role
# Parameters:
#   $1 - Optional: Comma-separated list of node names to label (e.g., "server1,server2")
label_cpu_nodes_for_runai_system() {
    local user_specified_nodes="$1"
    
    echo -e "${BLUE}Labelingdd CPU nodes with Run.ai system role...${NC}"
    
    local labeled_count=0
    local labeled_nodes=()
    
    # If user specified nodes, label only those nodes
    if [ -n "$user_specified_nodes" ]; then
        echo -e "${BLUE}ℹ️  Using user-specified nodes: $user_specified_nodes${NC}"
        
        # Convert comma-separated list to array
        IFS=',' read -ra nodes_to_label <<< "$user_specified_nodes"
        
        # Validate and label each specified node
        for node in "${nodes_to_label[@]}"; do
            # Trim whitespace
            node=$(echo "$node" | xargs)
            
            # Check if node exists in the cluster
            if ! kubectl get node "$node" &>/dev/null; then
                echo -e "${RED}❌ Error: Node '$node' does not exist in the cluster${NC}"
                continue
            fi
            
            # Apply the runai-system label
            if kubectl label node "$node" node-role.kubernetes.io/runai-system=true --overwrite=true 2>/dev/null; then
                labeled_nodes+=("$node")
                ((labeled_count++))
                
                # Log the command (if log_command function is available)
                if command -v log_command &> /dev/null; then
                    log_command "kubectl label node $node node-role.kubernetes.io/runai-system=true --overwrite=true" "Label user-specified node for Run.ai system"
                fi
            else
                echo -e "${RED}❌ Failed to label node '$node'${NC}"
            fi
        done
        
    else
        # No nodes specified - skip labeling and continue with installation
        echo -e "${BLUE}ℹ️  No nodes specified for labeling, skipping node labeling${NC}"
        return 0
    fi
    
    # Show final summary
    if [ "$labeled_count" -gt 0 ]; then
        echo -e "${GREEN}✅ Labeled $labeled_count node(s) for Run.ai system services: ${labeled_nodes[*]}${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to label any nodes${NC}"
        return 1
    fi
}

# Function to handle Run.ai node labeling based on GPU detection
# Parameters:
#   $1 - Optional: Comma-separated list of node names to label (e.g., "server1,server2")
handle_runai_node_labeling() {
    local user_specified_nodes="$1"
    
    # Detect GPU nodes first (silently)
    detect_gpu_nodes > /dev/null 2>&1
    
    # Label CPU nodes for Run.ai system role (with user-specified nodes if provided)
    if label_cpu_nodes_for_runai_system "$user_specified_nodes"; then
        return 0
    else
        echo -e "${RED}❌ Failed to label nodes for Run.ai system role${NC}"
        return 1
    fi
}



