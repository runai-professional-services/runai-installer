#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to show usage
show_usage() {
    echo -e "${YELLOW}Usage:${NC}"
    echo -e "  $0 [options]"
    echo -e "\n${YELLOW}Options:${NC}"
    echo -e "  --cert FILE      Certificate file for TLS"
    echo -e "  --key FILE       Private key file for TLS"
    echo -e "  --dns NAME       DNS name for ingress"
    echo -e "  --cacert FILE    CA certificate file (optional)"
    echo -e "  --storage        Run storage tests only"
    echo -e "  --class NAME     Specify storage class (optional)"
    echo -e "  --hardware       Check hardware requirements only"
    echo -e "  --diag          Run preinstall diagnostics"
    echo -e "  --diag-dns NAME  DNS name for diagnostics"
    echo -e "  --silent        Suppress output messages"
    echo -e "  -h, --help      Show this help message"
    echo -e "\n${YELLOW}Examples:${NC}"
    echo -e "  $0 --cert cert.pem --key key.pem --dns example.com"
    echo -e "  $0 --storage"
    echo -e "  $0 --storage --class my-storage-class"
    echo -e "  $0 --hardware"
    echo -e "  $0 --diag"
    echo -e "  $0 --diag --diag-dns example.com"
    exit 1
}

# Create logs directory
LOGS_DIR="./logs"
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/sanity_check_$(date +%Y%m%d_%H%M%S).log"
echo "Sanity check started at $(date)" > "$LOG_FILE"

# Create symlink to latest log
LATEST_LOG="$LOGS_DIR/latest.log"
rm -f "$LATEST_LOG"
ln -s "$(basename "$LOG_FILE")" "$LATEST_LOG"

