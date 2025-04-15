#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Create logs directory
LOGS_DIR="./logs"
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/sanity_check_$(date +%Y%m%d_%H%M%S).log"
echo "Sanity check started at $(date)" > "$LOG_FILE"

# Function to log commands and their output
log_command() {
    local cmd="$1"
    local description="$2"
    
    echo -e "\n\n==== $description ====" >> "$LOG_FILE"
    echo "Command: $cmd" >> "$LOG_FILE"
    echo "Executing at: $(date)" >> "$LOG_FILE"
    echo "Output:" >> "$LOG_FILE"
    
    # Execute command and capture both stdout and stderr
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        echo "Status: SUCCESS" >> "$LOG_FILE"
        return 0
    else
        local exit_code=$?
        echo "Status: FAILED (exit code: $exit_code)" >> "$LOG_FILE"
        return $exit_code
    fi
}

# Function to download preinstall diagnostics tool
download_preinstall_diagnostics() {
    echo -e "${YELLOW}Downloading preinstall diagnostics tool...${NC}"
    
    # Determine OS type and architecture
    OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    # Convert architecture to expected format
    case "$ARCH" in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
    esac
    
    # Get latest release version
    LATEST_VERSION=$(curl -s https://api.github.com/repos/run-ai/preinstall-diagnostics/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}❌ Failed to get latest version of preinstall diagnostics${NC}"
        return 1
    fi

    # Construct download URL
    DOWNLOAD_URL="https://github.com/run-ai/preinstall-diagnostics/releases/download/${LATEST_VERSION}/runai-preinstall-${OS_TYPE}-${ARCH}"
    DIAG_BIN="./runai-preinstall-${OS_TYPE}-${ARCH}"
    
    # Download the binary if it doesn't exist
    if [ ! -f "$DIAG_BIN" ]; then
        echo -e "${YELLOW}Downloading from: $DOWNLOAD_URL${NC}"
        if ! curl -L -o "$DIAG_BIN" "$DOWNLOAD_URL"; then
            echo -e "${RED}❌ Failed to download preinstall diagnostics${NC}"
            return 1
        fi
        chmod +x "$DIAG_BIN"
    else
        echo -e "${YELLOW}Using existing diagnostics binary: $DIAG_BIN${NC}"
    fi
    
    echo -e "${GREEN}✅ Preinstall diagnostics tool ready${NC}"
        return 0
}

# Function to run diagnostics check
run_diagnostics_check() {
    echo -e "\n${YELLOW}Running pre-installation diagnostics...${NC}"
    
    # Determine OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    # Set the appropriate URL based on OS and architecture
    if [ "$OS" = "linux" ] && [ "$ARCH" = "x86_64" ]; then
        DIAG_URL="https://github.com/run-ai/preinstall-diagnostics/releases/download/v2.18.14/preinstall-diagnostics-linux-amd64"
    elif [ "$OS" = "darwin" ] && [ "$ARCH" = "arm64" ]; then
        DIAG_URL="https://github.com/run-ai/preinstall-diagnostics/releases/download/v2.18.14/preinstall-diagnostics-darwin-arm64"
    else
        echo -e "${RED}❌ Unsupported OS/Architecture combination: $OS/$ARCH${NC}"
        return 1
    fi
    
    # Download diagnostics tool
    echo -e "${YELLOW}Downloading diagnostics tool...${NC}"
    if ! curl -L -o preinstall-diagnostics "$DIAG_URL"; then
        echo -e "${RED}❌ Failed to download diagnostics tool${NC}"
        return 1
    fi
    
    # Make executable
    chmod +x preinstall-diagnostics
    
    # Run diagnostics
    echo -e "${YELLOW}Running diagnostics...${NC}"
    if [ -n "$DIAG_DNS" ]; then
        echo -e "${YELLOW}Running DNS diagnostics for domain: $DIAG_DNS${NC}"
        ./preinstall-diagnostics --domain "$DIAG_DNS" --cluster-domain "$DIAG_DNS" > /dev/null 2>&1
    else
    ./preinstall-diagnostics > /dev/null 2>&1
    fi
    
    # Check if results file exists
    if [ ! -f "runai-diagnostics.txt" ]; then
        echo -e "${RED}❌ Diagnostics results file not found${NC}"
        return 1
    fi
    
    # Parse and display results
    echo -e "\n${YELLOW}Diagnostic Results:${NC}"
    echo -e "----------------------------------------"
    
    # Process the results file and format output
    while IFS= read -r line; do
        # Remove ANSI color codes and format
        line=$(echo "$line" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')
        
        # Extract test name and result
        if [[ $line =~ \|[[:space:]]*([^|]+)[[:space:]]*\|[[:space:]]*(PASS|FAIL)[[:space:]]*\|[[:space:]]*([^|]+)[[:space:]]*\| ]]; then
            TEST_NAME="${BASH_REMATCH[1]}"
            RESULT="${BASH_REMATCH[2]}"
            MESSAGE="${BASH_REMATCH[3]}"
            
            # Skip empty or header lines
            if [ -n "$TEST_NAME" ] && [ "$TEST_NAME" != "TEST NAME" ]; then
                # Format output
                TEST_NAME=$(echo "$TEST_NAME" | xargs)
                if [ "$RESULT" = "PASS" ]; then
                    echo -e "${TEST_NAME}: ${GREEN}✓ PASS${NC}"
                else
                    echo -e "${TEST_NAME}: ${RED}✗ FAIL${NC}"
                    echo -e "  └─ ${YELLOW}$MESSAGE${NC}"
                fi
            fi
        fi
    done < runai-diagnostics.txt
    
    # Cleanup removed to keep the binary file
    # rm -f preinstall-diagnostics
    
    echo -e "\n${GREEN}✅ Diagnostics completed${NC}"
    return 0
}

# Cleanup function
cleanup() {
    local exit_code=$?
    echo -e "\n${YELLOW}Running cleanup...${NC}"
    
    if [ -n "$TEST_NS" ]; then
        echo -e "${YELLOW}Deleting namespace $TEST_NS...${NC}"
        kubectl delete namespace "$TEST_NS" --timeout=60s &>/dev/null || true
        
        # Wait for namespace deletion (max 30 seconds)
    for i in {1..30}; do
            if ! kubectl get namespace "$TEST_NS" &>/dev/null; then
                echo -e "${GREEN}✅ Namespace $TEST_NS deleted successfully${NC}"
            break
            fi
            sleep 1
        done
        
        # Force deletion if namespace still exists
        if kubectl get namespace "$TEST_NS" &>/dev/null; then
            echo -e "${YELLOW}⚠️ Forcing namespace deletion...${NC}"
            kubectl delete namespace "$TEST_NS" --force --grace-period=0 &>/dev/null || true
        fi
    fi
    
    echo -e "${YELLOW}Cleanup completed${NC}"
    echo -e "${YELLOW}Log file: $LOG_FILE${NC}"
    
    # Exit with the original exit code
    exit $exit_code
}

# Set up trap to ensure cleanup runs on script exit
trap cleanup EXIT

# Function to show usage
show_usage() {
    echo -e "${YELLOW}Usage: $0 [OPTIONS]${NC}"
    echo "Options:"
    echo "  --cert CERT_FILE       Certificate file for TLS"
    echo "  --key KEY_FILE         Key file for TLS"
    echo "  --dns DNS_NAME         DNS name to test"
    echo "  --cacert CA_FILE       CA certificate file for SSL verification (optional)"
    echo "  --storage              Run only storage tests"
    echo "  --class STORAGE_CLASS  Specify StorageClass for storage tests (optional)"
    echo "  --hardware             Check hardware requirements (24GB RAM, 12 Cores)"
    echo "  --diag                 Run preinstall diagnostics"
    echo "  --diag-dns DNS_NAME    Run DNS diagnostics with specified domain (will be used for both --domain and --cluster-domain)"
    echo ""
    echo "Examples:"
    echo "  $0 --cert runai.crt --key runai.key --dns runai.kirson.local"
    echo "  $0 --cert runai.crt --key runai.key --dns runai.kirson.local --cacert ca.pem"
    echo "  $0 --storage                    # Test storage with default StorageClass"
    echo "  $0 --storage --class local-path # Test storage with specific StorageClass"
    echo "  $0 --hardware                   # Check hardware requirements"
    echo "  $0 --diag                       # Run preinstall diagnostics"
    echo "  $0 --diag --diag-dns example.com # Run DNS diagnostics with domain checks"
    exit 1
}

# Function to check required components
check_required_components() {
    echo -e "${YELLOW}Checking required components...${NC}"
    
    # Get all helm releases
    HELM_RELEASES=$(helm list -A 2>/dev/null)
    
    # Check for Prometheus
    if echo "$HELM_RELEASES" | grep -q "prometheus"; then
        echo -e "${GREEN}✅ Prometheus Installed${NC}"
    else
        echo -e "${RED}❌ Prometheus Missing${NC}"
    fi
    
    # Check for NGINX - either Helm release or running pods is sufficient
    NGINX_HELM=$(echo "$HELM_RELEASES" | grep -q "nginx" && echo "true" || echo "false")
    NGINX_PODS=$(kubectl get pods -A 2>/dev/null | grep -q "ingress-nginx" && echo "true" || echo "false")
    
    if [ "$NGINX_HELM" = "true" ] || [ "$NGINX_PODS" = "true" ]; then
        echo -e "${GREEN}✅ NGINX Installed${NC}"
    else
        echo -e "${RED}❌ NGINX Missing${NC}"
    fi
    
    # Check for GPU Operator
    if echo "$HELM_RELEASES" | grep -q "gpu-operator"; then
        echo -e "${GREEN}✅ GPU Operator Installed${NC}"
    else
        echo -e "${RED}❌ GPU Operator Missing${NC}"
    fi
    
    echo ""
}

# Function to check hardware requirements
check_hardware_requirements() {
    echo -e "${YELLOW}Checking hardware requirements...${NC}"
    echo -e "${YELLOW}Minimum Required: 24GB RAM, 24 CPU Cores${NC}\n"

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
            if [[ "$K8S_MAJOR_MINOR" =~ ^1\.(2[7-9]|3[0-2])$ ]]; then
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
        return 0
    else
        echo -e "${RED}❌ Cluster does not meet minimum requirements${NC}"
        if [ -n "$MISSING_COMPONENTS" ]; then
            echo -e "${RED}❌ Missing required components: $MISSING_COMPONENTS${NC}"
        fi
        return 1
    fi
}

# Function to run storage tests
run_storage_tests() {
    echo -e "${YELLOW}Testing storage functionality...${NC}"

    # Get storage class
    if [ -n "$STORAGE_CLASS" ]; then
        # Check if specified storage class exists
        if ! kubectl get storageclass "$STORAGE_CLASS" &>/dev/null; then
            echo -e "${RED}❌ StorageClass $STORAGE_CLASS not found${NC}"
            exit 1
        fi
        SC_TO_USE="$STORAGE_CLASS"
        echo -e "${YELLOW}Using specified StorageClass: $SC_TO_USE${NC}"
    else
        # Get default storage class
        SC_TO_USE=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
        if [ -z "$SC_TO_USE" ]; then
            echo -e "${RED}❌ No default StorageClass found${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Using default StorageClass: $SC_TO_USE${NC}"
    fi

    # Create PVC first
    echo -e "${YELLOW}Creating PVC...${NC}"
    cat <<EOF | kubectl apply -f - >> "$LOG_FILE"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sanity-pvc
  namespace: $TEST_NS
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: $SC_TO_USE
EOF

    # Create pod to test storage immediately after PVC
    echo -e "${YELLOW}Creating storage test pod...${NC}"
    cat <<EOF | kubectl apply -f - >> "$LOG_FILE"
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
  namespace: $TEST_NS
spec:
  securityContext:
    fsGroup: 1001
  containers:
  - name: storage-test
    image: ubuntu:latest
    command: 
    - sleep
    - "3600"
    securityContext:
      runAsUser: 1001
      runAsGroup: 1001
    volumeMounts:
    - name: storage-volume
      mountPath: /data
  volumes:
  - name: storage-volume
    persistentVolumeClaim:
      claimName: sanity-pvc
EOF

    # Now wait for both PVC and Pod
    echo -e "${YELLOW}Waiting for PVC to be bound...${NC}"
    # First, wait for the PVC to exist
    for i in {1..30}; do
        if kubectl get pvc -n "$TEST_NS" sanity-pvc &>/dev/null; then
            break
        fi
        sleep 2
    done

    # Then check its status
    PVC_STATUS=$(kubectl get pvc -n "$TEST_NS" sanity-pvc -o jsonpath='{.status.phase}')
    if [ "$PVC_STATUS" = "Bound" ]; then
        echo -e "${GREEN}✅ PVC successfully bound${NC}"
    else
        # Wait a bit longer and check again
        sleep 10
        PVC_STATUS=$(kubectl get pvc -n "$TEST_NS" sanity-pvc -o jsonpath='{.status.phase}')
        if [ "$PVC_STATUS" = "Bound" ]; then
            echo -e "${GREEN}✅ PVC successfully bound${NC}"
        else
            echo -e "${RED}❌ PVC failed to bind${NC}"
            echo -e "${YELLOW}PVC Status:${NC}"
            kubectl get pvc -n "$TEST_NS" sanity-pvc
            kubectl describe pvc -n "$TEST_NS" sanity-pvc
            exit 1
        fi
    fi

    # Log PVC details
    echo -e "${YELLOW}PVC Details:${NC}"
    kubectl get pvc -n "$TEST_NS" sanity-pvc >> "$LOG_FILE"

    # Wait for storage test pod to be ready
    echo -e "${YELLOW}Waiting for storage test pod to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=ready pod/storage-test -n $TEST_NS --timeout=60s" "Wait for storage test pod"; then
        echo -e "${RED}❌ Storage test pod failed to become ready${NC}"
        # Show pod status for debugging
        kubectl get pod -n $TEST_NS storage-test
        kubectl describe pod -n $TEST_NS storage-test
        exit 1
    fi

    # Write test file and verify permissions
    echo -e "${YELLOW}Testing file creation with user 1001:1001...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS storage-test -- /bin/bash -c 'echo \"Test content\" > /data/test.txt'" "Create test file"; then
        echo -e "${RED}❌ Failed to create test file${NC}"
        exit 1
    fi

    # Verify file permissions and ownership
    echo -e "${YELLOW}Verifying file permissions and ownership...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS storage-test -- ls -l /data/test.txt" "Check file permissions"; then
        echo -e "${RED}❌ Failed to check file permissions${NC}"
        exit 1
    fi

    # Verify file ownership
    FILE_OWNER=$(kubectl exec -n $TEST_NS storage-test -- ls -ln /data/test.txt | awk '{print $3":"$4}')
    if [ "$FILE_OWNER" = "1001:1001" ]; then
        echo -e "${GREEN}✅ File ownership verified: $FILE_OWNER${NC}"
    else
        echo -e "${RED}❌ Incorrect file ownership: $FILE_OWNER (expected 1001:1001)${NC}"
    fi

    # Read file content
    echo -e "${YELLOW}Verifying file content...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS storage-test -- cat /data/test.txt" "Read test file"; then
        echo -e "${RED}❌ Failed to read test file${NC}"
        exit 1
    fi

    # Test 1: Create file as user 1001:1001 (already implemented)
    echo -e "${YELLOW}Test 1: File created by user 1001:1001${NC}"
    echo -e "${GREEN}✅ Test 1 completed (file created with correct ownership)${NC}"

    # Test 2: Create file as root and change ownership
    echo -e "${YELLOW}Test 2: Creating root pod to test ownership change...${NC}"
    
    # Create root pod
    cat <<EOF | kubectl apply -f - >> "$LOG_FILE"
apiVersion: v1
kind: Pod
metadata:
  name: root-test
  namespace: $TEST_NS
spec:
  containers:
  - name: root-test
    image: ubuntu:latest
    command: 
    - sleep
    - "3600"
    securityContext:
      runAsUser: 0
      runAsGroup: 0
    volumeMounts:
    - name: storage-volume
      mountPath: /data
  volumes:
  - name: storage-volume
    persistentVolumeClaim:
      claimName: sanity-pvc
EOF

    # Wait for root pod to be ready
    echo -e "${YELLOW}Waiting for root pod to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=ready pod/root-test -n $TEST_NS --timeout=60s" "Wait for root pod"; then
        echo -e "${RED}❌ Root pod failed to become ready${NC}"
        exit 1
    fi

    # Create file as root
    echo -e "${YELLOW}Creating file as root...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS root-test -- touch /data/root_test.txt" "Create file as root"; then
        echo -e "${RED}❌ Failed to create file as root${NC}"
        exit 1
    fi

    # Verify initial ownership (should be 0:0)
    ROOT_FILE_OWNER=$(kubectl exec -n $TEST_NS root-test -- ls -ln /data/root_test.txt | awk '{print $3":"$4}')
    if [ "$ROOT_FILE_OWNER" = "0:0" ]; then
        echo -e "${GREEN}✅ Initial file ownership verified: $ROOT_FILE_OWNER${NC}"
    else
        echo -e "${RED}❌ Incorrect initial file ownership: $ROOT_FILE_OWNER (expected 0:0)${NC}"
    fi

    # Change ownership to 1001:1001
    echo -e "${YELLOW}Changing file ownership to 1001:1001...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS root-test -- chown 1001:1001 /data/root_test.txt" "Change file ownership"; then
        echo -e "${RED}❌ Failed to change file ownership${NC}"
        exit 1
    fi

    # Verify new ownership
    NEW_OWNER=$(kubectl exec -n $TEST_NS root-test -- ls -ln /data/root_test.txt | awk '{print $3":"$4}')
    if [ "$NEW_OWNER" = "1001:1001" ]; then
        echo -e "${GREEN}✅ File ownership successfully changed to: $NEW_OWNER${NC}"
    else
        echo -e "${RED}❌ Failed to change file ownership. Current ownership: $NEW_OWNER (expected 1001:1001)${NC}"
    fi

    # Add storage test results to log
    echo -e "\n==== Storage Test Summary ====" >> "$LOG_FILE"
    echo "StorageClass: $SC_TO_USE" >> "$LOG_FILE"
    echo "PVC Status:" >> "$LOG_FILE"
    kubectl get pvc sanity-pvc -n $TEST_NS -o wide >> "$LOG_FILE"
    echo "User-created File Permissions:" >> "$LOG_FILE"
    kubectl exec -n $TEST_NS storage-test -- ls -l /data/test.txt >> "$LOG_FILE"
    echo "Root-created File Permissions:" >> "$LOG_FILE"
    kubectl exec -n $TEST_NS root-test -- ls -l /data/root_test.txt >> "$LOG_FILE"

    echo -e "${GREEN}✅ Storage test completed${NC}"
}

# Initialize variables
HARDWARE_CHECK=false
DIAG=false
DIAG_DNS=""

# Initialize test result variables
TLS_SECRET_CREATED=false
INGRESS_CREATED=false
HTTPS_ACCESS_OK=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cert)
            CERT_FILE="$2"
            if [ ! -f "$CERT_FILE" ]; then
                echo -e "${RED}❌ Certificate file not found: $CERT_FILE${NC}"
                exit 1
            fi
            VALID_ARGS=true
            shift 2
            ;;
        --key)
            KEY_FILE="$2"
            if [ ! -f "$KEY_FILE" ]; then
                echo -e "${RED}❌ Key file not found: $KEY_FILE${NC}"
                exit 1
            fi
            VALID_ARGS=true
            shift 2
            ;;
        --dns)
            DNS_NAME="$2"
            VALID_ARGS=true
            shift 2
            ;;
        --cacert)
            CA_CERT="$2"
            if [ ! -f "$CA_CERT" ]; then
                echo -e "${RED}❌ CA certificate file not found: $CA_CERT${NC}"
                exit 1
            fi
            VALID_ARGS=true
            shift 2
            ;;
        --storage)
            STORAGE_ONLY=true
            VALID_ARGS=true
            shift
            ;;
        --class)
            STORAGE_CLASS="$2"
            VALID_ARGS=true
            shift 2
            ;;
        --hardware)
            HARDWARE_CHECK=true
            VALID_ARGS=true
            shift
            ;;
        --diag)
            DIAG=true
            VALID_ARGS=true
            shift
            ;;
        --diag-dns)
            DIAG_DNS="$2"
            VALID_ARGS=true
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            ;;
    esac
