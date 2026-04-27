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

# Resolve repo root: all ./modules and ./sanity-check paths work even when invoked as
#   bash /path/to/runai-installer.sh
# from another directory.
RUNAI_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$RUNAI_INSTALLER_DIR" || {
    echo -e "${RED}❌ Cannot cd to $RUNAI_INSTALLER_DIR${NC}" >&2
    exit 1
}

# Only sanity: ./runai-installer.sh --sanity [args to sanity-check.sh] — use repository logs (see block after load_env)
SANITY_PASSTHRU=()
SANITY_ONLY=0
if [ "${1:-}" = "--sanity" ]; then
    shift
    SANITY_ONLY=1
    SANITY_PASSTHRU=("$@")
    set --
fi

# Control-plane Helm helpers (JFrog vs NGC) — used by get_latest_runai_version and runai module
source ./modules/jfrog.sh
source ./modules/ngc.sh

# Debug information
echo "Script started at $(date)"
echo "Script path: $0"
echo "Current directory: $(pwd)"
echo "Arguments: $@"

# Function to get latest Run.ai version
get_latest_runai_version() {
    local pinned_ver=""
    case "${RUNAI_ARTIFACT_SOURCE:-jfrog}" in
        ngc)
            if pinned_ver="$(runai_ngc_read_pinned_version_file)"; then
                echo -e "${BLUE}Run:ai version from ${RUNAI_INSTALLER_DIR}/runai_version (NGC): ${pinned_ver}${NC}" >&2
                if ! runai_ngc_add_repo; then
                    return 1
                fi
                if ! log_command "helm repo update > /dev/null 2>&1" "Update Helm repos"; then
                    echo -e "${YELLOW}⚠️ Warning: Failed to update helm repos, continuing...${NC}"
                fi
                printf "%s" "$pinned_ver"
                return 0
            fi
            if ! runai_ngc_add_repo; then
                return 1
            fi
            ;;
        jfrog)
            if ! runai_jfrog_add_repo; then
                echo -e "${YELLOW}⚠️ Warning: Failed to add runai-backend helm repo, continuing...${NC}"
            fi
            ;;
    esac

    if ! log_command "helm repo update > /dev/null 2>&1" "Update Helm repos"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to update helm repos, continuing...${NC}"
    fi

    local latest_version=""
    if [ "${RUNAI_ARTIFACT_SOURCE:-jfrog}" = "ngc" ]; then
        latest_version=$(helm search repo runai/control-plane --output json 2>/dev/null | jq -r '[.[] | select(.name == "runai/control-plane")] | first | .version // empty' 2>/dev/null)
    else
        latest_version=$(helm search repo runai-backend --output json 2>/dev/null | jq -r '[.[] | select(.name == "runai-backend/control-plane")] | first | .version // empty' 2>/dev/null)
    fi
    
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        echo -e "${RED}❌ Error: Could not detect latest Run.ai version${NC}"
        return 1
    fi
    
    # Return only the version number (no echo to stdout)
    printf "%s" "$latest_version"
    return 0
}

