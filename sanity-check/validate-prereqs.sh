#!/bin/bash

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
    echo -e "  --fix          Attempt to install missing prerequisites"
    echo -e "  --skip-k8s     Skip Kubernetes cluster connectivity check"
    echo -e "  --verbose      Show detailed output"
    echo -e "  -h, --help     Show this help message"
    echo -e "\n${YELLOW}Examples:${NC}"
    echo -e "  $0                    # Check prerequisites only"
    echo -e "  $0 --fix              # Check and install missing prerequisites"
    echo -e "  $0 --verbose          # Check with detailed output"
    echo -e "  $0 --skip-k8s --fix   # Skip K8s check and install missing prereqs"
}

# Function to detect OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS=$NAME
            VER=$VERSION_ID
        elif type lsb_release >/dev/null 2>&1; then
            OS=$(lsb_release -si)
            VER=$(lsb_release -sr)
        elif [ -f /etc/lsb-release ]; then
            . /etc/lsb-release
            OS=$DISTRIB_ID
            VER=$DISTRIB_RELEASE
        elif [ -f /etc/debian_version ]; then
            OS=Debian
            VER=$(cat /etc/debian_version)
        elif [ -f /etc/SuSe-release ]; then
            OS=SuSE
        elif [ -f /etc/redhat-release ]; then
            OS=RedHat
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macOS"
        VER=$(sw_vers -productVersion)
    else
        OS="Unknown"
        VER="Unknown"
    fi
    echo "$OS"
}

# Function to check if command exists
check_command() {
    local cmd="$1"
    local name="$2"
    local required_version="$3"
    local install_cmd="$4"
    
    if command -v "$cmd" &>/dev/null; then
        if [ -n "$required_version" ]; then
            local version_output
            version_output=$($cmd version 2>/dev/null || $cmd --version 2>/dev/null || echo "unknown")
            
            if [[ "$cmd" == "helm" ]]; then
                local version
                version=$(echo "$version_output" | grep -oP 'v\K\d+\.\d+' | head -1)
                if [ -n "$version" ]; then
                    if (( $(echo "$version >= $required_version" | bc -l 2>/dev/null) )); then
                        return 0
                    else
                        if [ "$FIX_MODE" = true ]; then
                            echo -e "${YELLOW}Upgrading $name...${NC}"
                            eval "$install_cmd"
                        fi
                        return 1
                    fi
                else
                    return 1
                fi
            else
                return 0
            fi
        else
            return 0
        fi
    else
        if [ "$FIX_MODE" = true ] && [ -n "$install_cmd" ]; then
            echo -e "${YELLOW}Installing $name...${NC}"
            eval "$install_cmd"
            # Check again after installation
            if command -v "$cmd" &>/dev/null; then
                return 0
            else
                return 1
            fi
        fi
        return 1
    fi
}

# Function to install packages based on OS
install_package() {
    local package="$1"
    local os="$2"
    
    case "$os" in
        *"Ubuntu"*|*"Debian"*)
            sudo apt-get update && sudo apt-get install -y "$package"
            ;;
        *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*)
            if command -v dnf &>/dev/null; then
                sudo dnf install -y "$package"
            else
                sudo yum install -y "$package"
            fi
            ;;
        *"macOS"*)
            if command -v brew &>/dev/null; then
                brew install "$package"
            elif command -v port &>/dev/null; then
                sudo port install "$package"
            else
                echo -e "${RED}  └─ ❌ No package manager found (brew or port)${NC}"
                return 1
            fi
            ;;
        *)
            echo -e "${RED}  └─ ❌ Unsupported OS: $os${NC}"
            return 1
            ;;
    esac
}

# Function to install kubectl
install_kubectl() {
    local os="$1"
    
    case "$os" in
        *"Ubuntu"*|*"Debian"*)
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
            sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
            rm kubectl
            ;;
        *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*)
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
            sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
            rm kubectl
            ;;
        *"macOS"*)
            if command -v brew &>/dev/null; then
                brew install kubectl
            else
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
                sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
                rm kubectl
            fi
            ;;
        *)
            echo -e "${RED}  └─ ❌ Unsupported OS for kubectl installation: $os${NC}"
            return 1
            ;;
    esac
}

# Function to install helm
install_helm() {
    local os="$1"
    
    case "$os" in
        *"Ubuntu"*|*"Debian"*|*"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*)
            curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            ;;
        *"macOS"*)
            if command -v brew &>/dev/null; then
                brew install helm
            else
                curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            fi
            ;;
        *)
            echo -e "${RED}  └─ ❌ Unsupported OS for helm installation: $os${NC}"
            return 1
            ;;
    esac
}

# Function to check Kubernetes connectivity
check_k8s_connectivity() {
    echo -e "\n${BLUE}Checking Kubernetes cluster connectivity...${NC}"
    
    if ! command -v kubectl &>/dev/null; then
        echo -e "${RED}❌ kubectl not found - cannot check cluster connectivity${NC}"
        return 1
    fi
    
    # Check if kubectl can connect to cluster
    if kubectl cluster-info &>/dev/null; then
        echo -e "${GREEN}✅ kubectl connected to cluster${NC}"
        
        # Get cluster info
        local cluster_url
        cluster_url=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
        if [ -n "$cluster_url" ]; then
            echo -e "  └─ Cluster URL: $cluster_url"
        fi
        
        # Check if cluster is accessible
        if kubectl get nodes &>/dev/null; then
            local node_count
            node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
            echo -e "  └─ Nodes available: $node_count"
            
            # Check cluster version
            local k8s_version
            k8s_version=$(kubectl version --short 2>/dev/null | grep Server | cut -d' ' -f3)
            if [ -n "$k8s_version" ]; then
                echo -e "  └─ Kubernetes version: $k8s_version"
            fi
            
            return 0
        else
            echo -e "${RED}❌ Cannot access cluster nodes${NC}"
            return 1
        fi
    else
        echo -e "${RED}❌ kubectl cannot connect to cluster${NC}"
        echo -e "${YELLOW}  └─ Please ensure:${NC}"
        echo -e "     - Kubernetes cluster is running"
        echo -e "     - kubectl is configured with correct context"
        echo -e "     - You have proper permissions"
        return 1
    fi
}