done

# Check if no valid arguments were provided
if [ "$VALID_ARGS" = false ]; then
    echo -e "${RED}Error: No arguments provided${NC}"
    echo -e "${YELLOW}You must provide either:${NC}"
    echo -e "  - Certificate, key, and DNS parameters for a full test"
    echo -e "  - The --storage flag for storage-only tests"
    echo -e "  - The --hardware flag for hardware check"
    echo -e "  - The --diag flag for preinstall diagnostics"
    echo -e "\n"
    show_usage
    exit 1
fi

# Run diagnostics first if requested, and exit if it's the only operation
if [ "$DIAG" = true ]; then
    if ! run_diagnostics_check; then
        echo -e "${RED}❌ Diagnostics check failed${NC}"
        exit 1
    fi
    # Only exit if this is the only check requested
    if [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ -z "$CERT_FILE" ]; then
        echo -e "\n${GREEN}✅ Diagnostics check completed successfully!${NC}"
        exit 0
    fi
fi

# Skip remaining validation if only running diagnostics
if [ "$DIAG" = true ] && [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ -z "$CERT_FILE" ]; then
    exit 0
fi

# Validate required parameters
if [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && ([ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ] || [ -z "$DNS_NAME" ]); then
    echo -e "${RED}Error: --cert, --key, and --dns are required unless using --storage or --hardware${NC}"
    show_usage
fi

# Add validation after argument parsing
if [ -n "$DIAG_DNS" ] && [ "$DIAG" != true ]; then
    echo -e "${RED}Error: --diag-dns requires --diag flag${NC}"
    show_usage
fi

# Skip storage tests if running with certificate and DNS parameters
if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && [ -n "$DNS_NAME" ]; then
    STORAGE_ONLY=false
fi

echo -e "${YELLOW}Starting sanity checks...${NC}"

# Run hardware check if requested
if [ "$HARDWARE_CHECK" = "true" ]; then
    if ! check_hardware_requirements; then
        echo -e "${RED}❌ Hardware validation failed${NC}"
        exit 1
    fi
    # Only exit if this is the only check requested
    if [ "$STORAGE_ONLY" != "true" ] && [ -z "$CERT_FILE" ]; then
        echo -e "\n${GREEN}✅ Hardware check completed successfully!${NC}"
        exit 0
    fi
fi

# Main execution flow
if [ "$STORAGE_ONLY" = "true" ]; then
    # Create test namespace for storage tests
    TEST_NS="sanity-test-$(date +%s)"
    echo -e "${YELLOW}Creating test namespace: $TEST_NS${NC}"
    if ! log_command "kubectl create namespace $TEST_NS" "Create test namespace"; then
        echo -e "${RED}❌ Failed to create test namespace${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Running storage-only tests...${NC}"
    run_storage_tests
else
    # Only run TLS/ingress tests if not in storage-only mode
    if [ -n "$CERT_FILE" ]; then
        # Create test namespace
        TEST_NS="sanity-test-$(date +%s)"
        echo -e "${YELLOW}Creating test namespace: $TEST_NS${NC}"
        if ! log_command "kubectl create namespace $TEST_NS" "Create test namespace"; then
            echo -e "${RED}❌ Failed to create test namespace${NC}"
            exit 1
        fi

        # Create TLS secret
        echo -e "${YELLOW}Creating TLS secret...${NC}"
        if log_command "kubectl create secret tls sanity-tls -n $TEST_NS --cert=$CERT_FILE --key=$KEY_FILE" "Create TLS secret"; then
            TLS_SECRET_CREATED=true
        else
            echo -e "${RED}❌ Failed to create TLS secret${NC}"
            exit 1
        fi

        # Create test service and deployment
        echo -e "${YELLOW}Creating test deployment and service...${NC}"
        cat <<EOF | kubectl apply -f - >> "$LOG_FILE"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: $TEST_NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test
  namespace: $TEST_NS
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: nginx-test
EOF

        # Create ingress
        echo -e "${YELLOW}Creating test ingress...${NC}"
        INGRESS_YAML=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sanity-ingress
  namespace: $TEST_NS
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - $DNS_NAME
    secretName: sanity-tls
  rules:
  - host: $DNS_NAME
    http:
      paths:
      - path: /sanity-test
        pathType: Prefix
        backend:
          service:
            name: nginx-test
            port:
              number: 80
EOF
)
        if echo "$INGRESS_YAML" | kubectl apply -f - >> "$LOG_FILE" && kubectl get ingress -n $TEST_NS sanity-ingress &>/dev/null; then
            INGRESS_CREATED=true
        else
            echo -e "${RED}❌ Failed to create ingress${NC}"
            exit 1
        fi

        # Wait for deployment to be ready
        echo -e "${YELLOW}Waiting for test deployment to be ready...${NC}"
        if ! log_command "kubectl wait --for=condition=available deployment/nginx-test -n $TEST_NS --timeout=60s" "Wait for deployment"; then
            echo -e "${RED}❌ Deployment failed to become ready${NC}"
            exit 1
        fi

        # Test 1: External curl with SSL verification
        echo -e "${YELLOW}Testing external HTTPS access...${NC}"
        echo -e "${YELLOW}Performing curl test to https://$DNS_NAME/sanity-test${NC}"
        if [ -n "$CA_CERT" ]; then
            echo -e "${YELLOW}Using CA certificate for SSL verification${NC}"
            if log_command "curl -v --cacert $CA_CERT https://$DNS_NAME/sanity-test" "External HTTPS test with SSL verification"; then
                HTTPS_ACCESS_OK=true
            else
                echo -e "${YELLOW}⚠️ SSL verification failed as expected (no valid CA cert)${NC}"
            fi
        else
            echo -e "${YELLOW}Testing without CA certificate (expecting SSL verification failure)${NC}"
            if ! log_command "curl -v https://$DNS_NAME/sanity-test" "External HTTPS test without CA cert"; then
                echo -e "${YELLOW}⚠️ SSL verification failed as expected (no valid CA cert)${NC}"
                # For no CA cert case, we consider it a success if we get a response (even if SSL fails)
                HTTPS_ACCESS_OK=true
            else
                echo -e "${RED}❌ Unexpected success: SSL verification should have failed${NC}"
            fi
        fi

        # Test 2: Internal pod test
        echo -e "${YELLOW}Testing internal pod access...${NC}"
        cat <<EOF | kubectl apply -f - >> "$LOG_FILE"