# Function to show usage
show_usage() {
    echo -e "${BLUE}Usage: $0 [OPTIONS]${NC}"
    echo "Options:"
    echo "  --sanity [ARGS]        First option only: run only sanity-check/sanity-check.sh with ARGS; full log in logs/ (see logs/latest.log) like a full install"
    echo "  --dns DNS_NAME         global.domain (Run:ai FQDN). On OpenShift with --openshift, optional: defaults to runai.apps.<base> from the cluster if kubecontext can read dns/ingress"
    echo "  --runai-version VER    Run:ai version (use 'latest' to resolve from Helm; with --ngc, optional pin file ${RUNAI_INSTALLER_DIR}/runai_version)"
    echo "  --version VER          Alias for --runai-version (useful with --automatic)"
    echo "  --cluster-only         Skip backend installation and only install Run.ai cluster"
    echo "  --internal-dns         Configure internal DNS (requires --ip)"
    echo "  --ip IP_ADDRESS        Required if --internal-dns, --patch-nginx, or --patch-haproxy is set"
    echo "  --cert CERT_FILE       Use provided certificate file instead of generating self-signed"
    echo "  --key KEY_FILE         Use provided key file instead of generating self-signed"
    echo "  --cacert CA_CERT_FILE  Use provided CA certificate file (e.g., rootCA.pem)"
    echo "  --no-cert              Skip certificate setup (use existing certificates)"
    echo "  --knative              Install Knative serving"
    echo "  --nginx                Install Nginx Ingress Controller (no --ip needed)"
    echo "  --patch-nginx          Patch existing Nginx Ingress Controller with external IP (requires --ip)"
    echo "  --haproxy              Install HAProxy Kubernetes Ingress (HAProxyTech; NodePorts 32080/32443)"
    echo "  --patch-haproxy        Patch HAProxy Ingress service with external IP (requires --ip)"
    echo "  --use-haproxy          Control plane Helm: --set global.ingress.ingressClass=haproxy (required for vanilla K8s full install; not for --openshift)"
    echo "  --use-nginx            Control plane Helm: --set global.ingress.ingressClass=nginx (required for vanilla K8s full install; not for --openshift)"
    echo "  --openshift            Set global.config.kubernetesDistribution=openshift; set global.domain (default runai.apps.<base>, overridable with --dns); no haproxy/nginx class"
    echo "  --openshift-ingress-cacert FILE  Optional PEM: trust bundle for the OpenShift Route to Run:ai. Requires --openshift; has no effect on vanilla Kubernetes. With --openshift --no-cert, if omitted the installer reads openshift-ingress/router-ca or TLS-probes the Route hostname, then global.customCA (same as a manual file)."
    echo "  --ngc                  Use NVIDIA NGC for control-plane Helm chart (requires NGC API key)"
    echo "  --jfrog                Use JFrog for control-plane Helm chart (default if neither --ngc nor --jfrog)"
    echo "  --ngc-api-key KEY      NGC API key: Helm repo auth + docker-registry secret runai-reg-creds for nvcr.io (implies --ngc)"
    echo "                         (same as: kubectl create secret docker-registry runai-reg-creds --docker-server=https://nvcr.io"
    echo "                         --docker-username='\$oauthtoken' --docker-password=KEY --docker-email=test@run.ai -n runai-backend)"
    echo "                         Or export NGC_API_KEY and use: --ngc-api-key \"\$NGC_API_KEY\""
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
    echo "  --subdomain            Enable subdomain support with wildcard ingress"
    echo "  --install-only         Install prerequisites only (nginx, knative, lws, storage-class) without Run.ai"
    echo "  --automatic            Prep cluster, then full Run:ai; supports --dns (override sslip), --cert/--key/--cacert; requires --ngc-api-key (NGC) or --repo-secret (JFrog)"
    echo "  --automatic-chain      Legacy alias; same credential requirements as --automatic"
    echo "  --automatic-stop-after PHASE  Stop after: helm|nodes|prereqs|tests|hardware|haproxy|certs|tls|storage"
    echo "  -y, --yes              With --automatic: skip plan/install confirmations; with --uninstall: auto-confirm prompts"
    echo "  --ngc-key KEY|-        Set NGC API key for charts/images (implies --ngc). Use - to read key from stdin"
    echo "  --label NODES          Comma-separated list of node names to label for Run.ai system (e.g., server1,server2)"
    echo "  --uninstall            Uninstall Run.ai completely from the cluster"
    echo ""
    echo "Examples:"
    echo "  # Using sslip.io (automatic DNS resolution)"
    echo "  $0 --dns 192.168.0.100.sslip.io --runai-version 2.20.22 --use-nginx --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom domain with internal DNS"
    echo "  $0 --dns kirson.runai.lab --internal-dns --ip 172.21.140.20 --runai-version 2.20.22 --use-haproxy --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom certificates"
    echo "  $0 --dns kirson.rudnai.lab --runai-version 2.20.22 --use-nginx --cert /path/to/cert.pem --key /path/to/key.pem --repo-secret /root/jfrog"
    echo ""
    echo "  # Using custom certificates with CA cert"
    echo "  $0 --dns kirson.runai.lab --runai-version 2.20.22 --use-nginx --cert /path/to/cert.pem --key /path/to/key.pem --cacert /path/to/rootCA.pem --repo-secret /root/jfrog"
    echo ""
    echo "  # NGC (connected): chart + nvcr.io pull secret runai-reg-creds (pass key or set env NGC_API_KEY)"
    echo "  $0 --dns runai.example.com --runai-version 2.20.22 --use-haproxy --haproxy --ngc-api-key \"\$NGC_API_KEY\""
    echo "  # OpenShift (Routes): global.domain + kubernetesDistribution; optional --dns or derive runai.apps.<base> from cluster"
    echo "  $0 --openshift --no-cert --ngc --ngc-api-key \"\$NGC_API_KEY\" --runai-version 2.20.22"
    echo "  $0 --dns runai.apps.myocp.example.com --runai-version 2.20.22 --openshift --no-cert --openshift-ingress-cacert ./openshift-ingress-router-ca.pem --ngc --ngc-api-key \"\$NGC_API_KEY\""
    echo "  $0 --dns runai.apps.myocp.example.com --runai-version 2.20.22 --openshift --no-cert --ngc --ngc-api-key \"\$NGC_API_KEY\""
    echo ""
    echo "  # Automatic: prep + latest Run:ai + install missing stack (pass JFrog secret or NGC key)"
    echo "  $0 --automatic --yes --ngc-key \"\$NGC_API_KEY\""
    echo "  $0 --automatic --yes --ngc-key \"\$NGC_API_KEY\" --dns runai.example.com"
    echo "  # OpenShift: --automatic detects OCP, uses runai.apps.<baseDomain> and skips HAProxy (per NVIDIA docs)"
    echo ""
    echo "  # Installing with additional components (optional: --nginx / --haproxy to deploy an ingress controller)"
    echo "  $0 --dns 192.168.0.100.sslip.io --runai-version 2.20.22 --use-nginx --nginx --prometheus --gpu-operator --training --lws --install-sc --repo-secret /root/jfrog"
    echo ""
    echo "  # Patching existing Nginx installation (optional; --ip only needed for the patch)"
    echo "  $0 --dns 192.168.0.100.sslip.io --ip 192.168.0.214 --use-nginx --patch-nginx --repo-secret /root/jfrog"
    echo ""
    echo "  # Air-gapped installation (no --runai-version needed)"
    echo "  $0 --dns 192.168.0.100.sslip.io --use-nginx --air-gapped --file /path/to/runai-air-gapped.tar.gz --registry registry.example.com"
    echo "  # Air-gapped installation with skip-upload (images already in registry)"
    echo "  $0 --dns 192.168.0.100.sslip.io --use-haproxy --air-gapped --file /path/to/runai-air-gapped.tar.gz --registry registry.example.com --skip-upload"
    echo ""
    echo "  # Install prerequisites only (without Run.ai)"
    echo "  $0 --install-only --nginx --knative --lws --install-sc"
    echo ""
    echo "  # Label specific nodes for Run.ai"
    echo "  $0 --dns 192.168.0.100.sslip.io --runai-version 2.20.22 --use-nginx --label server1,server2 --repo-secret /root/jfrog"
    echo ""
    echo "  # Uninstall Run.ai completely"
    echo "  $0 --uninstall"
    echo "  $0 --uninstall -y"
    exit 1
}

