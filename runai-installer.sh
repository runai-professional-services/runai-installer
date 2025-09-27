#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check for required dependencies
check_dependencies() {
    echo -e "${BLUE}Checking required dependencies...${NC}"
    
    # Check for jq
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}❌ Error: jq is not installed${NC}"
        echo -e "${YELLOW}Please install jq before running this script:${NC}"
        echo -e "${YELLOW}  Ubuntu/Debian: sudo apt-get install jq${NC}"
        echo -e "${YELLOW}  CentOS/RHEL: sudo yum install jq${NC}"
        echo -e "${YELLOW}  macOS: brew install jq${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ All required dependencies are installed${NC}"
}

# Check dependencies first
check_dependencies

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
    echo "  --training             Install Kubeflow Training Operator"
    echo "  --lws                  Install Local Workload Service (LWS)"
    echo "  --install-sc           Install Local Path Provisioner and set as default storage class"
    echo "  --repo-secret FILE     Specify repository secret file location"
    echo "  --BCM                  Configure Bright Cluster Manager for Run.ai access"
    echo "  --air-gapped           Enable air-gapped installation mode"
    echo "  --file FILE            Air-gapped tar.gz file to extract (required with --air-gapped)"
    echo "  --registry URL         Registry URL for air-gapped installation (required with --air-gapped)"
    echo "  --registry-secret FILE Registry secret YAML file to apply (optional in --air-gapped mode)"
    echo "  --skip-upload          Skip image uploads when images are already in registry (air-gapped mode)"
    echo "  --uninstall            Uninstall Run.ai completely from the cluster"
    echo ""
    echo "Examples:"
    echo "  # Using sslip.io (automatic DNS resolution)"
    echo "  $0 --dns 192.168.0.100.sslip.io --runai-version 2.20.22 --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom domain with internal DNS"
    echo "  $0 --dns kirson.runai.lab --internal-dns --ip 172.21.140.20 --runai-version 2.20.22 --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom certificates"
    echo "  $0 --dns kirson.rudnai.lab --runai-version 2.20.22 --cert /path/to/cert.pem --key /path/to/key.pem --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom certificates with CA cert"
    echo "  $0 --dns kirson.runai.lab --runai-version 2.20.22 --cert /path/to/cert.pem --key /path/to/key.pem --cacert /path/to/rootCA.pem --repo-secret /root/jfrog"
    echo ""
    echo "  # Installing with additional components"
    echo "  $0 --dns 192.168.0.100.sslip.io --runai-version 2.20.22 --nginx --prometheus --gpu-operator --training --lws --install-sc --repo-secret /root/jfrog"
    echo ""
    echo "  # Patching existing Nginx installation"
    echo "  $0 --dns 192.168.0.100.sslip.io --ip 192.168.0.214 --patch-nginx --repo-secret /root/jfrog"
    echo ""
    echo "  # Air-gapped installation (no --runai-version needed)"
    echo "  $0 --dns 192.168.0.100.sslip.io --air-gapped --file /path/to/runai-air-gapped.tar.gz --registry registry.example.com"
    echo "  # Air-gapped installation with skip-upload (images already in registry)"
    echo "  $0 --dns 192.168.0.100.sslip.io --air-gapped --file /path/to/runai-air-gapped.tar.gz --registry registry.example.com --skip-upload"
    echo ""
    echo "  # Uninstall Run.ai completely"
    echo "  $0 --uninstall"
    exit 1
}

# Function to validate required parameters
validate_params() {
    # Skip validation for uninstall mode
    if [ "$UNINSTALL" = true ]; then
        return 0
    fi
    
    if [ -z "$DNS_NAME" ]; then
        echo -e "${RED}Error: --dns is required${NC}"
        show_usage
    fi

    # Run.ai version is only required when not in air-gapped mode
    if [ "$AIR_GAPPED_MODE" != true ] && [ -z "$RUNAI_VERSION" ]; then
        echo -e "${RED}Error: --runai-version is required (unless using --air-gapped mode)${NC}"
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

    # Validate air-gapped parameters
    if [ "$AIR_GAPPED_MODE" = true ]; then
        if [ -z "$AIR_GAPPED_FILE" ]; then
            echo -e "${RED}Error: --file is required when using --air-gapped${NC}"
            show_usage
        fi
        
        if [ -z "$REGISTRY_URL" ]; then
            echo -e "${RED}Error: --registry is required when using --air-gapped${NC}"
            show_usage
        fi
        
        # --registry-secret is optional in air-gapped mode
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
    
    # Initialize boolean flags (only if not already set)
    UNINSTALL=${UNINSTALL:-false}
    CLUSTER_ONLY=${CLUSTER_ONLY:-false}
    INTERNAL_DNS=${INTERNAL_DNS:-false}
    NO_CERT=${NO_CERT:-false}
    INSTALL_KNATIVE=${INSTALL_KNATIVE:-false}
    INSTALL_NGINX=${INSTALL_NGINX:-false}
    PATCH_NGINX=${PATCH_NGINX:-false}
    INSTALL_PROMETHEUS=${INSTALL_PROMETHEUS:-false}
    INSTALL_GPU_OPERATOR=${INSTALL_GPU_OPERATOR:-false}
    INSTALL_TRAINING=${INSTALL_TRAINING:-false}
    INSTALL_LWS=${INSTALL_LWS:-false}
    INSTALL_STORAGE_CLASS=${INSTALL_STORAGE_CLASS:-false}
    BCM_CONFIG=${BCM_CONFIG:-false}
    AIR_GAPPED_MODE=${AIR_GAPPED_MODE:-false}
    SKIP_UPLOAD=${SKIP_UPLOAD:-false}
    AIR_GAPPED_FILE=${AIR_GAPPED_FILE:-}
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
        --training)
            INSTALL_TRAINING=true
            shift
            ;;
        --lws)
            INSTALL_LWS=true
            shift
            ;;
        --install-sc)
            INSTALL_STORAGE_CLASS=true
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
        --air-gapped)
            AIR_GAPPED_MODE=true
            shift
            ;;
        --file)
            AIR_GAPPED_FILE="$2"
            shift 2
            ;;
        --registry)
            REGISTRY_URL="$2"
            shift 2
            ;;
        --registry-secret)
            REGISTRY_SECRET_FILE="$2"
            shift 2
            ;;
        --skip-upload)
            SKIP_UPLOAD=true
            shift
            ;;
        --BCM)
            BCM_CONFIG=true
            shift
            ;;
        --uninstall)
            UNINSTALL=true
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

