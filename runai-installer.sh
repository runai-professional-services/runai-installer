#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Debug information
echo "Script started at $(date)"
echo "Script path: $0"
echo "Current directory: $(pwd)"
echo "Arguments: $@"

# Function to show usage
show_usage() {
    echo -e "${BLUE}Usage: $0 [OPTIONS]${NC}"
    echo "Options:"
    echo "  --dns DNS_NAME         Specify DNS name for Run.ai certificates"
    echo "  --runai-version VER    Specify Run.ai version to install"
    echo "  --cluster-only         Skip backend installation and only install Run.ai cluster"
    echo "  --internal-dns         Configure internal DNS (requires --ip)"
    echo "  --ip IP_ADDRESS        Required if --internal-dns or --patch-nginx is set"
    echo "  --cert CERT_FILE       Use provided certificate file instead of generating self-signed"
    echo "  --key KEY_FILE         Use provided key file instead of generating self-signed"
    echo "  --cacert CA_CERT_FILE  Use provided CA certificate file (e.g., rootCA.pem)"
    echo "  --no-cert              Skip certificate setup (use existing certificates)"
    echo "  --knative              Install Knative serving"
    echo "  --nginx                Install Nginx Ingress Controller (no --ip needed)"
    echo "  --patch-nginx          Patch existing Nginx Ingress Controller with external IP (requires --ip)"
    echo "  --prometheus           Install Prometheus Stack"
    echo "  --gpu-operator         Install NVIDIA GPU Operator"
    echo "  --repo-secret FILE     Specify repository secret file location"
    echo "  --BCM                  Configure Bright Cluster Manager for Run.ai access"
    echo ""
    echo "Examples:"
    echo "  # Using sslip.io (automatic DNS resolution)"
    echo "  $0 --dns 192.168.0.100.sslip.io --runai-version 2.20.22 --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom domain with internal DNS"
    echo "  $0 --dns kirson.runai.lab --internal-dns --ip 172.21.140.20 --runai-version 2.20.22 --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom certificates"
    echo "  $0 --dns kirson.runai.lab --runai-version 2.20.22 --cert /path/to/cert.pem --key /path/to/key.pem --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom certificates with CA cert"
    echo "  $0 --dns kirson.runai.lab --runai-version 2.20.22 --cert /path/to/cert.pem --key /path/to/key.pem --cacert /path/to/rootCA.pem --repo-secret /root/jfrog"
    echo ""
    echo "  # Installing with additional components"
    echo "  $0 --dns 192.168.0.100.sslip.io --runai-version 2.20.22 --nginx --prometheus --gpu-operator --repo-secret /root/jfrog"
    echo ""
    echo "  # Patching existing Nginx installation"
    echo "  $0 --dns 192.168.0.100.sslip.io --ip 192.168.0.214 --patch-nginx --repo-secret /root/jfrog"
    exit 1
}

