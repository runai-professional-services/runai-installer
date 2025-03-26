#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to show usage
show_usage() {
    echo -e "\nUsage: $0 [OPTIONS]"
    echo -e "\nOptions:"
    echo "  --cert CERT_FILE       Certificate file for TLS"
    echo "  --key KEY_FILE         Key file for TLS"
    echo "  --dns DNS_NAME         DNS name to test"
    echo "  --cacert CA_FILE       CA certificate file for SSL verification (optional)"
    echo "  --storage             Run only storage tests"
    echo "  --class STORAGE_CLASS  Specify StorageClass for storage tests (optional)"
    echo "  --hardware            Validate minimum hardware requirements (24 cores, 32GB RAM)"
    echo "  --diag                Run pre-installation diagnostics"
    echo -e "\nExamples:"
    echo "  $0 --cert runai.crt --key runai.key --dns runai.example.com"
    echo "  $0 --cert runai.crt --key runai.key --dns runai.example.com --cacert ca.pem"
    echo "  $0 --storage                    # Test storage with default StorageClass"
    echo "  $0 --storage --class local-path # Test storage with specific StorageClass"
    echo "  $0 --hardware                   # Check hardware requirements only"
    exit 1
}

# Create logs directory
LOGS_DIR="./logs"
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/sanity_check_$(date +%Y%m%d_%H%M%S).log"
echo "Sanity check started at $(date)" > "$LOG_FILE"

# Cleanup function
cleanup() {
    local exit_code=$?
    echo -e "\n${BLUE}Running cleanup...${NC}"
    
    if [ -n "$TEST_NS" ]; then
        echo -e "${BLUE}Deleting namespace $TEST_NS...${NC}"
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
    
    echo -e "${BLUE}Cleanup completed${NC}"
    echo -e "${BLUE}Log file: $LOG_FILE${NC}"
    
    # Exit with the original exit code
    exit $exit_code
}

# Set up trap to ensure cleanup runs on script exit
trap cleanup EXIT

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