# Function to check required files
check_required_files() {
    echo -e "\n${BLUE}Checking required files...${NC}"
    
    local files_missing=false
    
    # Check for preinstall-diagnostics.zip
    if [ ! -f "preinstall-diagnostics.zip" ]; then
        echo -e "${RED}❌ preinstall-diagnostics.zip not found${NC}"
        echo -e "${YELLOW}  └─ This file is required for diagnostics tests${NC}"
        files_missing=true
    else
        echo -e "${GREEN}✅ preinstall-diagnostics.zip found${NC}"
    fi
    
    # Check for sanity-check.sh
    if [ ! -f "sanity-check.sh" ]; then
        echo -e "${RED}❌ sanity-check.sh not found in current directory${NC}"
        files_missing=true
    else
        echo -e "${GREEN}✅ sanity-check.sh found${NC}"
        # Check if it's executable
        if [ -x "sanity-check.sh" ]; then
            echo -e "  └─ Script is executable"
        else
            echo -e "${YELLOW}  └─ Making script executable...${NC}"
            chmod +x sanity-check.sh
        fi
    fi
    
    if [ "$files_missing" = true ]; then
        return 1
    fi
    return 0
}

# Function to check system resources
check_system_resources() {
    echo -e "\n${BLUE}Checking system resources...${NC}"
    
    # Check available memory
    local mem_total
    mem_total=$(free -g 2>/dev/null | awk 'NR==2{print $2}')
    if [ -n "$mem_total" ]; then
        if [ "$mem_total" -ge 4 ]; then
            echo -e "${GREEN}✅ System memory: ${mem_total}GB${NC}"
        else
            echo -e "${YELLOW}⚠️ System memory: ${mem_total}GB (low for running tests)${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️ Could not determine system memory${NC}"
    fi
    
    # Check available disk space
    local disk_free
    disk_free=$(df -BG . | awk 'NR==2{print $4}' | sed 's/G//')
    if [ -n "$disk_free" ]; then
        if [ "$disk_free" -ge 10 ]; then
            echo -e "${GREEN}✅ Available disk space: ${disk_free}GB${NC}"
        else
            echo -e "${YELLOW}⚠️ Available disk space: ${disk_free}GB (low for running tests)${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️ Could not determine available disk space${NC}"
    fi
}

# Main validation function
validate_prerequisites() {
    local os
    os=$(detect_os)
    local missing_items=()
    local failed_checks=()
    
    # Check system utilities
    check_command "curl" "curl" "" "install_package curl \"$os\"" || missing_items+=("curl")
    check_command "jq" "jq" "" "install_package jq \"$os\"" || missing_items+=("jq")
    check_command "unzip" "unzip" "" "install_package unzip \"$os\"" || missing_items+=("unzip")
    check_command "timeout" "timeout" "" "install_package coreutils \"$os\"" || missing_items+=("timeout")
    check_command "bc" "bc" "" "install_package bc \"$os\"" || missing_items+=("bc")
    
    # Check standard Unix tools
    check_command "awk" "awk" "" "" || missing_items+=("awk")
    check_command "sed" "sed" "" "" || missing_items+=("sed")
    check_command "grep" "grep" "" "" || missing_items+=("grep")
    check_command "sort" "sort" "" "" || missing_items+=("sort")
    check_command "uniq" "uniq" "" "" || missing_items+=("uniq")
    check_command "pkill" "pkill" "" "" || missing_items+=("pkill")
    
    # Check Kubernetes tools
    check_command "kubectl" "kubectl" "" "install_kubectl \"$os\"" || missing_items+=("kubectl")
    check_command "helm" "helm" "3.14" "install_helm \"$os\"" || failed_checks+=("helm")
    
    # Check Kubernetes connectivity (unless skipped)
    if [ "$SKIP_K8S" != true ]; then
        if ! kubectl cluster-info &>/dev/null; then
            failed_checks+=("k8s-connectivity")
        fi
    fi
    
    # Check required files
    if [ ! -f "preinstall-diagnostics.zip" ]; then
        missing_items+=("preinstall-diagnostics.zip")
    fi
    if [ ! -f "sanity-check.sh" ]; then
        missing_items+=("sanity-check.sh")
    fi
    
    # Show results
    if [ ${#missing_items[@]} -eq 0 ] && [ ${#failed_checks[@]} -eq 0 ]; then
        echo -e "${GREEN}✅ All prerequisites satisfied${NC}"
        return 0
    else
        if [ ${#missing_items[@]} -gt 0 ]; then
            echo -e "${RED}❌ Missing: ${missing_items[*]}${NC}"
        fi
        if [ ${#failed_checks[@]} -gt 0 ]; then
            echo -e "${RED}❌ Failed: ${failed_checks[*]}${NC}"
        fi
        if [ "$FIX_MODE" != true ]; then
            echo -e "${YELLOW}Run with --fix to install missing components${NC}"
        fi
        return 1
    fi
}

# Parse command line arguments
FIX_MODE=false
SKIP_K8S=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --skip-k8s)
            SKIP_K8S=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
done

# Run validation
validate_prerequisites
exit $? 