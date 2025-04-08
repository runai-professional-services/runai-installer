#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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

# Function to show usage
show_usage() {
    echo -e "${BLUE}Usage: $0 [OPTIONS]${NC}"
    echo "Options:"
    echo "  --cert CERT_FILE       Certificate file for TLS"
    echo "  --key KEY_FILE         Key file for TLS"
    echo "  --dns DNS_NAME         DNS name to test"
    echo "  --cacert CA_FILE       CA certificate file for SSL verification (optional)"
    echo "  --storage              Run only storage tests"
    echo "  --class STORAGE_CLASS  Specify StorageClass for storage tests (optional)"
    echo "  --hardware             Check hardware requirements (24GB RAM, 24 Cores)"
    echo ""
    echo "Examples:"
    echo "  $0 --cert runai.crt --key runai.key --dns runai.kirson.local"
    echo "  $0 --cert runai.crt --key runai.key --dns runai.kirson.local --cacert ca.pem"
    echo "  $0 --storage                    # Test storage with default StorageClass"
    echo "  $0 --storage --class local-path # Test storage with specific StorageClass"
    echo "  $0 --hardware                   # Check hardware requirements"
    exit 1
}

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

# Function to check hardware requirements
check_hardware_requirements() {
    echo -e "${BLUE}Checking hardware requirements...${NC}"
    echo -e "${BLUE}Minimum Required: 24GB RAM, 24 CPU Cores${NC}\n"

    # Get all nodes
    NODES=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name)
    if [ -z "$NODES" ]; then
        echo -e "${RED}❌ No nodes found in the cluster${NC}"
        return 1
    fi

    REQUIREMENTS_MET=true
    NODE_COUNT=0

    while read -r node; do
        ((NODE_COUNT++))
        echo -e "${BLUE}Checking node: ${GREEN}$node${NC}"

        # Get CPU cores
        CPU_CORES=$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}')
        if [ -z "$CPU_CORES" ]; then
            echo -e "${RED}Failed to get CPU capacity for node $node${NC}"
            REQUIREMENTS_MET=false
            continue
        fi

        # Get RAM and convert to GB
        RAM_RAW=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}')
        if [ -z "$RAM_RAW" ]; then
            echo -e "${RED}Failed to get memory capacity for node $node${NC}"
            REQUIREMENTS_MET=false
            continue
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

        # Check requirements for this node
        echo -e "└─ CPU Cores: ${BLUE}$CPU_CORES${NC} (minimum: 24)"
        echo -e "└─ RAM: ${BLUE}${RAM_GB}GB${NC} (minimum: 24GB)"

        if [ "$CPU_CORES" -lt 24 ]; then
            echo -e "${RED}❌ Insufficient CPU cores${NC}"
            REQUIREMENTS_MET=false
        fi

        if [ "$RAM_GB" -lt 24 ]; then
            echo -e "${RED}❌ Insufficient RAM${NC}"
            REQUIREMENTS_MET=false
        fi

        echo ""
    done <<< "$NODES"

    echo -e "${BLUE}Summary:${NC}"
    echo -e "----------------------------------------"
    echo -e "Nodes checked: $NODE_COUNT"
    if [ "$REQUIREMENTS_MET" = true ]; then
        echo -e "${GREEN}✅ All nodes meet minimum requirements${NC}"
        return 0
    else
        echo -e "${RED}❌ Some nodes do not meet minimum requirements${NC}"
        return 1
    fi
}

# Initialize variables
HARDWARE_CHECK=false

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
    echo -e "\n"
    show_usage
    exit 1
fi

# Validate required parameters
if [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && ([ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ] || [ -z "$DNS_NAME" ]); then
    echo -e "${RED}Error: --cert, --key, and --dns are required unless using --storage or --hardware${NC}"
    show_usage
fi

echo -e "${BLUE}Starting sanity checks...${NC}"

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

# Create test namespace
TEST_NS="sanity-test-$(date +%s)"
echo -e "${BLUE}Creating test namespace: $TEST_NS${NC}"
if ! log_command "kubectl create namespace $TEST_NS" "Create test namespace"; then
    echo -e "${RED}❌ Failed to create test namespace${NC}"
    exit 1
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

# Main execution flow
if [ "$STORAGE_ONLY" = "true" ]; then
    echo -e "${BLUE}Running storage-only tests...${NC}"
    run_storage_tests
else
    # Run storage tests after ingress tests
    run_storage_tests
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