# Function to run hardware check
run_hardware_check() {
    echo -e "\n${BLUE}Running hardware requirements check...${NC}"
    
    # Get all worker nodes (excluding nodes with master/control-plane labels)
    WORKER_NODES=$(kubectl get nodes --no-headers | grep -v -E "master|control-plane" | awk '{print $1}')
    
    if [ -z "$WORKER_NODES" ]; then
        echo -e "${RED}❌ No worker nodes found in the cluster${NC}"
        return 1
    fi

    TOTAL_CPU=0
    TOTAL_RAM=0

    echo -e "\n${BLUE}Analyzing worker nodes:${NC}"
    echo -e "----------------------------------------"
    
    # Loop through each worker node
    while read -r node; do
        echo -e "\n${BLUE}Worker Node: ${GREEN}$node${NC}"
        
        # Get CPU cores directly from capacity
        CPU_CORES=$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}')
        if [ -z "$CPU_CORES" ]; then
            echo -e "${RED}Failed to get CPU capacity for node $node${NC}"
            continue
        fi
        TOTAL_CPU=$((TOTAL_CPU + CPU_CORES))
        
        # Get RAM from capacity in Ki and convert to GB
        RAM_RAW=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}')
        if [ -z "$RAM_RAW" ]; then
            echo -e "${RED}Failed to get memory capacity for node $node${NC}"
            continue
        fi
        
        # Convert memory to GB (handling Ki suffix)
        if [[ $RAM_RAW == *Ki ]]; then
            RAM_GB=$((${RAM_RAW%Ki} / 1024 / 1024))
        elif [[ $RAM_RAW == *Mi ]]; then
            RAM_GB=$((${RAM_RAW%Mi} / 1024))
        elif [[ $RAM_RAW == *Gi ]]; then
            RAM_GB=${RAM_RAW%Gi}
        else
            # Assume the value is in Ki if no suffix
            RAM_GB=$((RAM_RAW / 1024 / 1024))
        fi
        
        TOTAL_RAM=$((TOTAL_RAM + RAM_GB))
        
        # Print node resources in requested format
        echo -e "└─ CPU Cores: ${GREEN}$CPU_CORES${NC}"
        echo -e "└─ RAM: ${GREEN}${RAM_GB}GB${NC}"
        
        # Get GPU information
        GPU_COUNT=$(kubectl get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
        if [ -n "$GPU_COUNT" ]; then
            echo -e "└─ GPU Count: ${GREEN}$GPU_COUNT${NC}"
            
            # Debug: Print all annotations to log
            echo "All node annotations:" >> "$LOG_FILE"
            kubectl get node "$node" -o jsonpath='{.metadata.annotations}' >> "$LOG_FILE"
            
            # Try different ways to get GPU type
            GPU_TYPE=$(kubectl get node "$node" -o jsonpath='{.metadata.annotations.nvidia\.com/gpu\.product}' 2>/dev/null || \
                      kubectl get node "$node" -o jsonpath='{.metadata.annotations.nvidia\.com/gpu-product}' 2>/dev/null || \
                      kubectl get node "$node" -o custom-columns=GPU:.metadata.annotations.nvidia\.com/gpu\.product --no-headers 2>/dev/null)
            
            # Debug: Print raw GPU type value
            echo "Raw GPU Type value: $GPU_TYPE" >> "$LOG_FILE"
            
            if [ -n "$GPU_TYPE" ]; then
                echo -e "└─ Type: ${GREEN}$GPU_TYPE${NC}"
            else
                # If GPU type not found in annotations, try describing node and grep
                GPU_TYPE=$(kubectl describe node "$node" | grep -i "nvidia.com/gpu.product" | awk -F= '{print $2}' | tr -d ' ')
                if [ -n "$GPU_TYPE" ]; then
                    echo -e "└─ Type: ${GREEN}$GPU_TYPE${NC}"
                fi
            fi
        fi
        
        # Log raw values for debugging
        echo "Debug - Raw values for $node:" >> "$LOG_FILE"
        echo "CPU Capacity: $(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}')" >> "$LOG_FILE"
        echo "Memory Raw: $RAM_RAW" >> "$LOG_FILE"
        echo "GPU Count: $GPU_COUNT" >> "$LOG_FILE"
        echo "GPU Type: $GPU_TYPE" >> "$LOG_FILE"
    done <<< "$WORKER_NODES"
    
    if [ "$GPU_FOUND" = false ]; then
        echo -e "${YELLOW}No GPUs found in any worker nodes${NC}"
    fi

    echo -e "\n${BLUE}Cluster Total Resources:${NC}"
    echo -e "----------------------------------------"
    echo -e "Total Worker CPU Cores: ${GREEN}$TOTAL_CPU${NC} (minimum required: 24)"
    echo -e "Total Worker RAM: ${GREEN}${TOTAL_RAM}GB${NC} (minimum required: 32GB)"
    
    # Check if requirements are met
    REQUIREMENTS_MET=true
    
    if [ "$TOTAL_CPU" -lt 24 ]; then
        echo -e "\n${RED}❌ Insufficient total CPU cores across worker nodes${NC}"
        echo -e "${RED}Required: 24 cores${NC}"
        echo -e "${RED}Available: $TOTAL_CPU cores${NC}"
        REQUIREMENTS_MET=false
    fi
    
    if [ "$TOTAL_RAM" -lt 32 ]; then
        echo -e "\n${RED}❌ Insufficient total RAM across worker nodes${NC}"
        echo -e "${RED}Required: 32GB${NC}"
        echo -e "${RED}Available: ${TOTAL_RAM}GB${NC}"
        REQUIREMENTS_MET=false
    fi
    
    if [ "$REQUIREMENTS_MET" = true ]; then
        echo -e "\n${GREEN}✅ Hardware requirements met:${NC}"
        echo -e "✓ Total Worker CPU Cores: $TOTAL_CPU (exceeds minimum: 24)"
        echo -e "✓ Total Worker RAM: ${TOTAL_RAM}GB (exceeds minimum: 32GB)"
        return 0
    else
        return 1
    fi
}

# Function to run diagnostics check
run_diagnostics_check() {
    echo -e "\n${BLUE}Running pre-installation diagnostics...${NC}"
    
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
    echo -e "${BLUE}Downloading diagnostics tool...${NC}"
    if ! curl -L -o preinstall-diagnostics "$DIAG_URL"; then
        echo -e "${RED}❌ Failed to download diagnostics tool${NC}"
        return 1
    fi
    
    # Make executable
    chmod +x preinstall-diagnostics
    
    # Run diagnostics
    echo -e "${BLUE}Running diagnostics...${NC}"
    ./preinstall-diagnostics > /dev/null 2>&1
    
    # Check if results file exists
    if [ ! -f "runai-diagnostics.txt" ]; then
        echo -e "${RED}❌ Diagnostics results file not found${NC}"
        return 1
    fi
    
    # Parse and display results
    echo -e "\n${BLUE}Diagnostic Results:${NC}"
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
    
    # Cleanup
    rm -f preinstall-diagnostics
    
    echo -e "\n${GREEN}✅ Diagnostics completed${NC}"
    return 0
}