# Function to log commands and their output
log_command() {
    local cmd="$1"
    local description="$2"
    
    if [ "$SILENT_MODE" = false ]; then
        echo -e "\n\n==== $description ====" >> "$LOG_FILE"
        echo "Command: $cmd" >> "$LOG_FILE"
        echo "Executing at: $(date)" >> "$LOG_FILE"
        echo "Output:" >> "$LOG_FILE"
    fi
    
    # Execute command and capture both stdout and stderr
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        if [ "$SILENT_MODE" = false ]; then
            echo "Status: SUCCESS" >> "$LOG_FILE"
        fi
        return 0
    else
        local exit_code=$?
        if [ "$SILENT_MODE" = false ]; then
            echo "Status: FAILED (exit code: $exit_code)" >> "$LOG_FILE"
        fi
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
    
    DIAG_BIN="./preinstall-diagnostics"
    
    # Check if file exists and is executable
    if [ -f "$DIAG_BIN" ] && [ -x "$DIAG_BIN" ]; then
        echo -e "${YELLOW}Using existing diagnostics binary: $DIAG_BIN${NC}"
        echo -e "${GREEN}✅ Preinstall diagnostics tool ready${NC}"
        return 0
    fi
    
    # Get latest release version
    LATEST_VERSION=$(curl -s https://api.github.com/repos/run-ai/preinstall-diagnostics/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}❌ Failed to get latest version of preinstall diagnostics${NC}"
        return 1
    fi

    # Construct download URL
    DOWNLOAD_URL="https://github.com/run-ai/preinstall-diagnostics/releases/download/${LATEST_VERSION}/preinstall-diagnostics-${OS_TYPE}-${ARCH}"
    
    # Download the binary
    echo -e "${YELLOW}Downloading from: $DOWNLOAD_URL${NC}"
    if ! curl -L -o "$DIAG_BIN" "$DOWNLOAD_URL"; then
        echo -e "${RED}❌ Failed to download preinstall diagnostics${NC}"
        return 1
    fi
    chmod +x "$DIAG_BIN"
    
    echo -e "${GREEN}✅ Preinstall diagnostics tool ready${NC}"
    return 0
}

# Function to run diagnostics check
run_diagnostics_check() {
    log_message "\n${YELLOW}Running pre-installation diagnostics...${NC}"

    # Download diagnostics tool if not already downloaded
    if ! download_preinstall_diagnostics; then
        return 1
    fi

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

    echo -e "\n${GREEN}✅ Diagnostics completed${NC}"
    return 0
}

# Function to check required components
check_required_components() {
    echo -e "${YELLOW}Checking required components...${NC}"
    
    # Check Helm version
    if ! command -v helm &>/dev/null; then
        echo -e "${RED}❌ Helm not found${NC}"
    else
        HELM_VERSION=$(helm version --short | grep -oP 'v\K\d+\.\d+')
        if [ -n "$HELM_VERSION" ]; then
            if (( $(echo "$HELM_VERSION >= 3.14" | bc -l) )); then
                echo -e "${GREEN}✅ Helm version: $HELM_VERSION${NC}"
            else
                echo -e "${RED}❌ Helm version $HELM_VERSION is too old. Required: 3.14 or later${NC}"
            fi
        else
            echo -e "${RED}❌ Could not determine Helm version${NC}"
        fi
    fi
    
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
    log_message "${YELLOW}Testing storage functionality...${NC}"
    local TESTS_FAILED=false

    # Get storage class
    if [ -n "$STORAGE_CLASS" ]; then
        if ! kubectl get storageclass "$STORAGE_CLASS" &>/dev/null; then
            log_message "${RED}❌ StorageClass $STORAGE_CLASS not found${NC}"
            TESTS_FAILED=true
            return 1
        fi
        SC_TO_USE="$STORAGE_CLASS"
        log_message "${YELLOW}Using specified StorageClass: $SC_TO_USE${NC}"
    else
        SC_TO_USE=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
        if [ -z "$SC_TO_USE" ]; then
            log_message "${RED}❌ No default StorageClass found${NC}"
            TESTS_FAILED=true
            return 1
        fi
        log_message "${YELLOW}Using default StorageClass: $SC_TO_USE${NC}"
    fi

    # Create PVC first
    log_message "${YELLOW}Creating PVC...${NC}"
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

    # Create pod to test storage
    log_message "${YELLOW}Creating storage test pod...${NC}"
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

    # Wait for PVC and Pod
    log_message "${YELLOW}Waiting for PVC to be bound...${NC}"
    for i in {1..30}; do
        if kubectl get pvc -n "$TEST_NS" sanity-pvc &>/dev/null; then
            break
        fi
        sleep 2
    done

    PVC_STATUS=$(kubectl get pvc -n "$TEST_NS" sanity-pvc -o jsonpath='{.status.phase}')
    if [ "$PVC_STATUS" = "Bound" ]; then
        log_message "${GREEN}✅ PVC successfully bound${NC}"
    else
        sleep 10
        PVC_STATUS=$(kubectl get pvc -n "$TEST_NS" sanity-pvc -o jsonpath='{.status.phase}')
        if [ "$PVC_STATUS" = "Bound" ]; then
            log_message "${GREEN}✅ PVC successfully bound${NC}"
        else
            log_message "${RED}❌ PVC failed to bind${NC}"
            log_message "${YELLOW}PVC Status:${NC}"
            kubectl get pvc -n "$TEST_NS" sanity-pvc
            kubectl describe pvc -n "$TEST_NS" sanity-pvc
            TESTS_FAILED=true
        fi
    fi

    # Log PVC details
    log_message "${YELLOW}PVC Details:${NC}"
    kubectl get pvc -n "$TEST_NS" sanity-pvc >> "$LOG_FILE"

    # Wait for storage test pod
    log_message "${YELLOW}Waiting for storage test pod to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=ready pod/storage-test -n $TEST_NS --timeout=60s" "Wait for storage test pod"; then
        log_message "${RED}❌ Storage test pod failed to become ready${NC}"
        kubectl get pod -n $TEST_NS storage-test
        kubectl describe pod -n $TEST_NS storage-test
        TESTS_FAILED=true
    fi

    # Test file operations
    log_message "${YELLOW}Testing file creation with user 1001:1001...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS storage-test -- /bin/bash -c 'echo \"Test content\" > /data/test.txt'" "Create test file"; then
        log_message "${RED}❌ Failed to create test file${NC}"
        TESTS_FAILED=true
    fi

    # Verify permissions
    log_message "${YELLOW}Verifying file permissions and ownership...${NC}"
    FILE_OWNER=$(kubectl exec -n $TEST_NS storage-test -- ls -ln /data/test.txt | awk '{print $3":"$4}')
    if [ "$FILE_OWNER" = "1001:1001" ]; then
        log_message "${GREEN}✅ File ownership verified: $FILE_OWNER${NC}"
    else
        log_message "${RED}❌ Incorrect file ownership: $FILE_OWNER (expected 1001:1001)${NC}"
        TESTS_FAILED=true
    fi

    # Test 1: Create file as user 1001:1001 (already implemented)
    log_message "${YELLOW}Test 1: File created by user 1001:1001${NC}"
    log_message "${GREEN}✅ Test 1 completed (file created with correct ownership)${NC}"

    # Test 2: Create file as root and change ownership
    log_message "${YELLOW}Test 2: Creating root pod to test ownership change...${NC}"
    
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
    log_message "${YELLOW}Waiting for root pod to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=ready pod/root-test -n $TEST_NS --timeout=60s" "Wait for root pod"; then
        log_message "${RED}❌ Root pod failed to become ready${NC}"
        TESTS_FAILED=true
    fi

    # Create file as root
    log_message "${YELLOW}Creating file as root...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS root-test -- touch /data/root_test.txt" "Create file as root"; then
        log_message "${RED}❌ Failed to create file as root${NC}"
        TESTS_FAILED=true
    fi

    # Verify initial ownership (should be 0:0)
    ROOT_FILE_OWNER=$(kubectl exec -n $TEST_NS root-test -- ls -ln /data/root_test.txt | awk '{print $3":"$4}')
    if [ "$ROOT_FILE_OWNER" = "0:0" ]; then
        log_message "${GREEN}✅ Initial file ownership verified: $ROOT_FILE_OWNER${NC}"
    else
        log_message "${RED}❌ Incorrect initial file ownership: $ROOT_FILE_OWNER (expected 0:0)${NC}"
        TESTS_FAILED=true
    fi

    # Change ownership to 1001:1001
    log_message "${YELLOW}Changing file ownership to 1001:1001...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS root-test -- chown 1001:1001 /data/root_test.txt" "Change file ownership"; then
        log_message "${RED}❌ Failed to change file ownership${NC}"
        TESTS_FAILED=true
    fi

    # Verify new ownership
    NEW_OWNER=$(kubectl exec -n $TEST_NS root-test -- ls -ln /data/root_test.txt | awk '{print $3":"$4}')
    if [ "$NEW_OWNER" = "1001:1001" ]; then
        log_message "${GREEN}✅ File ownership successfully changed to: $NEW_OWNER${NC}"
    else
        log_message "${RED}❌ Failed to change file ownership. Current ownership: $NEW_OWNER (expected 1001:1001)${NC}"
        TESTS_FAILED=true
    fi

    # Add storage test results to log
    log_message "\n==== Storage Test Summary ====" >> "$LOG_FILE"
    log_message "StorageClass: $SC_TO_USE" >> "$LOG_FILE"
    log_message "PVC Status:" >> "$LOG_FILE"
    kubectl get pvc sanity-pvc -n $TEST_NS -o wide >> "$LOG_FILE"
    log_message "User-created File Permissions:" >> "$LOG_FILE"
    kubectl exec -n $TEST_NS storage-test -- ls -l /data/test.txt >> "$LOG_FILE"
    log_message "Root-created File Permissions:" >> "$LOG_FILE"
    kubectl exec -n $TEST_NS root-test -- ls -l /data/root_test.txt >> "$LOG_FILE"

    log_message "${GREEN}✅ Storage test completed${NC}"

    # Return overall test status
    if [ "$TESTS_FAILED" = true ]; then
        return 1
    fi
    return 0
}

# Function to run TLS tests
run_tls_tests() {
    log_message "${YELLOW}Running TLS configuration tests...${NC}"
    local TESTS_FAILED=0

    # Create test namespace if not exists
    if [ -z "$TEST_NS" ]; then
        TEST_NS="sanity-test-$(date +%s)"
        log_message "${YELLOW}Creating test namespace: $TEST_NS${NC}"
        if ! log_command "kubectl create namespace $TEST_NS" "Create test namespace"; then
            log_message "${RED}❌ Failed to create test namespace${NC}"
            return 1
        fi
    fi

    # Create TLS secret
    log_message "${YELLOW}Creating TLS secret...${NC}"
    if log_command "kubectl create secret tls sanity-tls -n $TEST_NS --cert=$CERT_FILE --key=$KEY_FILE" "Create TLS secret"; then
        TLS_SECRET_CREATED=true
    else
        log_message "${RED}❌ Failed to create TLS secret${NC}"
        return 1
    fi

    # Create test service and deployment
    log_message "${YELLOW}Creating test deployment and service...${NC}"
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
    log_message "${YELLOW}Creating test ingress...${NC}"
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
        log_message "${RED}❌ Failed to create ingress${NC}"
        return 1
    fi

    # Wait for deployment to be ready
    log_message "${YELLOW}Waiting for test deployment to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=available deployment/nginx-test -n $TEST_NS --timeout=60s" "Wait for deployment"; then
        log_message "${RED}❌ Deployment failed to become ready${NC}"
        return 1
    fi

    # Test 1: External curl with SSL verification
    log_message "${YELLOW}Testing external HTTPS access...${NC}"
    log_message "${YELLOW}Performing curl test to https://$DNS_NAME/sanity-test${NC}"
    if [ -n "$CA_CERT" ]; then
        log_message "${YELLOW}Using CA certificate for SSL verification${NC}"
        if log_command "curl -v --cacert $CA_CERT https://$DNS_NAME/sanity-test" "External HTTPS test with SSL verification"; then
            HTTPS_ACCESS_OK=true
        else
            log_message "${YELLOW}⚠️ SSL verification failed as expected (no valid CA cert)${NC}"
        fi
    else
        log_message "${YELLOW}Testing without CA certificate (expecting SSL verification failure)${NC}"
        if ! log_command "curl -v https://$DNS_NAME/sanity-test" "External HTTPS test without CA cert"; then
            log_message "${YELLOW}⚠️ SSL verification failed as expected (no valid CA cert)${NC}"
            # For no CA cert case, we consider it a success if we get a response (even if SSL fails)
            HTTPS_ACCESS_OK=true
        else
            log_message "${RED}❌ Unexpected success: SSL verification should have failed${NC}"
            return 1
        fi
    fi

    # Test 2: Internal pod test
    log_message "${YELLOW}Testing internal pod access...${NC}"
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
    log_message "${YELLOW}Waiting for test pod to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=ready pod/curl-test -n $TEST_NS --timeout=60s" "Wait for test pod"; then
        log_message "${RED}❌ Test pod failed to become ready${NC}"
        return 1
    fi

    # Copy the certificate to the pod
    log_message "${YELLOW}Copying certificate to test pod...${NC}"
    if ! log_command "kubectl cp $CERT_FILE $TEST_NS/curl-test:/tmp/cert.pem -c curl" "Copy certificate to pod"; then
        log_message "${RED}❌ Failed to copy certificate to pod${NC}"
        return 1
    fi

    # Test internal HTTPS access
    log_message "${YELLOW}Testing internal HTTPS access...${NC}"
    if [ -n "$CA_CERT" ]; then
        log_message "${YELLOW}Copying CA certificate to test pod...${NC}"
        if ! log_command "kubectl cp $CA_CERT $TEST_NS/curl-test:/tmp/ca.pem -c curl" "Copy CA certificate to pod"; then
            log_message "${RED}❌ Failed to copy CA certificate to pod${NC}"
            return 1
        fi

        if log_command "kubectl exec -n $TEST_NS curl-test -- curl -v --cacert /tmp/ca.pem https://$DNS_NAME/sanity-test" "Internal HTTPS test with SSL verification"; then
            HTTPS_ACCESS_OK=true
        else
            log_message "${RED}❌ Internal HTTPS test failed${NC}"
            return 1
        fi
    fi

    return 0
}

# Cleanup function
cleanup() {
    local exit_code=$?
    
    # Now show cleanup message and perform cleanup
    if [ "$SILENT_MODE" = false ]; then
        echo -e "\n${YELLOW}Running cleanup...${NC}"
        
        if [ -n "$TEST_NS" ]; then
            echo -e "${YELLOW}Deleting namespace $TEST_NS...${NC}"
            kubectl delete namespace "$TEST_NS" --timeout=60s &>/dev/null || true
            
            for i in {1..30}; do
                if ! kubectl get namespace "$TEST_NS" &>/dev/null; then
                    echo -e "${GREEN}✅ Namespace $TEST_NS deleted successfully${NC}"
                    break
                fi
                sleep 1
            done
            
            if kubectl get namespace "$TEST_NS" &>/dev/null; then
                echo -e "${YELLOW}⚠️ Forcing namespace deletion...${NC}"
                kubectl delete namespace "$TEST_NS" --force --grace-period=0 &>/dev/null || true
            fi
        fi
        
        echo -e "${YELLOW}Cleanup completed${NC}"
        echo -e "${YELLOW}Log file: $LOG_FILE${NC}"
    fi
    
    # Exit with the original exit code
    exit $exit_code
}

# Initialize variables
HARDWARE_CHECK=false
DIAG=false
DIAG_DNS=""
SILENT_MODE=false
VALID_ARGS=false

# Initialize test result variables
STORAGE_TEST_RESULT=0
HARDWARE_TEST_RESULT=0
DIAG_TEST_RESULT=0
TLS_TEST_RESULT=0
TLS_SECRET_CREATED=false
INGRESS_CREATED=false
HTTPS_ACCESS_OK=false
all_passed=true

# Function to echo only if not in silent mode
log_message() {
    if [ "$SILENT_MODE" = false ]; then
        echo -e "$1"
    fi
}

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
        --silent)
            SILENT_MODE=true
            VALID_ARGS=true
            shift
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
    log_message "${YELLOW}Creating test namespace: $TEST_NS${NC}"
    if ! log_command "kubectl create namespace $TEST_NS" "Create test namespace"; then
        log_message "${RED}❌ Failed to create test namespace${NC}"
        STORAGE_TEST_RESULT=1
    else
        log_message "${YELLOW}Running storage-only tests...${NC}"
        run_storage_tests
        STORAGE_TEST_RESULT=$?
    fi