# Load environment
load_env

# Handle uninstall if requested (before validation)
if [ "$UNINSTALL" = true ]; then
    echo -e "${BLUE}Uninstall mode requested...${NC}"
    
    # Check if the original uninstall script exists
    if [ -f "./sanity-check/full-runai-delete.sh" ]; then
        echo -e "${BLUE}Running full Run.ai uninstall script...${NC}"
        bash ./sanity-check/full-runai-delete.sh
        exit $?
    else
        echo -e "${RED}❌ Error: Full uninstall script not found at ./sanity-check/full-runai-delete.sh${NC}"
        exit 1
    fi
fi

# Validate parameters (only if not uninstalling)
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

# Only setup certificates if not in air-gapped mode (air-gapped handles its own certificates)
if [ "$AIR_GAPPED_MODE" != true ]; then
    source ./modules/certificates.sh
    if [ "$NO_CERT" != true ]; then
        setup_certificates
    fi
fi

# Configure BCM early if requested (skip if in air-gapped mode - air-gapped handles its own BCM)
if [ "$BCM_CONFIG" = true ] && [ "$AIR_GAPPED_MODE" != true ]; then
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

source ./modules/training.sh
if [ "$INSTALL_TRAINING" = true ]; then
    install_training_operator
fi

source ./modules/lws.sh
if [ "$INSTALL_LWS" = true ]; then
    install_lws
fi

source ./modules/storage-class.sh
if [ "$INSTALL_STORAGE_CLASS" = true ]; then
    install_storage_class
fi

source ./modules/knative.sh
if [ "$INSTALL_KNATIVE" = true ]; then
    install_knative
fi

# Handle Run.ai node labeling before any installations
echo -e "${BLUE}Configuring Run.ai node roles...${NC}"
if [ -f "./modules/node-labeling.sh" ]; then
    source ./modules/node-labeling.sh
    if handle_runai_node_labeling; then
        echo -e "${GREEN}✅ Run.ai node labeling completed successfully${NC}"
    else
        echo -e "${YELLOW}⚠️ Run.ai node labeling completed with warnings${NC}"
    fi
else
    echo -e "${YELLOW}⚠️ Node labeling module not found - skipping node labeling${NC}"
fi

source ./modules/air-gapped.sh
if [ "$AIR_GAPPED_MODE" = true ]; then
    if handle_air_gapped; then
        echo -e "${GREEN}✅ Air-gapped installation completed successfully${NC}"
        # Continue with additional components instead of exiting
    else
        echo -e "${RED}❌ Air-gapped installation failed${NC}"
        echo -e "${YELLOW}Please check the logs at $LOG_FILE for details${NC}"
        exit 1
    fi
fi

# Only install Run.ai if not in air-gapped mode (air-gapped handles its own installation)
if [ "$AIR_GAPPED_MODE" != true ]; then
    source ./modules/runai.sh
    install_runai
fi

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
echo -e "Install Training Operator: $([ "$INSTALL_TRAINING" = true ] && echo "Yes" || echo "No")"
echo -e "Install LWS: $([ "$INSTALL_LWS" = true ] && echo "Yes" || echo "No")"
echo -e "Install Storage Class: $([ "$INSTALL_STORAGE_CLASS" = true ] && echo "Yes" || echo "No")"
echo -e "Install Knative: $([ "$INSTALL_KNATIVE" = true ] && echo "Yes" || echo "No")"
echo -e "Skip Certificate Setup: $([ "$NO_CERT" = true ] && echo "Yes" || echo "No")"
echo -e "Custom Certificates: $([ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && echo "Yes" || echo "No")"
echo -e "Repository Secret: $([ -n "$REPO_SECRET" ] && echo "$REPO_SECRET" || echo "None")"
echo -e "BCM Configuration: $([ "$BCM_CONFIG" = true ] && echo "Yes" || echo "No")"
echo -e "Air-gapped Mode: $([ "$AIR_GAPPED_MODE" = true ] && echo "Yes" || echo "No")"
if [ "$AIR_GAPPED_MODE" = true ]; then
    echo -e "Air-gapped File: $([ -n "$AIR_GAPPED_FILE" ] && echo "$AIR_GAPPED_FILE" || echo "None")"
    echo -e "Registry URL: $([ -n "$REGISTRY_URL" ] && echo "$REGISTRY_URL" || echo "None")"
    echo -e "Registry Secret: $([ -n "$REGISTRY_SECRET_FILE" ] && echo "$REGISTRY_SECRET_FILE" || echo "None")"
    echo -e "Skip Upload: $([ "$SKIP_UPLOAD" = true ] && echo "Yes" || echo "No")"
fi

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