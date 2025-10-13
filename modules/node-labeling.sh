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
label_cpu_nodes_for_runai_system() {
    echo -e "${BLUE}Labeling CPU nodes with Run.ai system role...${NC}"
    
    # Get all nodes
    local all_nodes=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name)
    
    if [ -z "$all_nodes" ]; then
        echo -e "${RED}❌ Error: Could not retrieve nodes from cluster${NC}"
        return 1
    fi
    
    local labeled_count=0
    local max_cpu_nodes=2
    
    while read -r node; do
        # Check if we've already labeled the maximum number of CPU nodes
        if [ "$labeled_count" -ge "$max_cpu_nodes" ]; then
            echo -e "${BLUE}ℹ️ Maximum CPU nodes ($max_cpu_nodes) already labeled - skipping remaining nodes${NC}"
            break
        fi
        
        # Check if this is a master/control-plane node
        local is_master=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}' 2>/dev/null)
        local is_control_plane=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null)
        
        # Skip master/control-plane nodes
        if [ -n "$is_master" ] || [ -n "$is_control_plane" ]; then
            echo -e "${BLUE}ℹ️ Skipping master/control-plane node: $node${NC}"
            continue
        fi
        
        # Check if node has GPU resources (multiple ways to detect GPUs)
        local gpu_count=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null)
        local gpu_product=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu\.product}' 2>/dev/null)
        local gpu_memory=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu\.memory}' 2>/dev/null)
        
        # Check GPU labels (alternative detection method)
        local gpu_label_count=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.count}' 2>/dev/null)
        local gpu_label_product=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null)
        local gpu_label_present=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.present}' 2>/dev/null)
        
        # Only label nodes that don't have GPUs
        if ([ -z "$gpu_count" ] || [ "$gpu_count" = "0" ]) && [ -z "$gpu_product" ] && [ -z "$gpu_memory" ] && 
           ([ -z "$gpu_label_count" ] || [ "$gpu_label_count" = "0" ]) && [ -z "$gpu_label_present" ]; then
            # Apply the runai-system label
            if kubectl label node "$node" node-role.kubernetes.io/runai-system=true --overwrite=true; then
                echo -e "${GREEN}✅ Labeled CPU node: $node${NC}"
                ((labeled_count++))
                
                # Log the command (if log_command function is available)
                if command -v log_command &> /dev/null; then
                    log_command "kubectl label node $node node-role.kubernetes.io/runai-system=true --overwrite=true" "Label CPU node for Run.ai system"
                fi
            else
                echo -e "${RED}❌ Failed to label node: $node${NC}"
            fi
        else
            if [ -n "$gpu_count" ] && [ "$gpu_count" != "0" ]; then
                echo -e "${BLUE}ℹ️ GPU node detected: $node (has $gpu_count GPUs) - will be used for workloads${NC}"
            elif [ -n "$gpu_label_count" ] && [ "$gpu_label_count" != "0" ]; then
                echo -e "${BLUE}ℹ️ GPU node detected: $node (GPU count: $gpu_label_count, product: $gpu_label_product) - will be used for workloads${NC}"
            elif [ -n "$gpu_label_present" ] && [ "$gpu_label_present" = "true" ]; then
                echo -e "${BLUE}ℹ️ GPU node detected: $node (GPU present: $gpu_label_present, product: $gpu_label_product) - will be used for workloads${NC}"
            else
                echo -e "${BLUE}ℹ️ GPU node detected: $node (GPU product: $gpu_product, GPU memory: $gpu_memory) - will be used for workloads${NC}"
            fi
        fi
    done <<< "$all_nodes"
    
    if [ "$labeled_count" -gt 0 ]; then
        echo -e "${GREEN}✅ Successfully labeled $labeled_count CPU node(s) for Run.ai system services${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ No CPU nodes were labeled${NC}"
        return 1
    fi
}

# Function to handle Run.ai node labeling based on GPU detection
handle_runai_node_labeling() {
    echo -e "${BLUE}Handling Run.ai node labeling...${NC}"
    
    # Detect GPU nodes first
    if detect_gpu_nodes; then
        echo -e "${GREEN}✅ GPU nodes detected - Run.ai workloads will use GPU nodes${NC}"
        echo -e "${BLUE}CPU nodes will be labeled for Run.ai system services${NC}"
        
        # Label CPU nodes for Run.ai system role even when GPU nodes exist
        if label_cpu_nodes_for_runai_system; then
            echo -e "${GREEN}✅ CPU nodes successfully labeled for Run.ai system role${NC}"
            return 0
        else
            echo -e "${RED}❌ Failed to label CPU nodes for Run.ai system role${NC}"
            return 1
        fi
    else
        echo -e "${BLUE}ℹ️ CPU-only cluster detected - labeling all nodes for Run.ai system role${NC}"
        
        # Label CPU nodes for Run.ai system role
        if label_cpu_nodes_for_runai_system; then
            echo -e "${GREEN}✅ CPU nodes successfully labeled for Run.ai system role${NC}"
            return 0
        else
            echo -e "${RED}❌ Failed to label CPU nodes for Run.ai system role${NC}"
            return 1
        fi
    fi
}