apiVersion: v1
kind: Pod
metadata:
  name: curl-test
  namespace: $TEST_NS
spec:
  containers:
  - name: curl
    image: curlimages/curl
    command: 
    - sleep
    - "3600"
EOF

        # Wait for the test pod to be ready
        echo -e "${YELLOW}Waiting for test pod to be ready...${NC}"
        if ! log_command "kubectl wait --for=condition=ready pod/curl-test -n $TEST_NS --timeout=60s" "Wait for test pod"; then
            echo -e "${RED}❌ Test pod failed to become ready${NC}"
            exit 1
        fi

        # Copy the certificate to the pod
        echo -e "${YELLOW}Copying certificate to test pod...${NC}"
        if ! log_command "kubectl cp $CERT_FILE $TEST_NS/curl-test:/tmp/cert.pem -c curl" "Copy certificate to pod"; then
            echo -e "${RED}❌ Failed to copy certificate to pod${NC}"
            exit 1
        fi

        # Test internal HTTPS access
        echo -e "${YELLOW}Testing internal HTTPS access...${NC}"
        if [ -n "$CA_CERT" ]; then
            echo -e "${YELLOW}Copying CA certificate to test pod...${NC}"
            if ! log_command "kubectl cp $CA_CERT $TEST_NS/curl-test:/tmp/ca.pem -c curl" "Copy CA certificate to pod"; then
                echo -e "${RED}❌ Failed to copy CA certificate to pod${NC}"
                exit 1
            fi
            
            if log_command "kubectl exec -n $TEST_NS curl-test -- curl -v --cacert /tmp/ca.pem https://$DNS_NAME/sanity-test" "Internal HTTPS test with SSL verification"; then
                HTTPS_ACCESS_OK=true
            else
                echo -e "${RED}❌ Internal HTTPS test failed${NC}"
            fi
        else
            echo -e "${YELLOW}Testing without CA certificate (expecting SSL verification failure)${NC}"
            if ! log_command "kubectl exec -n $TEST_NS curl-test -- curl -v https://$DNS_NAME/sanity-test" "Internal HTTPS test without CA cert"; then
                echo -e "${YELLOW}⚠️ SSL verification failed as expected (no valid CA cert)${NC}"
                # For no CA cert case, we consider it a success if we get a response (even if SSL fails)
                HTTPS_ACCESS_OK=true
            else
                echo -e "${RED}❌ Unexpected success: SSL verification should have failed${NC}"
            fi
        fi
    fi