# Function to validate required parameters
validate_params() {
    # Skip validation for uninstall mode or install-only mode
    if [ "$UNINSTALL" = true ] || [ "$INSTALL_ONLY" = true ]; then
        return 0
    fi
    
    # OpenShift: global.domain=runai.apps.<base> per Run:ai OCP install — optional --dns if the cluster is reachable.
    if [ "${RUNAI_K8S_DISTRIBUTION:-}" = "openshift" ] && [ -z "${DNS_NAME:-}" ] && [ "$AIR_GAPPED_MODE" != true ] && [ -f "${RUNAI_INSTALLER_DIR}/modules/openshift.sh" ]; then
        # shellcheck source=/dev/null
        . "${RUNAI_INSTALLER_DIR}/modules/openshift.sh"
        if ocdom=$(runai_openshift_default_runai_domain 2>/dev/null) && [ -n "$ocdom" ]; then
            DNS_NAME="$ocdom"
            echo -e "${GREEN}OpenShift: using --dns $DNS_NAME (from cluster: runai.apps.<baseDomain>)${NC}" >&2
        fi
    fi

    if [ -z "$DNS_NAME" ]; then
        echo -e "${RED}Error: --dns is required (on OpenShift: pass --openshift and a reachable kube; this installer can derive runai.apps.<baseDomain>)${NC}" >&2
        show_usage
    fi

    # Run.ai version is only required when not in air-gapped mode or install-only mode
    if [ "$AIR_GAPPED_MODE" != true ] && [ "$INSTALL_ONLY" != true ] && [ -z "$RUNAI_VERSION" ]; then
        echo -e "${RED}Error: --runai-version is required (unless using --air-gapped or --install-only mode)${NC}"
        show_usage
    fi

    # NGC/JFrog and API key must be validated before resolving --runai-version latest (Helm needs the key).
    if [ "${NGC_FLAG_COUNT:-0}" -gt 0 ] && [ "${JFROG_FLAG_COUNT:-0}" -gt 0 ]; then
        echo -e "${RED}Error: use only one of --ngc or --jfrog${NC}"
        show_usage
    fi

    if [ "${RUNAI_ARTIFACT_SOURCE:-jfrog}" = "ngc" ] && [ "$AIR_GAPPED_MODE" != true ] && [ "$INSTALL_ONLY" != true ] && [ -z "${NGC_API_KEY:-}" ]; then
        echo -e "${RED}Error: --ngc requires an NGC API key (pass --ngc-api-key or set env NGC_API_KEY)${NC}"
        show_usage
    fi
    
    # Handle "latest" version option
    if [ "$RUNAI_VERSION" = "latest" ]; then
        echo -e "${BLUE}Latest version requested, detecting latest available version...${NC}"
        RUNAI_VERSION=$(get_latest_runai_version)
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to detect latest version${NC}"
            exit 1
        fi
        # If any Helm noise leaked into stdout, keep only the first semver token.
        RUNAI_VERSION="$(printf '%s' "$RUNAI_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [ -z "$RUNAI_VERSION" ]; then
            echo -e "${RED}❌ Could not parse version from latest detection${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ Latest Run.ai version detected: $RUNAI_VERSION${NC}"
    fi

    if [ "$INTERNAL_DNS" = true ] && [ -z "$IP_ADDRESS" ]; then
        echo -e "${RED}Error: --ip is required when using --internal-dns${NC}"
        show_usage
    fi

    if [ "$PATCH_HAPROXY" = true ] && [ -z "$IP_ADDRESS" ]; then
        echo -e "${RED}Error: --ip is required when using --patch-haproxy${NC}"
        show_usage
    fi

    # Full Run.ai: ingress class haproxy|nginx on vanilla K8s; on OpenShift use platform Routes (no global.ingress.ingressClass).
    if [ -z "${RUNAI_INGRESS_CLASS:-}" ] && [ "${RUNAI_K8S_DISTRIBUTION:-}" != "openshift" ]; then
        echo -e "${RED}Error: pass --use-haproxy or --use-nginx (control plane global.ingress.ingressClass)${NC}" >&2
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

    if [ -n "${RUNAI_OCP_INGRESS_CACERT_FILE:-}" ]; then
        if [ ! -f "$RUNAI_OCP_INGRESS_CACERT_FILE" ]; then
            echo -e "${RED}Error: --openshift-ingress-cacert file not found: $RUNAI_OCP_INGRESS_CACERT_FILE${NC}" >&2
            show_usage
        fi
        if [ "${RUNAI_K8S_DISTRIBUTION:-}" != "openshift" ]; then
            echo -e "${RED}Error: --openshift-ingress-cacert requires --openshift${NC}" >&2
            show_usage
        fi
        if [ "${NO_CERT:-false}" != true ]; then
            echo -e "${RED}Error: --openshift-ingress-cacert is for --no-cert installs (OCP default router + cluster Helm customCA). Re-run with --no-cert, or use --cert --key --cacert instead of this flag.${NC}" >&2
            show_usage
        fi
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
    LOGS_DIR="$(pwd)/logs"
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
    export RUNAI_INGRESS_CLASS
    export NGC_API_KEY
    # kubernetes | openshift — sets Helm global.config.kubernetesDistribution
    export RUNAI_K8S_DISTRIBUTION="${RUNAI_K8S_DISTRIBUTION:-}"
    export RUNAI_INSTALLER_DIR
    export RUNAI_OCP_INGRESS_CACERT_FILE="${RUNAI_OCP_INGRESS_CACERT_FILE:-}"
    export RUNAI_OCP_NO_AUTO_INGRESS_CA="${RUNAI_OCP_NO_AUTO_INGRESS_CA:-false}"
    export RUNAI_INJECTED_OCP_CLUSTER_CA="${RUNAI_INJECTED_OCP_CLUSTER_CA:-0}"
    
    # Initialize boolean flags (only if not already set)
    UNINSTALL=${UNINSTALL:-false}
    CLUSTER_ONLY=${CLUSTER_ONLY:-false}
    INTERNAL_DNS=${INTERNAL_DNS:-false}
    NO_CERT=${NO_CERT:-false}
    INSTALL_KNATIVE=${INSTALL_KNATIVE:-false}
    INSTALL_NGINX=${INSTALL_NGINX:-false}
    PATCH_NGINX=${PATCH_NGINX:-false}
    INSTALL_HAPROXY=${INSTALL_HAPROXY:-false}
    PATCH_HAPROXY=${PATCH_HAPROXY:-false}
    RUNAI_ARTIFACT_SOURCE=${RUNAI_ARTIFACT_SOURCE:-jfrog}
    NGC_FLAG_COUNT=${NGC_FLAG_COUNT:-0}
    JFROG_FLAG_COUNT=${JFROG_FLAG_COUNT:-0}
    NGC_API_KEY=${NGC_API_KEY:-}
    # Normalize NGC key once (copy/paste quotes, CR/LF) so Helm and curl see the same value as kubectl secrets.
    if [ -n "${NGC_API_KEY:-}" ]; then
        NGC_API_KEY="$(printf '%s' "$NGC_API_KEY" | tr -d '\r\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^"//; s/"$//')"
        export NGC_API_KEY
    fi
    RUNAI_INGRESS_CLASS=${RUNAI_INGRESS_CLASS:-}
    INSTALL_PROMETHEUS=${INSTALL_PROMETHEUS:-false}
    INSTALL_GPU_OPERATOR=${INSTALL_GPU_OPERATOR:-false}
    INSTALL_TRAINING=${INSTALL_TRAINING:-false}
    INSTALL_LWS=${INSTALL_LWS:-false}
    INSTALL_STORAGE_CLASS=${INSTALL_STORAGE_CLASS:-false}
    BCM_CONFIG=${BCM_CONFIG:-false}
    AIR_GAPPED_MODE=${AIR_GAPPED_MODE:-false}
    SKIP_UPLOAD=${SKIP_UPLOAD:-false}
    SUBDOMAIN_SUPPORT=${SUBDOMAIN_SUPPORT:-false}
    INSTALL_ONLY=${INSTALL_ONLY:-false}
    AIR_GAPPED_FILE=${AIR_GAPPED_FILE:-}
    LABEL_NODES=${LABEL_NODES:-}
    AUTOMATIC_MODE=${AUTOMATIC_MODE:-false}
    AUTO_YES=${AUTO_YES:-false}
    AUTOMATIC_CHAIN=${AUTOMATIC_CHAIN:-false}
    AUTOMATIC_STOP_AFTER=${AUTOMATIC_STOP_AFTER:-}
    export AUTOMATIC_STOP_AFTER
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
        --version=*)
            RUNAI_VERSION="${1#*=}"
            shift
            ;;
        --version)
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
        --haproxy)
            INSTALL_HAPROXY=true
            shift
            ;;
        --patch-haproxy)
            PATCH_HAPROXY=true
            shift
            ;;
        --use-haproxy)
            if [ -n "${RUNAI_INGRESS_CLASS:-}" ] && [ "$RUNAI_INGRESS_CLASS" != "haproxy" ]; then
                echo -e "${RED}Error: cannot use both --use-haproxy and --use-nginx${NC}"
                exit 1
            fi
            RUNAI_INGRESS_CLASS=haproxy
            shift
            ;;
        --use-nginx)
            if [ -n "${RUNAI_INGRESS_CLASS:-}" ] && [ "$RUNAI_INGRESS_CLASS" != "nginx" ]; then
                echo -e "${RED}Error: cannot use both --use-haproxy and --use-nginx${NC}"
                exit 1
            fi
            RUNAI_INGRESS_CLASS=nginx
            shift
            ;;
        --ngc)
            RUNAI_ARTIFACT_SOURCE=ngc
            NGC_FLAG_COUNT=$(( ${NGC_FLAG_COUNT:-0} + 1 ))
            shift
            ;;
        --jfrog)
            RUNAI_ARTIFACT_SOURCE=jfrog
            JFROG_FLAG_COUNT=$(( ${JFROG_FLAG_COUNT:-0} + 1 ))
            shift
            ;;
        --ngc-api-key=*)
            NGC_API_KEY="${1#*=}"
            RUNAI_ARTIFACT_SOURCE=ngc
            NGC_FLAG_COUNT=$(( ${NGC_FLAG_COUNT:-0} + 1 ))
            shift
            ;;
        --ngc-api-key)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: --ngc-api-key requires a value (e.g. --ngc-api-key \"\$NGC_API_KEY\")${NC}"
                show_usage
            fi
            NGC_API_KEY="$2"
            RUNAI_ARTIFACT_SOURCE=ngc
            NGC_FLAG_COUNT=$(( ${NGC_FLAG_COUNT:-0} + 1 ))
            shift 2
            ;;
        --ngc-key=*)
            NGC_API_KEY="${1#*=}"
            RUNAI_ARTIFACT_SOURCE=ngc
            NGC_FLAG_COUNT=$(( ${NGC_FLAG_COUNT:-0} + 1 ))
            shift
            ;;
        --ngc-key)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: --ngc-key requires a value or - (stdin)${NC}"
                show_usage
            fi
            if [ "$2" = "-" ]; then
                NGC_API_KEY=$(cat)
            else
                NGC_API_KEY="$2"
            fi
            RUNAI_ARTIFACT_SOURCE=ngc
            NGC_FLAG_COUNT=$(( ${NGC_FLAG_COUNT:-0} + 1 ))
            shift 2
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
        --subdomain)
            SUBDOMAIN_SUPPORT=true
            shift
            ;;
        --install-only)
            INSTALL_ONLY=true
            shift
            ;;
        --automatic)
            AUTOMATIC_MODE=true
            shift
            ;;
        --automatic-chain)
            AUTOMATIC_CHAIN=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        --openshift)
            RUNAI_K8S_DISTRIBUTION=openshift
            shift
            ;;
        --openshift-ingress-cacert)
            RUNAI_OCP_INGRESS_CACERT_FILE="$2"
            if [ ! -f "$RUNAI_OCP_INGRESS_CACERT_FILE" ]; then
                echo -e "${RED}❌ File not found: $2${NC}" >&2
                exit 1
            fi
            shift 2
            ;;
        --automatic-stop-after)
            AUTOMATIC_STOP_AFTER="$2"
            shift 2
            ;;
        --label)
            LABEL_NODES="$2"
            shift 2
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

