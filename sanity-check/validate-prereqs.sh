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
    echo -e "  --skip-k8s     Skip Kubernetes cluster connectivity check"
    echo -e "  --verbose      Show detailed output"
    echo -e "  -h, --help     Show this help message"
    echo -e "\n${YELLOW}Examples:${NC}"
    echo -e "  $0                    # Check prerequisites only"
    echo -e "  $0 --verbose          # Check with detailed output"
    echo -e "  $0 --skip-k8s         # Skip K8s check"
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
        return 1
    fi
}



# Function to show installation instructions
show_installation_instructions() {
    local os="$1"
    shift
    local missing_items=("$@")
    
    for item in "${missing_items[@]}"; do
        case "$item" in
            "curl")
                echo -e "${BLUE}curl:${NC}"
                case "$os" in
                    *"Ubuntu"*|*"Debian"*) echo -e "  sudo apt-get install curl" ;;
                    *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*) echo -e "  sudo yum install curl  # or sudo dnf install curl" ;;
                    *"macOS"*) echo -e "  brew install curl" ;;
                    *) echo -e "  Install curl for your operating system" ;;
                esac
                ;;
            "jq")
                echo -e "${BLUE}jq:${NC}"
                case "$os" in
                    *"Ubuntu"*|*"Debian"*) echo -e "  sudo apt-get install jq" ;;
                    *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*) echo -e "  sudo yum install jq  # or sudo dnf install jq" ;;
                    *"macOS"*) echo -e "  brew install jq" ;;
                    *) echo -e "  Install jq for your operating system" ;;
                esac
                ;;
            "unzip")
                echo -e "${BLUE}unzip:${NC}"
                case "$os" in
                    *"Ubuntu"*|*"Debian"*) echo -e "  sudo apt-get install unzip" ;;
                    *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*) echo -e "  sudo yum install unzip  # or sudo dnf install unzip" ;;
                    *"macOS"*) echo -e "  brew install unzip" ;;
                    *) echo -e "  Install unzip for your operating system" ;;
                esac
                ;;
            "timeout")
                echo -e "${BLUE}timeout:${NC}"
                case "$os" in
                    *"Ubuntu"*|*"Debian"*) echo -e "  sudo apt-get install coreutils" ;;
                    *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*) echo -e "  sudo yum install coreutils  # or sudo dnf install coreutils" ;;
                    *"macOS"*) echo -e "  Already included in macOS" ;;
                    *) echo -e "  Install coreutils for your operating system" ;;
                esac
                ;;
            "bc")
                echo -e "${BLUE}bc:${NC}"
                case "$os" in
                    *"Ubuntu"*|*"Debian"*) echo -e "  sudo apt-get install bc" ;;
                    *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*) echo -e "  sudo yum install bc  # or sudo dnf install bc" ;;
                    *"macOS"*) echo -e "  brew install bc" ;;
                    *) echo -e "  Install bc for your operating system" ;;
                esac
                ;;
            "kubectl")
                echo -e "${BLUE}kubectl:${NC}"
                echo -e "  curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
                echo -e "  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
                echo -e "  rm kubectl"
                ;;
            "helm")
                echo -e "${BLUE}helm:${NC}"
                echo -e "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
                ;;
            "docker")
                echo -e "${BLUE}Docker:${NC}"
                case "$os" in
                    *"Ubuntu"*|*"Debian"*)
                        echo -e "  sudo apt-get update"
                        echo -e "  sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release"
                        echo -e "  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg"
                        echo -e "  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"
                        echo -e "  sudo apt-get update"
                        echo -e "  sudo apt-get install -y docker-ce docker-ce-cli containerd.io"
                        echo -e "  sudo systemctl start docker"
                        echo -e "  sudo systemctl enable docker"
                        echo -e "  sudo usermod -aG docker \$USER"
                        echo -e "  # Log out and back in for group changes to take effect"
                        ;;
                    *"CentOS"*|*"Red Hat"*|*"Rocky"*|*"Fedora"*)
                        echo -e "  sudo dnf -y install dnf-plugins-core"
                        echo -e "  sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo"
                        echo -e "  sudo dnf install -y docker-ce docker-ce-cli containerd.io"
                        echo -e "  sudo systemctl start docker"
                        echo -e "  sudo systemctl enable docker"
                        echo -e "  sudo usermod -aG docker \$USER"
                        echo -e "  # Log out and back in for group changes to take effect"
                        ;;
                    *"macOS"*)
                        echo -e "  brew install --cask docker"
                        echo -e "  # Or download from: https://www.docker.com/products/docker-desktop"
                        ;;
                    *)
                        echo -e "  Install Docker for your operating system"
                        ;;
                esac
                ;;
            "k8s-connectivity")
                echo -e "${BLUE}Kubernetes connectivity:${NC}"
                echo -e "  Ensure your Kubernetes cluster is running"
                echo -e "  Configure kubectl with correct context: kubectl config use-context <context-name>"
                echo -e "  Verify connectivity: kubectl cluster-info"
                ;;
            "preinstall-diagnostics.zip")
                echo -e "${BLUE}preinstall-diagnostics.zip:${NC}"
                echo -e "  Download the preinstall-diagnostics.zip file and place it in the current directory"
                ;;
            "sanity-check.sh")
                echo -e "${BLUE}sanity-check.sh:${NC}"
                echo -e "  Ensure sanity-check.sh is in the current directory"
                ;;
            *)
                echo -e "${BLUE}$item:${NC}"
                echo -e "  Install $item for your operating system"
                ;;
        esac
        echo ""
    done
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



