#!/bin/bash

# Hardware Module for Sanity Check
# This module handles hardware requirements checking functionality

# Function to check hardware requirements
check_hardware_requirements() {
    log_message "${YELLOW}Checking hardware requirements...${NC}"
    log_message "${YELLOW}Minimum Required: 24GB RAM, 24 CPU Cores${NC}\n"

    # Check required components first
    check_required_components

    # Check Kubernetes version
    echo -e "${YELLOW}Checking Kubernetes version...${NC}"
    if ! command -v kubectl &>/dev/null; then
        echo -e "${RED}❌ kubectl not found${NC}\n"
    else
        K8S_VERSION=$(kubectl get nodes -o wide 2>/dev/null | awk 'NR==2 {print $5}')
        if [ -n "$K8S_VERSION" ]; then
            echo -e "${GREEN}✅ Kubernetes version: $K8S_VERSION${NC}"
            
            # Extract major.minor version
            K8S_MAJOR_MINOR=$(echo "$K8S_VERSION" | grep -oP 'v?\K\d+\.\d+')
            
            # Check Run.ai version compatibility
            echo -e "${YELLOW}Checking Run.ai version compatibility...${NC}"
            SUPPORTED_VERSIONS=""
            
            # Check each Run.ai version's compatibility
            if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(2[7-9]|3[0-4])$ ]]; then
                # v2.17 supports 1.27-1.29
                if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(2[7-9])$ ]]; then
                    SUPPORTED_VERSIONS="2.17"
                fi
                
                # v2.18 supports 1.28-1.30
                if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(2[8-9]|30)$ ]]; then
                    [ -n "$SUPPORTED_VERSIONS" ] && SUPPORTED_VERSIONS="$SUPPORTED_VERSIONS,"
                    SUPPORTED_VERSIONS="${SUPPORTED_VERSIONS}2.18"
                fi
                
                # v2.19 supports 1.28-1.31
                if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(2[8-9]|3[0-1])$ ]]; then
                    [ -n "$SUPPORTED_VERSIONS" ] && SUPPORTED_VERSIONS="$SUPPORTED_VERSIONS,"
                    SUPPORTED_VERSIONS="${SUPPORTED_VERSIONS}2.19"
                fi
                
                # v2.20 supports 1.29-1.32
                if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(2[9]|3[0-2])$ ]]; then
                    [ -n "$SUPPORTED_VERSIONS" ] && SUPPORTED_VERSIONS="$SUPPORTED_VERSIONS,"
                    SUPPORTED_VERSIONS="${SUPPORTED_VERSIONS}2.20"
                fi
                
                # v2.21 supports 1.30-1.32
                if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(3[0-2])$ ]]; then
                    [ -n "$SUPPORTED_VERSIONS" ] && SUPPORTED_VERSIONS="$SUPPORTED_VERSIONS,"
                    SUPPORTED_VERSIONS="${SUPPORTED_VERSIONS}2.21"
                fi
                
                # v2.22 supports 1.31-1.33
                if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(3[1-3])$ ]]; then
                    [ -n "$SUPPORTED_VERSIONS" ] && SUPPORTED_VERSIONS="$SUPPORTED_VERSIONS,"
                    SUPPORTED_VERSIONS="${SUPPORTED_VERSIONS}2.22"
                fi
                
                # v2.23 (latest) supports 1.31-1.34
                if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(3[1-4])$ ]]; then
                    [ -n "$SUPPORTED_VERSIONS" ] && SUPPORTED_VERSIONS="$SUPPORTED_VERSIONS,"
                    SUPPORTED_VERSIONS="${SUPPORTED_VERSIONS}2.23"
                fi
            fi
            
            if [ -n "$SUPPORTED_VERSIONS" ]; then
                echo -e "${GREEN}✅ Supported Run.ai versions: $SUPPORTED_VERSIONS${NC}"
            else
                echo -e "${RED}❌ No supported Run.ai versions found for Kubernetes $K8S_MAJOR_MINOR${NC}"
            fi
            echo ""
        else
            echo -e "${RED}❌ Could not determine Kubernetes version${NC}"
            echo -e "${YELLOW}Checking kubectl connection...${NC}"
            if kubectl cluster-info &>/dev/null; then
                echo -e "${GREEN}✅ kubectl is connected to cluster${NC}"
            else
                echo -e "${RED}❌ kubectl cannot connect to cluster${NC}"
            fi
            echo ""
        fi
    fi

    # List Storage Classes
    echo -e "${YELLOW}Storage Classes:${NC}"
    kubectl get storageclass -o name | while read -r sc; do
        echo -e "└─ $sc"
    done
    echo ""

    # Get all nodes
    NODES=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name)
    if [ -z "$NODES" ]; then
        echo -e "${RED}❌ No nodes found in the cluster${NC}"
        return 1
    fi

    NODE_COUNT=0
    TOTAL_CPU=0
    TOTAL_RAM_GB=0
    GPU_NODES=0
    TOTAL_GPUS=0

    while read -r node; do
        ((NODE_COUNT++))
        echo -e "${YELLOW}Checking node: ${GREEN}$node${NC}"

        # Get node roles
        local node_roles=""
        local has_master=false
        local has_worker=false
        
        # Check for control-plane role (newer label)
        if kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null | grep -q "true"; then
            has_master=true
        fi
        
        # Check for legacy master role
        if kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}' 2>/dev/null | grep -q "true"; then
            has_master=true
        fi
        
        # Check for worker role
        if kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/worker}' 2>/dev/null | grep -q "true"; then
            has_worker=true
        fi
        
        # Determine the role display
        if [ "$has_master" = true ] && [ "$has_worker" = true ]; then
            node_roles="master+worker"
        elif [ "$has_master" = true ]; then
            node_roles="master"
        elif [ "$has_worker" = true ]; then
            node_roles="worker"
        else
            # If no explicit roles found, check if it's a control-plane node (which can also run workloads)
            if [ "$has_master" = true ]; then
                node_roles="master+worker"
            else
                node_roles="worker"
            fi
        fi

        # Display node role with better formatting
        if [ "$node_roles" = "master+worker" ]; then
            echo -e "└─ Role: ${YELLOW}master+worker${NC} (control-plane + workload)"
        else
            echo -e "└─ Role: ${YELLOW}$node_roles${NC}"
        fi

        # Get OS information
        OS_INFO=$(kubectl get nodes "$node" -o wide --no-headers | awk '{for(i=8;i<=NF-1;i++) printf "%s ", $i; print ""}' | sed 's/ $//' | sed 's/containerd.*$//')
        echo -e "└─ OS: ${YELLOW}$OS_INFO${NC}"

        # Get CPU cores
        CPU_CORES=$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}')
        if [ -z "$CPU_CORES" ]; then
            echo -e "${RED}Failed to get CPU capacity for node $node${NC}"
            return 1
        fi
        TOTAL_CPU=$((TOTAL_CPU + CPU_CORES))

        # Get RAM and convert to GB
        RAM_RAW=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}')
        if [ -z "$RAM_RAW" ]; then
            echo -e "${RED}Failed to get memory capacity for node $node${NC}"
            return 1
        fi

        # Convert memory to GB
        if [[ $RAM_RAW == *Ki ]]; then
            RAM_GB=$((${RAM_RAW%Ki} / 1024 / 1024))
        elif [[ $RAM_RAW == *Mi ]]; then
            RAM_GB=$((${RAM_RAW%Mi} / 1024))
        elif [[ $RAM_RAW == *Gi ]]; then
            RAM_GB=${RAM_RAW%Gi}
        else
            RAM_GB=$((RAM_RAW / 1024 / 1024))
        fi
        TOTAL_RAM_GB=$((TOTAL_RAM_GB + RAM_GB))

        # Check for GPU resources
        GPU_COUNT=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}')
        if [ -n "$GPU_COUNT" ] && [ "$GPU_COUNT" != "0" ]; then
            ((GPU_NODES++))
            TOTAL_GPUS=$((TOTAL_GPUS + GPU_COUNT))
            echo -e "└─ GPU Count: ${YELLOW}$GPU_COUNT${NC}"
        fi

        # Show individual node resources
        echo -e "└─ CPU Cores: ${YELLOW}$CPU_CORES${NC}"
        echo -e "└─ RAM: ${YELLOW}${RAM_GB}GB${NC}"
        
        # Check storage for this node
        if ! check_node_storage "$node"; then
            echo -e "  └─ ${RED}❌ Storage check failed for this node${NC}"
        fi
        echo ""
    done <<< "$NODES"

    echo -e "${YELLOW}Cluster Resources Summary:${NC}"
    echo -e "----------------------------------------"
    echo -e "Total Nodes: $NODE_COUNT"
    echo -e "Total CPU Cores: ${YELLOW}$TOTAL_CPU${NC} (minimum: 24)"
    echo -e "Total RAM: ${YELLOW}${TOTAL_RAM_GB}GB${NC} (minimum: 24GB)"
    if [ "$GPU_NODES" -gt 0 ]; then
        echo -e "GPU Nodes: ${YELLOW}$GPU_NODES${NC}"
        echo -e "Total GPUs: ${YELLOW}$TOTAL_GPUS${NC}"
    else
        echo -e "GPU Nodes: ${RED}None detected${NC}"
    fi
    echo -e "Minimum Disk Space: ${YELLOW}110GB${NC} per node"
    echo -e "----------------------------------------"

    # Check total requirements
    REQUIREMENTS_MET=true
    MISSING_COMPONENTS=""
    
    if [ "$TOTAL_CPU" -lt 24 ]; then
        echo -e "${RED}❌ Insufficient total CPU cores ($TOTAL_CPU < 24)${NC}"
        REQUIREMENTS_MET=false
    fi

    if [ "$TOTAL_RAM_GB" -lt 24 ]; then
        echo -e "${RED}❌ Insufficient total RAM (${TOTAL_RAM_GB}GB < 24GB)${NC}"
        REQUIREMENTS_MET=false
    fi

    # Check GPU Operator status
    if ! echo "$HELM_RELEASES" | grep -q "gpu-operator"; then
        MISSING_COMPONENTS="GPU Operator"
    fi

    if [ "$REQUIREMENTS_MET" = true ]; then
        echo -e "${GREEN}✅ Cluster meets minimum requirements${NC}"
        if [ -n "$MISSING_COMPONENTS" ]; then
            echo -e "${YELLOW}⚠️ Missing required components: $MISSING_COMPONENTS${NC}"
        fi
        echo -e "${YELLOW}⚠️ Note: Storage requirements are checked separately for each node${NC}"
        return 0
    else
        echo -e "${RED}❌ Cluster does not meet minimum requirements${NC}"
        if [ -n "$MISSING_COMPONENTS" ]; then
            echo -e "${RED}❌ Missing required components: $MISSING_COMPONENTS${NC}"
        fi
        echo -e "${YELLOW}⚠️ Note: Check individual node storage requirements above${NC}"
        return 1
    fi
}

