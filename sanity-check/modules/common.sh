#!/bin/bash

# Common Module for Sanity Check
# This module contains shared functions and variables used by other modules

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
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
    echo -e "  --disk           Check disk/ephemeral storage only"
    echo -e "  --software       Check prerequisite software only"
    echo -e "  --diag          Run preinstall diagnostics"
    echo -e "  --diag-dns NAME  DNS name for diagnostics"
    echo -e "  --prereq         Check prerequisite software"
    echo -e "  --clean          Clean up all sanity-test namespaces (manual cleanup required)"
    echo -e "  --silent        Suppress output messages"
    echo -e "  -h, --help      Show this help message"
    echo -e "\n${YELLOW}Examples:${NC}"
    echo -e "  $0 --cert cert.pem --key key.pem --dns example.com"
    echo -e "  $0 --storage"
    echo -e "  $0 --storage --class my-storage-class"
    echo -e "  $0 --hardware"
    echo -e "  $0 --disk"
    echo -e "  $0 --software"
    echo -e "  $0 --diag"
    echo -e "  $0 --diag --diag-dns example.com"
    echo -e "  $0 --clean"
    echo -e "\n${YELLOW}Note:${NC} Test namespaces are not automatically cleaned up."
    echo -e "      Run '$0 --clean' to remove test namespaces and resources."
    exit 1
}

# Function to log messages
log_message() {
    local message="$1"
    if [ "$SILENT_MODE" = false ]; then
        echo -e "$message"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

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
    
    # Check if binary already exists
    if [ -f "$DIAG_BIN" ] && [ -x "$DIAG_BIN" ]; then
        echo -e "${GREEN}✅ Preinstall diagnostics binary already exists${NC}"
        return 0
    fi
    
    # Download the binary
    DIAG_URL="https://github.com/run-ai/preinstall-diagnostics/releases/latest/download/preinstall-diagnostics-${OS_TYPE}-${ARCH}"
    
    echo -e "${YELLOW}Downloading preinstall diagnostics...${NC}"
    if curl -L -o "$DIAG_BIN" "$DIAG_URL" 2>/dev/null; then
        chmod +x "$DIAG_BIN"
        echo -e "${GREEN}✅ Preinstall diagnostics downloaded successfully${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to download preinstall diagnostics${NC}"
        return 1
    fi
}

# Function to check required components
check_required_components() {
    echo -e "${YELLOW}Checking required components...${NC}"
    
    # Get Helm releases
    HELM_RELEASES=$(helm list -A --output json 2>/dev/null | jq -r '.[].name' 2>/dev/null || echo "")
    
    # Check for GPU Operator
    if echo "$HELM_RELEASES" | grep -q "gpu-operator"; then
        echo -e "${GREEN}✅ GPU Operator installed${NC}"
    else
        echo -e "${YELLOW}⚠️ GPU Operator not found${NC}"
    fi
    
    # Check for Training Operator
    if echo "$HELM_RELEASES" | grep -q "training-operator"; then
        echo -e "${GREEN}✅ Training Operator installed${NC}"
    else
        echo -e "${YELLOW}⚠️ Training Operator not found${NC}"
    fi
    
    # Check for Prometheus
    if echo "$HELM_RELEASES" | grep -q "prometheus"; then
        echo -e "${GREEN}✅ Prometheus installed${NC}"
    else
        echo -e "${YELLOW}⚠️ Prometheus not found${NC}"
    fi
    
    echo ""
}

# Function to cleanup test resources
cleanup_test_resources() {
    local namespace="$1"
    
    if [ -z "$namespace" ]; then
        echo -e "${RED}❌ No namespace specified for cleanup${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}Cleaning up test resources in namespace: $namespace${NC}"
    
    # Delete all resources in parallel for faster cleanup
    kubectl delete all,pvc,secret,ingress --all -n "$namespace" --ignore-not-found=true --force --grace-period=0 &
    
    # Force delete the namespace immediately
    kubectl delete namespace "$namespace" --ignore-not-found=true --force --grace-period=0
    
    # Wait for background deletion to complete
    wait
    
    echo -e "${GREEN}✅ Cleanup completed for namespace: $namespace${NC}"
}

# Function to cleanup all test namespaces
cleanup_all_test_namespaces() {
    echo -e "${YELLOW}🧹 Fast cleanup of sanity-test namespaces...${NC}"
    
    # Find all sanity-test namespaces
    local test_namespaces
    test_namespaces=$(kubectl get namespaces --no-headers -o custom-columns=NAME:.metadata.name | grep "^sanity-test-" 2>/dev/null || true)
    
    if [ -z "$test_namespaces" ]; then
        echo -e "${GREEN}✅ No sanity-test namespaces found${NC}"
        return 0
    fi
    
    # Ultra-fast cleanup: delete namespaces directly with force
    echo "$test_namespaces" | xargs -I {} kubectl delete namespace {} --force --grace-period=0 --ignore-not-found=true >/dev/null 2>&1
    
    # Clean up any remaining resources in parallel
    (
        # Delete all pods in sanity-test namespaces
        kubectl get pods --all-namespaces --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null | grep "sanity-test-" | awk '{print $1, $2}' | xargs -I {} sh -c 'kubectl delete pod $2 -n $1 --force --grace-period=0 --ignore-not-found=true >/dev/null 2>&1' _ {} &
        
        # Delete all ingresses in sanity-test namespaces
        kubectl get ingress --all-namespaces --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null | grep "sanity-test-" | awk '{print $1, $2}' | xargs -I {} sh -c 'kubectl delete ingress $2 -n $1 --force --grace-period=0 --ignore-not-found=true >/dev/null 2>&1' _ {} &
        
        # Delete all PVCs in sanity-test namespaces
        kubectl get pvc --all-namespaces --no-headers -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null | grep "sanity-test-" | awk '{print $1, $2}' | xargs -I {} sh -c 'kubectl delete pvc $2 -n $1 --force --grace-period=0 --ignore-not-found=true >/dev/null 2>&1' _ {} &
    ) &
    
    # Wait a moment for cleanup to complete
    sleep 2
    
    echo -e "${GREEN}✅ Fast cleanup completed${NC}"
} 