# Embedded sanity: full trace in LOG_FILE and logs/latest.log (must be first flag: --sanity)
if [ "${SANITY_ONLY:-0}" = 1 ]; then
    echo -e "${BLUE}Running sanity-check (unified with installation log)${NC}"
    echo "  $LOG_FILE"
    ( cd "$RUNAI_INSTALLER_DIR/sanity-check" && \
        env RUNAI_SANITY_UNIFIED_LOG_FILE="${LOG_FILE}" \
        bash ./sanity-check.sh "${SANITY_PASSTHRU[@]}"
    ) || exit 1
    echo -e "${GREEN}Also: tail -f $LOGS_DIR/latest.log${NC}"
    exit 0
fi

# Handle uninstall if requested (before validation)
if [ "$UNINSTALL" = true ]; then
    echo -e "${BLUE}Uninstall mode requested...${NC}"
    
    # Check if the original uninstall script exists
    if [ -f "./sanity-check/full-runai-delete.sh" ]; then
        echo -e "${BLUE}Running full Run.ai uninstall script...${NC}"
        if [ "${AUTO_YES:-false}" = true ]; then
            RUNAI_AUTO_YES=true bash ./sanity-check/full-runai-delete.sh --yes
        else
            bash ./sanity-check/full-runai-delete.sh
        fi
        exit $?
    else
        echo -e "${RED}❌ Error: Full uninstall script not found at ./sanity-check/full-runai-delete.sh${NC}"
        exit 1
    fi