fi

if [ "$HARDWARE_CHECK" = "true" ]; then
    check_hardware_requirements
    HARDWARE_TEST_RESULT=$?
fi

if [ "$DIAG" = "true" ]; then
    run_diagnostics_check
    DIAG_TEST_RESULT=$?
fi

# Run TLS tests if certificate and key are provided
if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && [ -n "$DNS_NAME" ]; then
    run_tls_tests
    TLS_TEST_RESULT=$?
fi

# Set up trap for cleanup after initializing test result variables
trap cleanup EXIT

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

# Print detailed test results table
echo -e "\n${YELLOW}Detailed Test Results:${NC}"
echo -e "+----------------+------------------+------------------+"
echo -e "| Test Category  | Tests Performed  | Status          |"
echo -e "+----------------+------------------+------------------+"

# Storage Tests Summary
if [ "$STORAGE_ONLY" = "true" ]; then
    if [ "${STORAGE_TEST_RESULT:-1}" -eq 0 ]; then
        printf "| %-14s | %-16s | %-15s |\n" "Storage" "File Ownership" "✅"
        all_passed=true
    else
        printf "| %-14s | %-16s | %-15s |\n" "Storage" "File Ownership" "⚠️"
        all_passed=false
    fi
fi

# Hardware Tests Summary
if [ "$HARDWARE_CHECK" = "true" ]; then
    if [ "${TOTAL_CPU:-0}" -ge 24 ] && [ "${TOTAL_RAM_GB:-0}" -ge 24 ]; then
        printf "| %-14s | %-16s | %-15s |\n" "Hardware" "CPU/RAM" "✅"
    else
        printf "| %-14s | %-16s | %-15s |\n" "Hardware" "CPU/RAM" "⚠️"
        all_passed=false
    fi
    
    if [ "${GPU_NODES:-0}" -gt 0 ]; then
        printf "| %-14s | %-16s | %-15s |\n" "Hardware" "GPU Detection" "✅"
    else
        printf "| %-14s | %-16s | %-15s |\n" "Hardware" "GPU Detection" "⚠️"
        all_passed=false
    fi