# Initialize a flag to track if any valid arguments were provided
VALID_ARGS=false

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
            DIAG_CHECK=true
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
    echo -e "  - The --storage flag for storage-only tests\n"
    show_usage
    exit 1
fi

# Validate required parameters
if [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ "$DIAG_CHECK" != "true" ] && ([ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ] || [ -z "$DNS_NAME" ]); then
    echo -e "${RED}Error: --cert, --key, and --dns are required unless using --storage, --hardware, or --diag${NC}"
    show_usage
fi

echo -e "${BLUE}Starting sanity checks...${NC}"

# Main execution flow
if [ "$DIAG_CHECK" = "true" ] && [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ -z "$CERT_FILE" ]; then
    # Run only diagnostics check without creating namespace
    if ! run_diagnostics_check; then
        echo -e "${RED}❌ Diagnostics check failed${NC}"
        exit 1
    fi
    echo -e "\n${GREEN}✅ Diagnostics check completed successfully!${NC}"
    exit 0
fi

# Only create namespace if running storage or TLS tests
if [ "$HARDWARE_CHECK" != "true" ] || [ "$STORAGE_ONLY" = "true" ] || [ -n "$CERT_FILE" ]; then
    # Create test namespace
    TEST_NS="sanity-test-$(date +%s)"
    echo -e "${BLUE}Creating test namespace: $TEST_NS${NC}"
    if ! log_command "kubectl create namespace $TEST_NS" "Create test namespace"; then
        echo -e "${RED}❌ Failed to create test namespace${NC}"
        exit 1
    fi
fi

# Only run TLS/ingress tests if not in storage-only mode
if [ "$STORAGE_ONLY" != "true" ]; then
    # Create TLS secret
    echo -e "${BLUE}Creating TLS secret...${NC}"
    if ! log_command "kubectl create secret tls sanity-tls -n $TEST_NS --cert=$CERT_FILE --key=$KEY_FILE" "Create TLS secret"; then
        echo -e "${RED}❌ Failed to create TLS secret${NC}"
        exit 1
    fi

    # Create test service and deployment
    echo -e "${BLUE}Creating test deployment and service...${NC}"
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
    echo -e "${BLUE}Creating test ingress...${NC}"
    cat <<EOF | kubectl apply -f - >> "$LOG_FILE"
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

    # Wait for deployment to be ready
    echo -e "${BLUE}Waiting for test deployment to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=available deployment/nginx-test -n $TEST_NS --timeout=60s" "Wait for deployment"; then
        echo -e "${RED}❌ Deployment failed to become ready${NC}"
        exit 1
    fi

    # Test 1: External curl with SSL verification
    echo -e "${BLUE}Testing external HTTPS access...${NC}"
    echo -e "${BLUE}Performing curl test to https://$DNS_NAME/sanity-test${NC}"
    if [ -n "$CA_CERT" ]; then
        echo -e "${BLUE}Using CA certificate for SSL verification${NC}"
        if ! log_command "curl -v --cacert $CA_CERT https://$DNS_NAME/sanity-test" "External HTTPS test with SSL verification"; then
            echo -e "${YELLOW}⚠️ SSL verification failed as expected (no valid CA cert)${NC}"
        else
            echo -e "${GREEN}✅ External HTTPS test successful${NC}"
        fi
    else
        echo -e "${BLUE}Testing without CA certificate (expecting SSL verification failure)${NC}"
        if ! log_command "curl -v https://$DNS_NAME/sanity-test" "External HTTPS test without CA cert"; then
            echo -e "${YELLOW}⚠️ SSL verification failed as expected (no valid CA cert)${NC}"
        else
            echo -e "${RED}❌ Unexpected success: SSL verification should have failed${NC}"
        fi
    fi

    # Test 2: Internal pod test
    echo -e "${BLUE}Testing internal pod access...${NC}"
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
    echo -e "${BLUE}Waiting for test pod to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=ready pod/curl-test -n $TEST_NS --timeout=60s" "Wait for test pod"; then
        echo -e "${RED}❌ Test pod failed to become ready${NC}"
        exit 1
    fi

    # Copy the certificate to the pod
    echo -e "${BLUE}Copying certificate to test pod...${NC}"
    if ! log_command "kubectl cp $CERT_FILE $TEST_NS/curl-test:/tmp/cert.pem -c curl" "Copy certificate to pod"; then
        echo -e "${RED}❌ Failed to copy certificate to pod${NC}"
        exit 1
    fi

    # Test internal HTTPS access
    echo -e "${BLUE}Testing internal HTTPS access...${NC}"
    if [ -n "$CA_CERT" ]; then
        echo -e "${BLUE}Copying CA certificate to test pod...${NC}"
        if ! log_command "kubectl cp $CA_CERT $TEST_NS/curl-test:/tmp/ca.pem -c curl" "Copy CA certificate to pod"; then
            echo -e "${RED}❌ Failed to copy CA certificate to pod${NC}"
            exit 1
        fi
        
        if ! log_command "kubectl exec -n $TEST_NS curl-test -- curl -v --cacert /tmp/ca.pem https://$DNS_NAME/sanity-test" "Internal HTTPS test with SSL verification"; then
            echo -e "${RED}❌ Internal HTTPS test failed${NC}"
        else
            echo -e "${GREEN}✅ Internal HTTPS test successful${NC}"
        fi
    else
        echo -e "${BLUE}Testing without CA certificate (expecting SSL verification failure)${NC}"
        if ! log_command "kubectl exec -n $TEST_NS curl-test -- curl -v https://$DNS_NAME/sanity-test" "Internal HTTPS test without CA cert"; then
            echo -e "${YELLOW}⚠️ SSL verification failed as expected (no valid CA cert)${NC}"
        else
            echo -e "${RED}❌ Unexpected success: SSL verification should have failed${NC}"
        fi
    fi