# Function to validate required parameters
validate_params() {
    if [ -z "$DNS_NAME" ]; then
        echo -e "${RED}Error: --dns is required${NC}"
        show_usage
    fi

    if [ -z "$RUNAI_VERSION" ]; then
        echo -e "${RED}Error: --runai-version is required${NC}"
        show_usage
    fi

    if [ "$INTERNAL_DNS" = true ] && [ -z "$IP_ADDRESS" ]; then
        echo -e "${RED}Error: --ip is required when using --internal-dns${NC}"
        show_usage
    fi

    if [ -n "$CERT_FILE" ] && [ -z "$KEY_FILE" ]; then
        echo -e "${RED}Error: --key is required when using --cert${NC}"
        show_usage
    fi

    if [ -z "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
        echo -e "${RED}Error: --cert is required when using --key${NC}"
        show_usage
    fi

    if [ -n "$CA_CERT_FILE" ] && [ ! -f "$CA_CERT_FILE" ]; then
        echo -e "${RED}Error: CA certificate file not found: $CA_CERT_FILE${NC}"
        show_usage
    fi
}

# Function to load environment variables
load_env() {
    # Create logs directory
    LOGS_DIR="./logs"
    mkdir -p "$LOGS_DIR"
    LOG_FILE="$LOGS_DIR/installation_$(date +%Y%m%d_%H%M%S).log"
    echo "Installation started at $(date)" > "$LOG_FILE"

    # Create symlink to latest log
    ln -sf "$LOG_FILE" "$LOGS_DIR/latest.log"
    echo -e "${BLUE}Log file created: $LOG_FILE${NC}"
    echo -e "${BLUE}Latest log symlink: $LOGS_DIR/latest.log${NC}"

    # Export common variables
    export GREEN YELLOW BLUE RED NC
    export LOGS_DIR LOG_FILE
    export TEMP_DIR="/tmp"
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

# Main execution
if [ $# -eq 0 ]; then
    show_usage
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dns)
            DNS_NAME="$2"
            shift 2
            ;;
        --runai-version)
            RUNAI_VERSION="$2"
            shift 2
            ;;
        --cluster-only)
            CLUSTER_ONLY=true
            shift
            ;;
        --internal-dns)
            INTERNAL_DNS=true
            shift
            ;;
        --ip)
            IP_ADDRESS="$2"
            shift 2
            ;;
        --cert)
            CERT_FILE="$2"
            if [ ! -f "$CERT_FILE" ]; then
                echo -e "${RED}❌ Certificate file not found: $CERT_FILE${NC}"
                exit 1
            fi
            shift 2
            ;;
        --key)
            KEY_FILE="$2"
            if [ ! -f "$KEY_FILE" ]; then
                echo -e "${RED}❌ Key file not found: $KEY_FILE${NC}"
                exit 1
            fi
            shift 2
            ;;
        --cacert)
            CA_CERT_FILE="$2"
            if [ ! -f "$CA_CERT_FILE" ]; then
                echo -e "${RED}❌ CA certificate file not found: $CA_CERT_FILE${NC}"
                exit 1
            fi
            shift 2
            ;;
        --no-cert)
            NO_CERT=true
            shift
            ;;
        --knative)
            INSTALL_KNATIVE=true
            shift
            ;;
        --nginx)
            INSTALL_NGINX=true
            shift
            ;;
        --patch-nginx)
            PATCH_NGINX=true
            shift
            ;;
        --prometheus)
            INSTALL_PROMETHEUS=true
            shift
            ;;
        --gpu-operator)
            INSTALL_GPU_OPERATOR=true
            shift
            ;;
        --repo-secret)
            REPO_SECRET="$2"
            if [ ! -f "$REPO_SECRET" ]; then
                echo -e "${RED}❌ Repository secret file not found: $REPO_SECRET${NC}"
                exit 1
            fi
            shift 2
            ;;
        --BCM)
            BCM_CONFIG=true
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

# Load environment and validate parameters
load_env
validate_params

# Create namespaces first
echo -e "${BLUE}Creating namespaces...${NC}"
kubectl create namespace runai 2>/dev/null || true
kubectl create namespace runai-backend 2>/dev/null || true
echo -e "${GREEN}✅ Namespaces created${NC}"

# Source and execute modules based on configuration
source ./modules/log.sh
init_logging

source ./modules/helm.sh
check_helm_version

source ./modules/certificates.sh
if [ "$NO_CERT" != true ]; then
    setup_certificates
fi

# Configure BCM early if requested
if [ "$BCM_CONFIG" = true ]; then
    echo -e "${BLUE}BCM configuration requested...${NC}"
    
    if [ ! -f "./modules/bcm.sh" ]; then
        echo -e "${RED}❌ Error: BCM module not found at ./modules/bcm.sh${NC}"
        exit 1
    fi

    # Ensure required variables are set
    if [ -z "$DNS_NAME" ]; then
        echo -e "${RED}❌ Error: DNS_NAME is required for BCM configuration${NC}"
        exit 1
    fi

    # Ensure TEMP_DIR is set
    if [ -z "$TEMP_DIR" ]; then
        TEMP_DIR="/tmp"
    fi

    # Source and execute BCM module
    echo -e "${BLUE}Loading BCM module...${NC}"
    source ./modules/bcm.sh
    echo -e "${BLUE}BCM module loaded successfully${NC}"
    
    echo -e "${BLUE}Starting BCM configuration...${NC}"
    if configure_bcm; then
        echo -e "${GREEN}✅ Bright Cluster Manager configuration completed successfully${NC}"
    else
        echo -e "${RED}❌ Bright Cluster Manager configuration failed${NC}"
        echo -e "${YELLOW}Please check the logs at $LOG_FILE for details${NC}"
        exit 1
    fi