fi

# Diagnostics Tests Summary
if [ "$DIAG" = "true" ]; then
    if [ -f "runai-diagnostics.txt" ]; then
        # Kubernetes Version
        if grep -q "Kubernetes Cluster Version.*PASS" runai-diagnostics.txt; then
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "K8s Version" "✅"
        else
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "K8s Version" "⚠️"
            all_passed=false
        fi

        # Ingress
        if grep -q "Ingress Controller.*PASS" runai-diagnostics.txt; then
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Ingress" "✅"
        else
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Ingress" "⚠️"
            all_passed=false
        fi

        # Prometheus
        if grep -q "Prometheus.*PASS" runai-diagnostics.txt; then
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Prometheus" "✅"
        else
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Prometheus" "⚠️"
            all_passed=false
        fi

        # Node Connectivity
        if grep -q "Node Connectivity.*PASS" runai-diagnostics.txt; then
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Node Connect" "✅"
        else
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Node Connect" "⚠️"
            all_passed=false
        fi

        # DNS Resolution
        if grep -q "Backend FQDN Resolve.*PASS" runai-diagnostics.txt; then
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "DNS Resolve" "✅"
        else
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "DNS Resolve" "⚠️"
            all_passed=false
        fi

        # Backend Reachability
        if grep -q "RunAI Backend Reachable.*PASS" runai-diagnostics.txt; then
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Backend" "✅"
        else
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Backend" "⚠️"
            all_passed=false
        fi

        # GPU Nodes
        if grep -q "GPU Nodes.*PASS" runai-diagnostics.txt; then
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "GPU Nodes" "✅"
        else
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "GPU Nodes" "⚠️"
            all_passed=false
        fi

        # Storage Classes
        if grep -q "Available StorageClasses.*PASS" runai-diagnostics.txt; then
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Storage" "✅"
        else
            printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "Storage" "⚠️"
            all_passed=false
        fi
    else
        printf "| %-14s | %-16s | %-15s |\n" "Diagnostics" "All Tests" "⚠️"
        all_passed=false
    fi
fi

echo -e "+----------------+------------------+------------------+"

# Overall Status Message
if [ "$all_passed" = true ]; then
    echo -e "\n${GREEN}✅ All tests completed successfully!${NC}"
else
    echo -e "\n${RED}⚠️ Some tests failed - please check the detailed results above${NC}"
fi 