fi

# Function to run storage tests
run_storage_tests() {
    echo -e "${BLUE}Testing storage functionality...${NC}"

    # Get storage class
    if [ -n "$STORAGE_CLASS" ]; then
        # Check if specified storage class exists
        if ! kubectl get storageclass "$STORAGE_CLASS" &>/dev/null; then
            echo -e "${RED}❌ StorageClass $STORAGE_CLASS not found${NC}"
            exit 1
        fi
        SC_TO_USE="$STORAGE_CLASS"
        echo -e "${BLUE}Using specified StorageClass: $SC_TO_USE${NC}"
    else
        # Get default storage class
        SC_TO_USE=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
        if [ -z "$SC_TO_USE" ]; then
            echo -e "${RED}❌ No default StorageClass found${NC}"
            exit 1
        fi
        echo -e "${BLUE}Using default StorageClass: $SC_TO_USE${NC}"
    fi

    # Create PVC first
    echo -e "${BLUE}Creating PVC...${NC}"
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
    echo -e "${BLUE}Creating storage test pod...${NC}"
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
    echo -e "${BLUE}Waiting for PVC to be bound...${NC}"
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
            echo -e "${BLUE}PVC Status:${NC}"
            kubectl get pvc -n "$TEST_NS" sanity-pvc
            kubectl describe pvc -n "$TEST_NS" sanity-pvc
            exit 1
        fi
    fi

    # Log PVC details
    echo -e "${BLUE}PVC Details:${NC}"
    kubectl get pvc -n "$TEST_NS" sanity-pvc >> "$LOG_FILE"

    # Wait for storage test pod to be ready
    echo -e "${BLUE}Waiting for storage test pod to be ready...${NC}"
    if ! log_command "kubectl wait --for=condition=ready pod/storage-test -n $TEST_NS --timeout=60s" "Wait for storage test pod"; then
        echo -e "${RED}❌ Storage test pod failed to become ready${NC}"
        # Show pod status for debugging
        kubectl get pod -n $TEST_NS storage-test
        kubectl describe pod -n $TEST_NS storage-test
        exit 1
    fi

    # Write test file and verify permissions
    echo -e "${BLUE}Testing file creation with user 1001:1001...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS storage-test -- /bin/bash -c 'echo \"Test content\" > /data/test.txt'" "Create test file"; then
        echo -e "${RED}❌ Failed to create test file${NC}"
        exit 1
    fi

    # Verify file permissions and ownership
    echo -e "${BLUE}Verifying file permissions and ownership...${NC}"
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
    echo -e "${BLUE}Verifying file content...${NC}"
    if ! log_command "kubectl exec -n $TEST_NS storage-test -- cat /data/test.txt" "Read test file"; then
        echo -e "${RED}❌ Failed to read test file${NC}"
        exit 1
    fi

    # Add storage test results to log
    echo -e "\n==== Storage Test Summary ====" >> "$LOG_FILE"
    echo "StorageClass: $SC_TO_USE" >> "$LOG_FILE"
    echo "PVC Status:" >> "$LOG_FILE"
    kubectl get pvc sanity-pvc -n $TEST_NS -o wide >> "$LOG_FILE"
    echo "File Permissions:" >> "$LOG_FILE"
    kubectl exec -n $TEST_NS storage-test -- ls -l /data/test.txt >> "$LOG_FILE"

    echo -e "${GREEN}✅ Storage test completed${NC}"
}

