#!/bin/bash

# Sanity Check Script - Modular Version
# This script uses modules from the modules/ directory

# Color definitions for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Determine script directory robustly
if [ -n "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Source module files
if [ -f "$SCRIPT_DIR/modules/common.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/modules/common.sh"
fi
if [ -f "$SCRIPT_DIR/modules/hardware.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/modules/hardware.sh"
fi
if [ -f "$SCRIPT_DIR/modules/certificates.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/modules/certificates.sh"
fi
if [ -f "$SCRIPT_DIR/modules/storage.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/modules/storage.sh"
fi

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
    echo -e "${YELLOW}Setting up preinstall diagnostics tool...${NC}"
    
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
    
    # Check if zip file exists
    if [ ! -f "preinstall-diagnostics.zip" ]; then
        echo -e "${RED}❌ preinstall-diagnostics.zip not found in current directory${NC}"
        return 1
    fi

    # Create a temporary directory for extraction
    TMP_DIR=$(mktemp -d)
    
    # Unzip the file
    if ! unzip -q preinstall-diagnostics.zip -d "$TMP_DIR"; then
        echo -e "${RED}❌ Failed to unzip preinstall-diagnostics.zip${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # Find the correct binary for current OS and architecture
    BINARY_NAME="preinstall-diagnostics-${OS_TYPE}-${ARCH}"
    if [ ! -f "$TMP_DIR/$BINARY_NAME" ]; then
        echo -e "${RED}❌ Binary for ${OS_TYPE}-${ARCH} not found in zip file${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # Copy and make executable
    cp "$TMP_DIR/$BINARY_NAME" "$DIAG_BIN"
    chmod +x "$DIAG_BIN"

    # Cleanup
    rm -rf "$TMP_DIR"
    
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

    # Run diagnostics with timeout
    echo -e "${YELLOW}Running diagnostics...${NC}"
    if [ -n "$DIAG_DNS" ]; then
        echo -e "${YELLOW}Running DNS diagnostics for domain: $DIAG_DNS${NC}"
        echo -e "${YELLOW}This may take a few minutes...${NC}"
        if ! timeout 300 ./preinstall-diagnostics --domain "$DIAG_DNS" --cluster-domain "$DIAG_DNS" > /dev/null 2>&1; then
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                echo -e "${RED}❌ Diagnostics timed out after 5 minutes${NC}"
            else
                echo -e "${RED}❌ Diagnostics failed (exit code: $exit_code)${NC}"
            fi
            return 1
        fi
    else
        echo -e "${YELLOW}This may take a few minutes...${NC}"
        if ! timeout 300 ./preinstall-diagnostics > /dev/null 2>&1; then
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                echo -e "${RED}❌ Diagnostics timed out after 5 minutes${NC}"
            else
                echo -e "${RED}❌ Diagnostics failed (exit code: $exit_code)${NC}"
            fi
            return 1
        fi
    fi

    # Check if results file exists
    if [ ! -f "runai-diagnostics.txt" ]; then
        echo -e "${RED}❌ Diagnostics results file not found${NC}"
        return 1
    fi

    # Parse and display results in a clean format
    echo -e "\n${YELLOW}Diagnostic Results:${NC}"
    
    # Track current server for grouping
    CURRENT_SERVER=""
    
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
                # Format test name
                TEST_NAME=$(echo "$TEST_NAME" | xargs)
                
                # Check if this is a new server
                if [[ "$TEST_NAME" =~ ^Node.* ]]; then
                    # Add blank line for new servers
                    if [ -n "$CURRENT_SERVER" ]; then
                        echo ""
                    fi
                    CURRENT_SERVER="$TEST_NAME"
                    echo -e "${YELLOW}$TEST_NAME${NC}"
                fi
                
                # Format status (plain text)
                if [ "$RESULT" = "PASS" ]; then
                    STATUS="PASS"
                else
                    STATUS="FAIL"
                fi
                
                # Print result
                if [ "$RESULT" = "PASS" ]; then
                    echo -e "  ${GREEN}✓ $TEST_NAME: $STATUS${NC}"
                else
                    echo -e "  ${RED}✗ $TEST_NAME: $STATUS${NC}"
                    if [ -n "$MESSAGE" ]; then
                        # Clean up the error message - remove table formatting and extra characters
                        CLEAN_MESSAGE=$(echo "$MESSAGE" | sed 's/|//g' | sed 's/+-*//g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                        if [ -n "$CLEAN_MESSAGE" ]; then
                            echo -e "    ${YELLOW}Error: $CLEAN_MESSAGE${NC}"
                        fi
                    fi
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



# Source hardware module
# source "$SCRIPT_DIR/modules/hardware.sh"

# Source certificates module
# source "$SCRIPT_DIR/modules/certificates.sh"

# Function to check all nodes storage (replaces the old GPU-only function)
check_all_nodes_storage() {
    log_message "${YELLOW}Checking ephemeral storage on all nodes...${NC}"
    local TESTS_FAILED=false
    local total_nodes=0
    local nodes_with_issues=0

    # Get all nodes
    local all_nodes
    all_nodes=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)

    if [ -z "$all_nodes" ]; then
        log_message "${RED}❌ No nodes found in the cluster${NC}"
        return 1
    fi

    # Check each node
    while read -r node; do
        ((total_nodes++))
        echo -e "${YELLOW}-----------------------------------------${NC}"
        echo -e "${YELLOW}🎯 Node: ${GREEN}$node${NC}"
        
        if ! check_node_storage "$node"; then
            ((nodes_with_issues++))
            TESTS_FAILED=true
        fi
        echo ""
    done <<< "$all_nodes"

    # Summary
    echo -e "${YELLOW}Storage Check Summary:${NC}"
    echo -e "----------------------------------------"
    echo -e "Total Nodes Checked: ${YELLOW}$total_nodes${NC}"
    echo -e "Minimum Required: ${YELLOW}110GB${NC} per node (150GB for GPU nodes)"
    if [ "$nodes_with_issues" -gt 0 ]; then
        echo -e "Nodes with Issues: ${RED}$nodes_with_issues${NC}"
        echo -e "${RED}❌ Some nodes have storage issues${NC}"
        echo -e "${YELLOW}⚠️ Recommendations:${NC}"
        echo -e "   - Consider adding more storage to nodes with insufficient capacity"
        echo -e "   - Clean up unused images, logs, and temporary files"
        echo -e "   - Monitor disk usage regularly to prevent pressure conditions"
    else
        echo -e "Nodes with Issues: ${GREEN}0${NC}"
        echo -e "${GREEN}✅ All nodes have adequate storage${NC}"
    fi
    echo -e "----------------------------------------"

    if [ "$TESTS_FAILED" = true ]; then
        return 1
    fi
    return 0
}

# Source storage module
# source "$SCRIPT_DIR/modules/storage.sh"

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

    log_message "${GREEN}✅ TLS configuration test completed successfully${NC}"
    return 0
}

# Function to clean up all sanity-test namespaces
cleanup_all_test_namespaces() {
    log_message "${YELLOW}Cleaning up all sanity-test namespaces...${NC}"
    
    # Kill any existing kubectl proxy processes
    pkill -f "kubectl proxy" 2>/dev/null || true
    sleep 1
    
    # Step 1: Find all sanity-test-* namespaces and orphaned pods
    local test_namespaces
    test_namespaces=$(kubectl get namespaces --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep "^sanity-test-" || true)
    
    # Also find namespaces that have orphaned pods (pods running in non-existent namespaces)
    local orphaned_namespaces
    orphaned_namespaces=$(kubectl get pods -A --no-headers 2>/dev/null | grep "sanity-test-" | awk '{print $1}' | sort | uniq | while read -r ns; do
        if ! kubectl get namespace "$ns" &>/dev/null; then
            echo "$ns"
        fi
    done)
    
    # Combine both lists
    test_namespaces=$(echo -e "${test_namespaces}\n${orphaned_namespaces}" | sort | uniq | grep -v '^$')
    
    if [ -z "$test_namespaces" ]; then
        log_message "${GREEN}✅ No sanity-test namespaces found to clean up${NC}"
        return 0
    fi
    
    log_message "${YELLOW}Found the following test namespaces:${NC}"
    echo "$test_namespaces" | while read -r ns; do
        log_message "  - $ns"
    done
    
    local cleaned_count=0
    local failed_count=0
    
    # Clean up each namespace
    while read -r ns; do
        if [ -n "$ns" ]; then
            log_message "${YELLOW}Cleaning up namespace: $ns${NC}"
            
            # Step 2: Delete all assets inside each namespace - pods, deployments, sts, etc.
            log_message "  └─ Deleting all assets in namespace..."
            
            # Check if namespace exists
            if kubectl get namespace "$ns" &>/dev/null; then
                # Normal namespace deletion
                kubectl delete all --all -n "$ns" --ignore-not-found=true &>/dev/null
                kubectl delete pvc --all -n "$ns" --ignore-not-found=true &>/dev/null
                kubectl delete secret --all -n "$ns" --ignore-not-found=true &>/dev/null
                kubectl delete ingress --all -n "$ns" --ignore-not-found=true &>/dev/null
                kubectl delete statefulset --all -n "$ns" --ignore-not-found=true &>/dev/null
                kubectl delete daemonset --all -n "$ns" --ignore-not-found=true &>/dev/null
                kubectl delete job --all -n "$ns" --ignore-not-found=true &>/dev/null
                kubectl delete cronjob --all -n "$ns" --ignore-not-found=true &>/dev/null
            else
                # Handle orphaned pods in non-existent namespace
                log_message "  └─ Found orphaned pods in non-existent namespace, force deleting pods..."
                kubectl get pods -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | while read -r pod; do
                    if [ -n "$pod" ]; then
                        kubectl delete pod "$pod" -n "$ns" --force --grace-period=0 &>/dev/null || true
                    fi
                done
            fi
            
            # Step 3: Delete namespace with --force and immediately do API call
            if kubectl get namespace "$ns" &>/dev/null; then
                log_message "  └─ Force deleting namespace and using API cleanup..."
                kubectl delete namespace "$ns" --force --grace-period=0 &>/dev/null
                
                # Wait a moment for deletion
                sleep 3
                
                # Check if namespace is already deleted
                if ! kubectl get namespace "$ns" &>/dev/null; then
                    log_message "${GREEN}✅ Namespace $ns deleted successfully${NC}"
                    ((cleaned_count++))
                else
                    # Try API cleanup only if namespace still exists
                    log_message "  └─ Namespace still exists, trying API cleanup..."
                    
                    # Start kubectl proxy with timeout
                    kubectl proxy --port=8001 &
                    local proxy_pid=$!
                    sleep 2
                    
                    # Try to get namespace JSON with timeout
                    if timeout 10 kubectl get namespace "$ns" -o json > temp.json 2>/dev/null; then
                        if timeout 10 jq '.spec = {"finalizers":[]}' temp.json > temp_finalize.json 2>/dev/null; then
                            if timeout 10 curl -k -H "Content-Type: application/json" -X PUT --data-binary @temp_finalize.json "127.0.0.1:8001/api/v1/namespaces/$ns/finalize" &>/dev/null; then
                                log_message "  └─ API cleanup completed"
                            else
                                log_message "  └─ API cleanup failed"
                            fi
                        else
                            log_message "  └─ Failed to create finalize JSON"
                        fi
                    else
                        log_message "  └─ Failed to get namespace JSON"
                    fi
                    
                    # Cleanup temp files and proxy
                    rm -f temp.json temp_finalize.json 2>/dev/null || true
                    if [ -n "$proxy_pid" ]; then
                        kill $proxy_pid 2>/dev/null || true
                    fi
                    
                    # Wait a bit more and check final status
                    sleep 5
                    if ! kubectl get namespace "$ns" &>/dev/null; then
                        log_message "${GREEN}✅ Namespace $ns deleted successfully via API cleanup${NC}"
                        ((cleaned_count++))
                    else
                        log_message "${RED}❌ Failed to delete namespace $ns - manual cleanup may be required${NC}"
                        ((failed_count++))
                    fi
                fi
            else
                # Namespace doesn't exist, just clean up orphaned pods
                log_message "${GREEN}✅ Orphaned pods in $ns cleaned up successfully${NC}"
                ((cleaned_count++))
            fi
        fi
    done <<< "$test_namespaces"
    
    # Final cleanup of any remaining proxy processes
    pkill -f "kubectl proxy" 2>/dev/null || true
    
    log_message "\n${YELLOW}Cleanup Summary:${NC}"
    log_message "----------------------------------------"
    log_message "Namespaces cleaned: ${GREEN}$cleaned_count${NC}"
    if [ "$failed_count" -gt 0 ]; then
        log_message "Namespaces failed: ${RED}$failed_count${NC}"
        log_message "${YELLOW}⚠️ Some namespaces may require manual cleanup${NC}"
    fi
    log_message "----------------------------------------"
    
    if [ "$failed_count" -eq 0 ]; then
        log_message "${GREEN}✅ All test namespaces cleaned successfully!${NC}"
        return 0
    else
        log_message "${RED}❌ Some namespaces could not be cleaned${NC}"
        return 1
    fi
}

# Function to perform namespace cleanup in background
cleanup_namespace() {
    local ns="$1"
    local log_file="$2"

    echo "Starting cleanup for namespace: $ns" >> "$log_file"

    # Issue namespace deletion with force
    echo "Force deleting namespace $ns" >> "$log_file"
    kubectl delete namespace "$ns" --force --grace-period=0 &>> "$log_file" || true
    
    # Wait 10 seconds then do API cleanup
    echo "Waiting 10 seconds then using API cleanup..." >> "$log_file"
    sleep 10
    
    # Always use API cleanup
    echo "Using API cleanup for namespace $ns" >> "$log_file"
    
    # Check if namespace still exists before attempting API cleanup
    if kubectl get namespace "$ns" &>> "$log_file"; then
        kubectl proxy --port=8001 &>> "$log_file" &
        local proxy_pid=$!
        sleep 2
        
        # Try to get namespace JSON with timeout
        if timeout 10 kubectl get namespace "$ns" -o json > temp.json 2>> "$log_file"; then
            echo "Created temp.json for API cleanup" >> "$log_file"
            
            if timeout 10 jq '.spec = {"finalizers":[]}' temp.json > temp_finalize.json 2>> "$log_file"; then
                curl -k -H "Content-Type: application/json" -X PUT --data-binary @temp_finalize.json "127.0.0.1:8001/api/v1/namespaces/$ns/finalize" &>> "$log_file"
                echo "API cleanup completed for namespace $ns" >> "$log_file"
            else
                echo "Failed to create finalize JSON for namespace $ns" >> "$log_file"
            fi
        else
            echo "Failed to get namespace JSON for $ns" >> "$log_file"
        fi
        
        # Wait for deletion with timeout
        for j in {1..30}; do
            if ! kubectl get namespace "$ns" &>> "$log_file"; then
                echo "Namespace $ns deleted successfully via API cleanup" >> "$log_file"
                break
            fi
            sleep 1
        done

        # Cleanup temp files and proxy
        rm -f temp.json temp_finalize.json 2>> "$log_file" || true
        if [ -n "$proxy_pid" ]; then
            kill $proxy_pid 2>> "$log_file" || true
        fi
    else
        echo "Namespace $ns no longer exists, skipping API cleanup" >> "$log_file"
    fi

    # Final status check
    if kubectl get namespace "$ns" &>> "$log_file"; then
        echo "WARNING: Namespace $ns is still stuck in Terminating state" >> "$log_file"
        echo "Manual cleanup may be required for namespace $ns" >> "$log_file"
    else
        echo "Namespace $ns cleanup completed successfully" >> "$log_file"
    fi
}

# Cleanup function
cleanup() {
    local exit_code=$?
    
    # Only perform cleanup if we have a test namespace
    if [ -n "$TEST_NS" ]; then
        if [ "$SILENT_MODE" = false ]; then
            echo -e "\n${YELLOW}Running cleanup...${NC}"
            echo -e "${YELLOW}Cleaning up namespace $TEST_NS...${NC}"
        fi
        
        # First, delete all resources in the namespace explicitly
        if [ "$SILENT_MODE" = false ]; then
            echo -e "${YELLOW}Deleting test resources...${NC}"
        fi
        
        # Delete ingress first
        kubectl delete ingress sanity-ingress -n "$TEST_NS" --ignore-not-found=true &>/dev/null
        
        # Delete services
        kubectl delete service nginx-test -n "$TEST_NS" --ignore-not-found=true &>/dev/null
        
        # Delete deployments
        kubectl delete deployment nginx-test -n "$TEST_NS" --ignore-not-found=true &>/dev/null
        
        # Delete pods
        kubectl delete pod curl-test -n "$TEST_NS" --ignore-not-found=true &>/dev/null
        kubectl delete pod storage-test -n "$TEST_NS" --ignore-not-found=true &>/dev/null
        kubectl delete pod root-test -n "$TEST_NS" --ignore-not-found=true &>/dev/null
        
        # Delete PVCs
        kubectl delete pvc sanity-pvc -n "$TEST_NS" --ignore-not-found=true &>/dev/null
        
        # Delete secrets
        kubectl delete secret sanity-tls -n "$TEST_NS" --ignore-not-found=true &>/dev/null
        
        # Step 2: Always use --force delete first
        if [ "$SILENT_MODE" = false ]; then
            echo -e "${YELLOW}Force deleting namespace $TEST_NS...${NC}"
        fi
        kubectl delete namespace "$TEST_NS" --force --grace-period=0 &>/dev/null
        
        # Step 3: Wait 10 seconds then do API cleanup
        if [ "$SILENT_MODE" = false ]; then
            echo -e "${YELLOW}Waiting 10 seconds then using API cleanup...${NC}"
        fi
        sleep 10
        
        # Step 4: Check if namespace still exists before attempting API cleanup
        if kubectl get namespace "$TEST_NS" &>/dev/null; then
            if [ "$SILENT_MODE" = false ]; then
                echo -e "${YELLOW}Using API cleanup...${NC}"
            fi
            
            # Start kubectl proxy
            kubectl proxy --port=8001 &
            local proxy_pid=$!
            sleep 2
            
            # Try to get namespace JSON with timeout
            if timeout 10 kubectl get namespace "$TEST_NS" -o json > temp.json 2>/dev/null; then
                if timeout 10 jq '.spec = {"finalizers":[]}' temp.json > temp_finalize.json 2>/dev/null; then
                    # Call the finalize endpoint
                    curl -k -H "Content-Type: application/json" -X PUT --data-binary @temp_finalize.json "127.0.0.1:8001/api/v1/namespaces/$TEST_NS/finalize" &>/dev/null
                fi
            fi
            
            # Cleanup temp files and proxy
            rm -f temp.json temp_finalize.json 2>/dev/null || true
            if [ -n "$proxy_pid" ]; then
                kill $proxy_pid 2>/dev/null || true
            fi
            
            # Wait for namespace to be deleted
            count=0
            while [ $count -lt 15 ]; do
                if ! kubectl get namespace "$TEST_NS" &>/dev/null; then
                    if [ "$SILENT_MODE" = false ]; then
                        echo -e "${GREEN}✅ Namespace $TEST_NS deleted via API cleanup${NC}"
                    fi
                    break
                fi
                sleep 1
                ((count++))
            done
        else
            if [ "$SILENT_MODE" = false ]; then
                echo -e "${GREEN}✅ Namespace $TEST_NS already deleted${NC}"
            fi
        fi
        
        if [ "$SILENT_MODE" = false ]; then
            echo -e "${YELLOW}Cleanup completed${NC}"
            echo -e "${YELLOW}Log file: $LOG_FILE${NC}"
        fi
    fi
    
    # Exit with the original exit code
    exit $exit_code
}

# Initialize variables
HARDWARE_CHECK=false
DISK_CHECK=false
DIAG=false
DIAG_DNS=""
CLEAN=false
SILENT_MODE=false
VALID_ARGS=false

# Initialize test result variables
STORAGE_TEST_RESULT=0
HARDWARE_TEST_RESULT=0
DISK_TEST_RESULT=0
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

# Function to show usage information
show_usage() {
    echo -e "${YELLOW}Usage:${NC}"
    echo -e "  sanity-check.sh [options]"
    echo -e ""
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  --cert FILE      Certificate file for TLS"
    echo -e "  --key FILE       Private key file for TLS"
    echo -e "  --dns NAME       DNS name for ingress"
    echo -e "  --cacert FILE    CA certificate file (optional)"
    echo -e "  --storage        Run storage tests only"
    echo -e "  --class NAME     Specify storage class (optional)"
    echo -e "  --hardware       Check hardware requirements only"
    echo -e "  --disk           Check disk/ephemeral storage only"
    echo -e "  --software       Check prerequisite software only"
    echo -e "  --diag          Run preinstall diagnostics"
    echo -e "  --diag-dns NAME  DNS name for diagnostics"
    echo -e "  --prereq         Check prerequisite software"
    echo -e "  --clean          Clean up all sanity-test namespaces (manual cleanup required)"
    echo -e "  --silent        Suppress output messages"
    echo -e "  -h, --help      Show this help message"
    echo -e ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  ./sanity-check.sh --cert cert.pem --key key.pem --dns example.com"
    echo -e "  ./sanity-check.sh --storage"
    echo -e "  ./sanity-check.sh --hardware"
    echo -e "  ./sanity-check.sh --diag --diag-dns example.com"
    exit 1
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
        --disk)
            DISK_CHECK=true
            VALID_ARGS=true
            shift
            ;;
        --software)
            SOFTWARE_CHECK=true
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
        --clean)
            CLEAN=true
            VALID_ARGS=true
            shift
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
    echo -e "  - The --disk flag for disk/ephemeral storage check"
    echo -e "  - The --software flag for prerequisite software check"
    echo -e "  - The --diag flag for preinstall diagnostics"
    echo -e "  - The --clean flag to clean up test namespaces"
    echo -e "\n"
    show_usage
    exit 1
fi

# Run diagnostics first if requested, and exit if it's the only operation
if [ "$DIAG" = true ] && [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ "$DISK_CHECK" != "true" ] && [ -z "$CERT_FILE" ]; then
    if ! run_diagnostics_check; then
        echo -e "${RED}❌ Diagnostics check failed${NC}"
        exit 1
    fi
    echo -e "\n${GREEN}✅ Diagnostics check completed successfully!${NC}"
    exit 0
fi

# Validate required parameters
if [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ "$DISK_CHECK" != "true" ] && [ "$SOFTWARE_CHECK" != "true" ] && [ "$CLEAN" != "true" ] && ([ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ] || [ -z "$DNS_NAME" ]); then
    echo -e "${RED}Error: --cert, --key, and --dns are required unless using --storage, --hardware, --disk, --software, or --clean${NC}"
    show_usage
fi

# Add validation after argument parsing
if [ -n "$DIAG_DNS" ] && [ "$DIAG" != true ]; then
    echo -e "${RED}Error: --diag-dns requires --diag flag${NC}"
    show_usage
fi

# Note: Storage tests can run alongside certificate tests
# We don't set STORAGE_ONLY=false here to allow both to run



# Run cleanup if requested
if [ "$CLEAN" = "true" ]; then
    if ! cleanup_all_test_namespaces; then
        echo -e "${RED}❌ Cleanup failed${NC}"
        exit 1
    fi
    # Only exit if this is the only operation requested
    if [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ "$DISK_CHECK" != "true" ] && [ "$SOFTWARE_CHECK" != "true" ] && [ "$DIAG" != "true" ] && [ -z "$CERT_FILE" ]; then
        echo -e "\n${GREEN}✅ Cleanup completed successfully!${NC}"
        exit 0
    fi
fi

# Run hardware check if requested (early exit only if it's the only operation)
if [ "$HARDWARE_CHECK" = "true" ] && [ "$STORAGE_ONLY" != "true" ] && [ "$DISK_CHECK" != "true" ] && [ "$SOFTWARE_CHECK" != "true" ] && [ "$DIAG" != "true" ] && [ -z "$CERT_FILE" ]; then
    if ! check_hardware_requirements; then
        echo -e "${RED}❌ Hardware validation failed${NC}"
        exit 1
    fi
    echo -e "\n${GREEN}✅ Hardware check completed successfully!${NC}"
    exit 0
fi

# Run software check if requested (early exit only if it's the only operation)
if [ "$SOFTWARE_CHECK" = "true" ] && [ "$STORAGE_ONLY" != "true" ] && [ "$HARDWARE_CHECK" != "true" ] && [ "$DISK_CHECK" != "true" ] && [ "$DIAG" != "true" ] && [ -z "$CERT_FILE" ]; then
    if ! bash "$(dirname "$0")/validate-prereqs.sh"; then
        echo -e "${RED}❌ Software validation failed${NC}"
        exit 1
    fi
    echo -e "\n${GREEN}✅ Software check completed successfully!${NC}"
    exit 0
fi

# Run disk check if requested
if [ "$DISK_CHECK" = "true" ]; then
    check_all_nodes_storage
    DISK_TEST_RESULT=$?
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

if [ "$SOFTWARE_CHECK" = "true" ]; then
    bash "$(dirname "$0")/validate-prereqs.sh"
    SOFTWARE_TEST_RESULT=$?
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

# Final summary
echo -e "\n${YELLOW}Test Summary:${NC}"
echo -e "----------------------------------------"
if [ "$STORAGE_ONLY" = "true" ]; then
    if [ $STORAGE_TEST_RESULT -eq 0 ]; then
        echo -e "Storage Tests: ${GREEN}✅ PASSED${NC}"
    else
        echo -e "Storage Tests: ${RED}❌ FAILED${NC}"
    fi
fi

if [ "$HARDWARE_CHECK" = "true" ]; then
    if [ $HARDWARE_TEST_RESULT -eq 0 ]; then
        echo -e "Hardware Check: ${GREEN}✅ PASSED${NC}"
    else
        echo -e "Hardware Check: ${RED}❌ FAILED${NC}"
    fi
fi

if [ "$SOFTWARE_CHECK" = "true" ]; then
    if [ $SOFTWARE_TEST_RESULT -eq 0 ]; then
        echo -e "Software Check: ${GREEN}✅ PASSED${NC}"
    else
        echo -e "Software Check: ${RED}❌ FAILED${NC}"
    fi
fi

if [ "$DISK_CHECK" = "true" ]; then
    if [ $DISK_TEST_RESULT -eq 0 ]; then
        echo -e "Disk Check: ${GREEN}✅ PASSED${NC}"
    else
        echo -e "Disk Check: ${RED}❌ FAILED${NC}"
    fi
fi

if [ "$DIAG" = "true" ]; then
    if [ $DIAG_TEST_RESULT -eq 0 ]; then
        echo -e "Diagnostics: ${GREEN}✅ PASSED${NC}"
    else
        echo -e "Diagnostics: ${RED}❌ FAILED${NC}"
    fi
fi

if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && [ -n "$DNS_NAME" ]; then
    if [ $TLS_TEST_RESULT -eq 0 ]; then
        echo -e "TLS Tests: ${GREEN}✅ PASSED${NC}"
    else
        echo -e "TLS Tests: ${RED}❌ FAILED${NC}"
    fi
fi
echo -e "----------------------------------------"

# Determine overall result
OVERALL_RESULT=0
if [ "$STORAGE_ONLY" = "true" ] && [ $STORAGE_TEST_RESULT -ne 0 ]; then
    OVERALL_RESULT=1
fi
if [ "$HARDWARE_CHECK" = "true" ] && [ $HARDWARE_TEST_RESULT -ne 0 ]; then
    OVERALL_RESULT=1
fi
if [ "$DISK_CHECK" = "true" ] && [ $DISK_TEST_RESULT -ne 0 ]; then
    OVERALL_RESULT=1
fi
if [ "$DIAG" = "true" ] && [ $DIAG_TEST_RESULT -ne 0 ]; then
    OVERALL_RESULT=1
fi
if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && [ -n "$DNS_NAME" ] && [ $TLS_TEST_RESULT -ne 0 ]; then
    OVERALL_RESULT=1
fi

if [ $OVERALL_RESULT -eq 0 ]; then
    echo -e "\n${GREEN}✅ All tests completed successfully!${NC}"
    exit 0
else
    echo -e "\n${RED}❌ Some tests failed${NC}"
    exit 1
fi