# Function to check Docker functionality
check_docker() {
    # Check if Docker is installed
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    
    # Check Docker version
    local docker_version
    docker_version=$(docker --version 2>/dev/null | head -1)
    if [ -z "$docker_version" ]; then
        return 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &>/dev/null; then
        return 1
    fi
    
    # Test Docker functionality with docker ps
    if docker ps &>/dev/null; then
        return 0
    else
        return 1
    fi
}



# Main validation function
validate_prerequisites() {
    local os
    os=$(detect_os)
    local missing_items=()
    local failed_checks=()
    
    echo -e "${BLUE}Detected OS: $os${NC}\n"
    
    # Check all tools and components
    check_command "curl" "curl" "" && echo -e "${GREEN}✅ curl${NC}" || { echo -e "${RED}❌ curl${NC}"; missing_items+=("curl"); }
    check_command "jq" "jq" "" && echo -e "${GREEN}✅ jq${NC}" || { echo -e "${RED}❌ jq${NC}"; missing_items+=("jq"); }
    check_command "unzip" "unzip" "" && echo -e "${GREEN}✅ unzip${NC}" || { echo -e "${RED}❌ unzip${NC}"; missing_items+=("unzip"); }
    check_command "timeout" "timeout" "" && echo -e "${GREEN}✅ timeout${NC}" || { echo -e "${RED}❌ timeout${NC}"; missing_items+=("timeout"); }
    check_command "bc" "bc" "" && echo -e "${GREEN}✅ bc${NC}" || { echo -e "${RED}❌ bc${NC}"; missing_items+=("bc"); }
    check_command "awk" "awk" "" && echo -e "${GREEN}✅ awk${NC}" || { echo -e "${RED}❌ awk${NC}"; missing_items+=("awk"); }
    check_command "sed" "sed" "" && echo -e "${GREEN}✅ sed${NC}" || { echo -e "${RED}❌ sed${NC}"; missing_items+=("sed"); }
    check_command "grep" "grep" "" && echo -e "${GREEN}✅ grep${NC}" || { echo -e "${RED}❌ grep${NC}"; missing_items+=("grep"); }
    check_command "sort" "sort" "" && echo -e "${GREEN}✅ sort${NC}" || { echo -e "${RED}❌ sort${NC}"; missing_items+=("sort"); }
    check_command "uniq" "uniq" "" && echo -e "${GREEN}✅ uniq${NC}" || { echo -e "${RED}❌ uniq${NC}"; missing_items+=("uniq"); }
    check_command "pkill" "pkill" "" && echo -e "${GREEN}✅ pkill${NC}" || { echo -e "${RED}❌ pkill${NC}"; missing_items+=("pkill"); }
    
    # Check Docker functionality
    if check_docker; then
        echo -e "${GREEN}✅ docker${NC}"
    else
        echo -e "${RED}❌ docker${NC}"
        failed_checks+=("docker")
    fi
    
    # Check Kubernetes tools
    check_command "kubectl" "kubectl" "" && echo -e "${GREEN}✅ kubectl${NC}" || { echo -e "${RED}❌ kubectl${NC}"; missing_items+=("kubectl"); }
    check_command "helm" "helm" "3.14" && echo -e "${GREEN}✅ helm${NC}" || { echo -e "${RED}❌ helm${NC}"; failed_checks+=("helm"); }
    
    # Check Kubernetes connectivity (unless skipped)
    if [ "$SKIP_K8S" != true ]; then
        if kubectl cluster-info &>/dev/null; then
            echo -e "${GREEN}✅ k8s-connectivity${NC}"
        else
            echo -e "${RED}❌ k8s-connectivity${NC}"
            failed_checks+=("k8s-connectivity")
        fi
    fi
    
    # Check required files
    if [ -f "preinstall-diagnostics.zip" ]; then
        echo -e "${GREEN}✅ preinstall-diagnostics.zip${NC}"
    else
        echo -e "${RED}❌ preinstall-diagnostics.zip${NC}"
        missing_items+=("preinstall-diagnostics.zip")
    fi
    
    if [ -f "sanity-check.sh" ]; then
        echo -e "${GREEN}✅ sanity-check.sh${NC}"
        # Check if it's executable
        if [ -x "sanity-check.sh" ]; then
            echo -e "  └─ Script is executable"
        else
            echo -e "${YELLOW}  └─ Making script executable...${NC}"
            chmod +x sanity-check.sh
        fi
    else
        echo -e "${RED}❌ sanity-check.sh${NC}"
        missing_items+=("sanity-check.sh")
    fi
    

    
    # Show summary
    echo -e "\n${BLUE}=== VALIDATION SUMMARY ===${NC}"
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
        
        # Show installation instructions
        echo -e "\n${YELLOW}=== INSTALLATION INSTRUCTIONS ===${NC}"
        show_installation_instructions "$os" "${missing_items[@]}" "${failed_checks[@]}"
        return 1
    fi
}

# Parse command line arguments
SKIP_K8S=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
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