# Function to check node disk/ephemeral storage
check_node_storage() {
    local node="$1"
    local node_type="$2"
    local MIN_STORAGE_GB=110  # Minimum for all nodes
    local MIN_GPU_STORAGE_GB=150  # Higher minimum for GPU nodes
    local TESTS_FAILED=false

    # Function to convert to bytes
    to_bytes() {
        local value="$1"
        if [[ $value == *Ki ]]; then
            echo $(( ${value%Ki} * 1024 ))
        elif [[ $value == *Mi ]]; then
            echo $(( ${value%Mi} * 1024 * 1024 ))
        elif [[ $value == *Gi ]]; then
            echo $(( ${value%Gi} * 1024 * 1024 * 1024 ))
        else
            echo "$value"
        fi
    }

    # Function to convert bytes to GB
    to_gb() { 
        echo "$(( $1 / 1024 / 1024 / 1024 ))"
    }

    # Check if this is a GPU node
    local gpu_count
    gpu_count=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null)
    local is_gpu_node=false
    if [ -n "$gpu_count" ] && [ "$gpu_count" != "0" ]; then
        is_gpu_node=true
    fi

    # Get ephemeral storage capacity and allocatable
    local capacity
    local allocatable
    capacity=$(kubectl get node "$node" -o jsonpath="{.status.capacity['ephemeral-storage']}" 2>/dev/null)
    allocatable=$(kubectl get node "$node" -o jsonpath="{.status.allocatable['ephemeral-storage']}" 2>/dev/null)

    if [ -z "$capacity" ] || [ -z "$allocatable" ]; then
        echo "└─ Storage: warning Could not retrieve storage information"
        return 1
    fi

    # Convert to bytes and calculate usage
    local cap_bytes=$(to_bytes "$capacity")
    local alloc_bytes=$(to_bytes "$allocatable")
    local used_bytes=$((cap_bytes - alloc_bytes))
    local used_pct=$((used_bytes * 100 / cap_bytes))
    local cap_gb=$(to_gb $cap_bytes)
    local alloc_gb=$(to_gb $alloc_bytes)
    local used_gb=$(to_gb $used_bytes)

    # Determine minimum requirement based on node type
    local min_required_gb=$MIN_STORAGE_GB
    if [ "$is_gpu_node" = true ]; then
        min_required_gb=$MIN_GPU_STORAGE_GB
    fi

    # Always show storage information
    if [ "$cap_bytes" -lt $((min_required_gb * 1024 * 1024 * 1024)) ]; then
        echo "└─ Storage: warning Insufficient storage: ${cap_gb}GB < ${min_required_gb}GB minimum"
        TESTS_FAILED=true
    else
        echo "└─ Storage: ${cap_gb}GB available (minimum: ${min_required_gb}GB)"
    fi
    
    # Show usage information
    if [ "$used_pct" -ge 85 ]; then
        echo "└─ Usage: warning High disk usage (${used_pct}%) - close to pressure!"
        TESTS_FAILED=true
    elif [ "$used_pct" -ge 75 ]; then
        echo "└─ Usage: warning Moderate disk usage (${used_pct}%)"
    else
        echo "└─ Usage: ${used_pct}% used"
    fi
    
    # Check disk pressure
    local disk_pressure
    disk_pressure=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null)
    if [ "$disk_pressure" = "True" ]; then
        echo "└─ Status: warning Node is under disk pressure - pods may be evicted"
        TESTS_FAILED=true
    fi

    if [ "$TESTS_FAILED" = true ]; then
        return 1
    fi
    return 0
} 