fi

# Opinionated automatic cluster prep (exits when finished)
if [ "${AUTOMATIC_MODE:-false}" = true ]; then
    if [ -n "${NGC_API_KEY:-}" ]; then
        export RUNAI_ARTIFACT_SOURCE=ngc
    elif [ -n "${REPO_SECRET:-}" ] && [ -f "${REPO_SECRET}" ]; then
        export RUNAI_ARTIFACT_SOURCE=jfrog
    else
        echo -e "${RED}❌ --automatic requires credentials:${NC}" >&2
        echo -e "  ${BLUE}--ngc-api-key${NC} / ${BLUE}NGC_API_KEY${NC} (NGC), or ${BLUE}--repo-secret FILE${NC} (JFrog)" >&2
        exit 1
    fi

    REPO_ROOT="$RUNAI_INSTALLER_DIR"
    if [ ! -f "$RUNAI_INSTALLER_DIR/modules/automatic.sh" ]; then
        echo -e "${RED}❌ modules/automatic.sh not found under $RUNAI_INSTALLER_DIR${NC}" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$RUNAI_INSTALLER_DIR/modules/automatic.sh"
    if ! declare -F run_automatic_mode >/dev/null 2>&1; then
        echo -e "${RED}❌ run_automatic_mode missing after sourcing modules/automatic.sh (check script for errors).${NC}" >&2
        exit 1
    fi
    if ! run_automatic_mode; then
        exit 1
    fi
    exit 0