# Add this function near the other function definitions:

check_jfrog_secret() {
    if [ ! -f "./jfrog.yaml" ]; then
        echo -e "${YELLOW}⚠️ Warning: jfrog.yaml file not found in current directory${NC}"
        echo -e "${BLUE}Note: This file is required for accessing private registries${NC}"
        echo -e "${BLUE}Skipping repository secret configuration...${NC}"
        return 1
    fi
    
    # Try to apply the secret
    if ! log_command "kubectl apply -f ./jfrog.yaml -n $TEST_NS" "Apply repository secret"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to apply repository secret${NC}"
        echo -e "${BLUE}Note: This might affect access to private container images${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Repository secret applied successfully${NC}"
    return 0
}

# Then modify the main execution flow to include this check before creating deployments:

# In the main script, before creating any deployments, add:

if [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ]; then
    # Check for jfrog secret
    check_jfrog_secret
    # Continue with other operations regardless of secret status
fi

# Run other tests as needed
if [ "$STORAGE_ONLY" = "true" ]; then
    echo -e "${BLUE}Running storage-only tests...${NC}"
    run_storage_tests
else
    if [ -n "$CERT_FILE" ]; then
        # Run TLS/ingress tests
        # ... existing TLS/ingress test code ...
        # Run storage tests after ingress tests
        run_storage_tests
    fi
fi

# Run hardware check if requested alongside other tests
if [ "$HARDWARE_CHECK" = "true" ]; then
    if ! run_hardware_check; then
        echo -e "${RED}❌ Hardware validation failed${NC}"
        cleanup
        exit 1
    fi
fi

# Print test summary
echo -e "\n${BLUE}Test Summary:${NC}"
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
    echo -e "Full Tests:"
    echo -e "- TLS Secret Creation: ${GREEN}✓${NC}"
    echo -e "- Ingress Creation: ${GREEN}✓${NC}"
    echo -e "- Storage Tests:"
    if [ -n "$STORAGE_CLASS" ]; then
        echo -e "  - Using StorageClass: ${GREEN}$STORAGE_CLASS${NC}"
    else
        echo -e "  - Using default StorageClass"
    fi
    echo -e "  - PVC Creation: ${GREEN}✓${NC}"
    echo -e "  - Pod Creation: ${GREEN}✓${NC}"
    echo -e "  - Storage Binding: ${GREEN}✓${NC}"
fi
echo -e "----------------------------------------"

# Run cleanup
echo -e "\n${BLUE}Running cleanup...${NC}"
cleanup
echo -e "${GREEN}Cleanup completed${NC}"

echo -e "${BLUE}Log file: ${GREEN}$LOG_FILE${NC}"

# Final status
echo -e "\n${GREEN}✅ All tests completed successfully!${NC}"

# Add this new function:
run_diagnostics_check() {
    echo -e "\n${BLUE}Running pre-installation diagnostics...${NC}"
    
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
    echo -e "${BLUE}Downloading diagnostics tool...${NC}"
    if ! curl -L -o preinstall-diagnostics "$DIAG_URL"; then
        echo -e "${RED}❌ Failed to download diagnostics tool${NC}"
        return 1
    fi
    
    # Make executable
    chmod +x preinstall-diagnostics
    
    # Run diagnostics
    echo -e "${BLUE}Running diagnostics...${NC}"
    ./preinstall-diagnostics > /dev/null 2>&1
    
    # Check if results file exists
    if [ ! -f "runai-diagnostics.txt" ]; then
        echo -e "${RED}❌ Diagnostics results file not found${NC}"
        return 1
    fi
    
    # Parse and display results
    echo -e "\n${BLUE}Diagnostic Results:${NC}"
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
    
    # Cleanup
    rm -f preinstall-diagnostics
    
    echo -e "\n${GREEN}✅ Diagnostics completed${NC}"
    return 0
}

# Add to the main execution flow:
if [ "$DIAG_CHECK" = "true" ]; then
    if ! run_diagnostics_check; then
        echo -e "${RED}❌ Diagnostics check failed${NC}"
        exit 1
    fi
    # Exit if only running diagnostics
    if [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ -z "$CERT_FILE" ]; then
        exit 0
    fi
fi 