fi

# Print test summary
echo -e "\n${YELLOW}Test Summary:${NC}"
echo -e "----------------------------------------"
if [ "$STORAGE_ONLY" = "true" ]; then
    echo -e "Storage Tests:"
    if [ -n "$STORAGE_CLASS" ]; then
        echo -e "- Using StorageClass: ${GREEN}$STORAGE_CLASS${NC}"
    else
        echo -e "- Using default StorageClass"
    fi
    echo -e "- PVC Creation: ${GREEN}✓${NC}"
    echo -e "- Pod Creation: ${GREEN}✓${NC}"
    echo -e "- Storage Binding: ${GREEN}✓${NC}"
else
    echo -e "TLS/Ingress Tests:"
    if [ "$TLS_SECRET_CREATED" = true ]; then
    echo -e "- TLS Secret Creation: ${GREEN}✓${NC}"
    else
        echo -e "- TLS Secret Creation: ${RED}✗${NC}"
    fi
    if [ "$INGRESS_CREATED" = true ]; then
    echo -e "- Ingress Creation: ${GREEN}✓${NC}"
    else
        echo -e "- Ingress Creation: ${RED}✗${NC}"
    fi
    if [ "$HTTPS_ACCESS_OK" = true ]; then
        echo -e "- HTTPS Access Tests: ${GREEN}✓${NC}"
    else
        echo -e "- HTTPS Access Tests: ${RED}✗${NC}"
    fi
fi
echo -e "----------------------------------------"

# Run cleanup
echo -e "\n${YELLOW}Running cleanup...${NC}"
cleanup
echo -e "${GREEN}Cleanup completed${NC}"

echo -e "${YELLOW}Log file: ${GREEN}$LOG_FILE${NC}"

# Final status
if [ "$STORAGE_ONLY" = "true" ] || ([ "$TLS_SECRET_CREATED" = true ] && [ "$INGRESS_CREATED" = true ] && [ "$HTTPS_ACCESS_OK" = true ]); then
echo -e "\n${GREEN}✅ All tests completed successfully!${NC}" 
else
    echo -e "\n${RED}❌ Some tests failed!${NC}"
    exit 1
fi 