fi

# Validate parameters (only if not uninstalling)
validate_params

# Create namespaces first (skip if install-only mode)
if [ "$INSTALL_ONLY" != true ]; then
    echo -e "${BLUE}Creating namespaces...${NC}"
    kubectl create namespace runai 2>/dev/null || true
    kubectl create namespace runai-backend 2>/dev/null || true
    echo -e "${GREEN}✅ Namespaces created${NC}"
fi

# Source and execute modules based on configuration
source ./modules/log.sh
init_logging

source ./modules/helm.sh
check_helm_version

# Only setup certificates if not in air-gapped mode or install-only mode
if [ "$AIR_GAPPED_MODE" != true ] && [ "$INSTALL_ONLY" != true ]; then
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
    if ! install_nginx; then
        echo -e "${RED}❌ Nginx installation failed${NC}"
        exit 1
    fi
elif [ "$PATCH_NGINX" = true ]; then
    if ! patch_nginx_service; then
        echo -e "${RED}❌ Nginx patch failed${NC}"
        exit 1
    fi
fi

source ./modules/haproxy.sh
if [ "$INSTALL_HAPROXY" = true ]; then
    if ! install_haproxy; then
        echo -e "${RED}❌ HAProxy installation failed${NC}"
        exit 1
    fi
elif [ "$PATCH_HAPROXY" = true ]; then
    if ! patch_haproxy_service; then
        echo -e "${RED}❌ HAProxy patch failed${NC}"
        exit 1
    fi