fi

source ./modules/dns.sh
if [ "$INTERNAL_DNS" = true ]; then
    patch_coredns
fi

source ./modules/nginx.sh
if [ "$INSTALL_NGINX" = true ]; then
    install_nginx
elif [ "$PATCH_NGINX" = true ]; then
    patch_nginx_service
fi

source ./modules/prerequisites.sh
if [ "$INSTALL_PROMETHEUS" = true ]; then
    install_prometheus
fi

if [ "$INSTALL_GPU_OPERATOR" = true ]; then
    install_gpu_operator
fi

source ./modules/knative.sh
if [ "$INSTALL_KNATIVE" = true ]; then
    install_knative
fi

source ./modules/runai.sh
install_runai

# Display configuration summary
echo -e "\n${GREEN}"
cat << "EOF" > /dev/null
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║              Welcome to AI Factory Installation Wizard                ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${BLUE}Configuration:${NC}"
echo -e "DNS Name: $DNS_NAME"
echo -e "Run.ai Version: $RUNAI_VERSION"
echo -e "Cluster Only: $([ "$CLUSTER_ONLY" = true ] && echo "Yes" || echo "No")"
echo -e "Internal DNS: $([ "$INTERNAL_DNS" = true ] && echo "Yes" || echo "No")"
echo -e "Install Nginx: $([ "$INSTALL_NGINX" = true ] && echo "Yes" || echo "No")"
echo -e "Patch Nginx: $([ "$PATCH_NGINX" = true ] && echo "Yes" || echo "No")"
echo -e "Install Prometheus: $([ "$INSTALL_PROMETHEUS" = true ] && echo "Yes" || echo "No")"
echo -e "Install GPU Operator: $([ "$INSTALL_GPU_OPERATOR" = true ] && echo "Yes" || echo "No")"
echo -e "Install Knative: $([ "$INSTALL_KNATIVE" = true ] && echo "Yes" || echo "No")"
echo -e "Skip Certificate Setup: $([ "$NO_CERT" = true ] && echo "Yes" || echo "No")"
echo -e "Custom Certificates: $([ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && echo "Yes" || echo "No")"
echo -e "Repository Secret: $([ -n "$REPO_SECRET" ] && echo "$REPO_SECRET" || echo "None")"
echo -e "BCM Configuration: $([ "$BCM_CONFIG" = true ] && echo "Yes" || echo "No")"

# Final success message
echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                                       ║${NC}"
echo -e "${GREEN}║              Installation Completed Successfully!                     ║${NC}"
echo -e "${GREEN}║                                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
echo -e "\n${BLUE}You can access Run.ai at: ${GREEN}https://$DNS_NAME${NC}"
echo -e "${BLUE}Default credentials: ${GREEN}test@run.ai / Abcd!234${NC}\n"

# Add certificate instructions if using self-signed certificates
if [ -z "$CERT_FILE" ] && [ -z "$KEY_FILE" ]; then
    echo -e "${YELLOW}For self-signed certificates:${NC}"
    echo -e "${YELLOW}1. Copy the root CA certificate to your browser:${NC}"
    echo -e "${YELLOW}   - Chrome: Settings -> Privacy and Security -> Security -> Manage Certificates -> Authorities -> Import${NC}"
    echo -e "${YELLOW}   - Firefox: Settings -> Privacy & Security -> Certificates -> View Certificates -> Authorities -> Import${NC}"
    echo -e "${YELLOW}2. For Ubuntu systems, install the certificate:${NC}"
    echo -e "${YELLOW}   - Copy the certificate: ${GREEN}sudo cp ./certificates/rootCA.pem /usr/local/share/ca-certificates/runai-ca.crt${NC}"
    echo -e "${YELLOW}   - Update the certificate store: ${GREEN}sudo update-ca-certificates --fresh${NC}"
    echo -e "${YELLOW}3. Select the file: ${GREEN}./certificates/rootCA.pem${NC}"
    echo
fi

echo -e "${BLUE}Thank you for using the AI Factory One-Click Installer!${NC}" 