fi

source ./modules/prerequisites.sh
if [ "$INSTALL_PROMETHEUS" = true ]; then
    if ! install_prometheus; then
        echo -e "${RED}❌ Prometheus installation failed${NC}"
        exit 1
    fi
fi

if [ "$INSTALL_GPU_OPERATOR" = true ]; then
    if ! install_gpu_operator; then
        echo -e "${RED}❌ GPU Operator installation failed${NC}"
        exit 1
    fi
fi

source ./modules/training.sh
if [ "$INSTALL_TRAINING" = true ]; then
    if ! install_training_operator; then
        echo -e "${RED}❌ Training Operator installation failed${NC}"
        exit 1
    fi
fi

source ./modules/lws.sh
if [ "$INSTALL_LWS" = true ]; then
    if ! install_lws; then
        echo -e "${RED}❌ LWS installation failed${NC}"
        exit 1
    fi
fi

source ./modules/storage-class.sh
if [ "$INSTALL_STORAGE_CLASS" = true ]; then
    if ! install_storage_class; then
        echo -e "${RED}❌ StorageClass installation failed${NC}"
        exit 1
    fi
fi

source ./modules/knative.sh
if [ "$INSTALL_KNATIVE" = true ]; then
    if ! install_knative; then
        echo -e "${RED}❌ Knative installation failed${NC}"
        exit 1
    fi
fi

# Skip Run.ai installation if --install-only is set
if [ "$INSTALL_ONLY" = true ]; then
    # Nested calls from --automatic (HAProxy, Prometheus, etc.) are --install-only; avoid looking like the full run skipped Run.ai.
    if [ "${RUNAI_SUBINSTALLER:-false}" = true ]; then
        echo -e "${GREEN}✅ Prerequisite step completed (--install-only).${NC}"
    else
        echo -e "${BLUE}Install-only mode: Skipping Run.ai installation${NC}"
        echo -e "${BLUE}Only prerequisites will be installed${NC}"
    fi
else
    # Handle Run.ai node labeling before any installations
    echo -e "${BLUE}Configuring Run.ai node roles...${NC}"
    if [ -f "./modules/node-labeling.sh" ]; then
        source ./modules/node-labeling.sh
        if handle_runai_node_labeling "$LABEL_NODES"; then
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
        if [ ! -r "./modules/runai.sh" ]; then
            echo -e "${RED}❌ modules/runai.sh not found or not readable${NC}"
            exit 1
        fi
        # Strip CR (Windows) so function names are not broken.
        _runai_mod="$(mktemp "${TMPDIR:-/tmp}/runai-installer-runai.XXXXXX")" || exit 1
        sed 's/\r$//' ./modules/runai.sh >"$_runai_mod" || { rm -f "$_runai_mod"; exit 1; }
        # shellcheck source=/dev/null
        source "$_runai_mod" || { rm -f "$_runai_mod"; echo -e "${RED}❌ Failed to load modules/runai.sh${NC}"; exit 1; }
        rm -f "$_runai_mod"
        if ! declare -F install_runai >/dev/null 2>&1; then
            echo -e "${RED}❌ install_runai is not defined after loading modules/runai.sh.${NC}"
            echo -e "${YELLOW}On Windows editors: run dos2unix modules/runai.sh or save with LF line endings.${NC}"
            echo -e "${YELLOW}Confirm modules/runai.sh is complete, not truncated.${NC}"
            exit 1
        fi
        install_runai
    fi

    # Handle subdomain support if requested
    if [ "$SUBDOMAIN_SUPPORT" = true ]; then
        echo -e "${BLUE}Setting up subdomain support...${NC}"
        source ./modules/subdomain.sh
        if handle_subdomain_support; then
            echo -e "${GREEN}✅ Subdomain support setup completed successfully${NC}"
        else
            echo -e "${RED}❌ Subdomain support setup failed${NC}"
            echo -e "${YELLOW}Please check the logs at $LOG_FILE for details${NC}"
        fi
    fi
fi

# Display configuration summary (log-only; keep terminal output focused on actionable steps).
{
    echo ""
    echo "==== Configuration Summary ===="
    echo "DNS: $([ "$INTERNAL_DNS" = true ] && echo "Yes" || echo "No")"
    echo "Install Nginx: $([ "$INSTALL_NGINX" = true ] && echo "Yes" || echo "No")"
    echo "Patch Nginx: $([ "$PATCH_NGINX" = true ] && echo "Yes" || echo "No")"
    echo "Install HAProxy Ingress: $([ "$INSTALL_HAPROXY" = true ] && echo "Yes" || echo "No")"
    echo "Patch HAProxy Ingress: $([ "$PATCH_HAPROXY" = true ] && echo "Yes" || echo "No")"
    echo "Control-plane chart source: ${RUNAI_ARTIFACT_SOURCE:-jfrog}"
    if [ "${RUNAI_ARTIFACT_SOURCE:-jfrog}" = ngc ]; then
        echo "NGC API key (Helm + runai-reg-creds): $([ -n "${NGC_API_KEY:-}" ] && echo "set" || echo "not set")"
    fi
    if [ "${RUNAI_K8S_DISTRIBUTION:-}" = "openshift" ]; then
        echo "Control-plane: OpenShift (global.ingress.ingressClass not set; platform Routes)${RUNAI_INGRESS_CLASS:+; override: $RUNAI_INGRESS_CLASS}"
    else
        echo "Control-plane ingress class (--use-haproxy / --use-nginx): ${RUNAI_INGRESS_CLASS:-not set}"
    fi
    echo "Install Prometheus: $([ "$INSTALL_PROMETHEUS" = true ] && echo "Yes" || echo "No")"
    echo "Install GPU Operator: $([ "$INSTALL_GPU_OPERATOR" = true ] && echo "Yes" || echo "No")"
    echo "Install Training Operator: $([ "$INSTALL_TRAINING" = true ] && echo "Yes" || echo "No")"
    echo "Install LWS: $([ "$INSTALL_LWS" = true ] && echo "Yes" || echo "No")"
    echo "Install Storage Class: $([ "$INSTALL_STORAGE_CLASS" = true ] && echo "Yes" || echo "No")"
    echo "Install Knative: $([ "$INSTALL_KNATIVE" = true ] && echo "Yes" || echo "No")"
    echo "Skip Certificate Setup: $([ "$NO_CERT" = true ] && echo "Yes" || echo "No")"
    if [ -n "${RUNAI_OCP_INGRESS_CACERT_FILE:-}" ]; then
        echo "OpenShift route TLS / router CA (runai cluster Helm, customCA): $RUNAI_OCP_INGRESS_CACERT_FILE"
    fi
    echo "Custom Certificates: $([ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && echo "Yes" || echo "No")"
    echo "Repository Secret: $([ -n "$REPO_SECRET" ] && echo "$REPO_SECRET" || echo "None")"
    echo "BCM Configuration: $([ "$BCM_CONFIG" = true ] && echo "Yes" || echo "No")"
    echo "Subdomain Support: $([ "$SUBDOMAIN_SUPPORT" = true ] && echo "Yes" || echo "No")"
    echo "Air-gapped Mode: $([ "$AIR_GAPPED_MODE" = true ] && echo "Yes" || echo "No")"
    if [ "$AIR_GAPPED_MODE" = true ]; then
        echo "Air-gapped File: $([ -n "$AIR_GAPPED_FILE" ] && echo "$AIR_GAPPED_FILE" || echo "None")"
        echo "Registry URL: $([ -n "$REGISTRY_URL" ] && echo "$REGISTRY_URL" || echo "None")"
        echo "Registry Secret: $([ -n "$REGISTRY_SECRET_FILE" ] && echo "$REGISTRY_SECRET_FILE" || echo "None")"
        echo "Skip Upload: $([ "$SKIP_UPLOAD" = true ] && echo "Yes" || echo "No")"
    fi
} >> "$LOG_FILE"

# Final success message
if [ "$INSTALL_ONLY" = true ]; then
    # Simple message for prerequisites-only installation
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                                       ║${NC}"
    echo -e "${GREEN}║         Prerequisites Installation Completed Successfully!            ║${NC}"
    echo -e "${GREEN}║                                                                       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${BLUE}Installed components:${NC}"
    [ "$INSTALL_NGINX" = true ] && echo -e "  ${GREEN}✅ Nginx Ingress Controller${NC}"
    [ "$INSTALL_HAPROXY" = true ] && echo -e "  ${GREEN}✅ HAProxy Kubernetes Ingress${NC}"
    [ "$INSTALL_KNATIVE" = true ] && echo -e "  ${GREEN}✅ Knative Serving${NC}"
    [ "$INSTALL_LWS" = true ] && echo -e "  ${GREEN}✅ LWS${NC}"
    [ "$INSTALL_TRAINING" = true ] && echo -e "  ${GREEN}✅ Kubeflow Training Operator${NC}"
    echo
else
    # Full Run.ai installation message
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                                       ║${NC}"
    echo -e "${GREEN}║              Run.ai Installation Completed Successfully!              ║${NC}"
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
fi

echo -e "${BLUE}Thank you for using the AI Factory One-Click Installer!${NC}" 


