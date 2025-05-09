#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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
    echo "  # Installing with additional components"
    echo "  $0 --dns 192.168.0.100.sslip.io --runai-version 2.20.22 --nginx --prometheus --gpu-operator --repo-secret /root/jfrog"
    echo ""
    echo "  # Patching existing Nginx installation"
    echo "  $0 --dns 192.168.0.100.sslip.io --ip 192.168.0.214 --patch-nginx --repo-secret /root/jfrog"
    exit 1
}

# Variables
DNS_NAME=""
RUNAI_VERSION=""
RUNAI_ONLY=false
CLUSTER_ONLY=false
INTERNAL_DNS=false
IP_ADDRESS=""
CERT_FILE=""
KEY_FILE=""
NO_CERT=false
INSTALL_KNATIVE=false
INSTALL_NGINX=false
INSTALL_PROMETHEUS=false
INSTALL_GPU_OPERATOR=false
PATCH_NGINX=false
REPO_SECRET=""
BCM_CONFIG=false
TEMP_DIR="/tmp"

# Add at the beginning of the script
CURRENT_OPERATION="Starting installation"

# Create logs directory
LOGS_DIR="./logs"
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/installation_$(date +%Y%m%d_%H%M%S).log"
echo "Installation started at $(date)" > "$LOG_FILE"

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

# Function to check Helm version
check_helm_version() {
    echo -e "${BLUE}Checking Helm version...${NC}"
    
    # Check if Helm is installed
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}❌ Helm is not installed. Please install Helm first.${NC}"
        exit 1
    fi
    
    # Get Helm version
    HELM_VERSION=$(helm version --short | cut -d'v' -f2 | cut -d'.' -f1,2)
    REQUIRED_VERSION="3.14"
    
    # Compare versions
    if [ $(echo "$HELM_VERSION < $REQUIRED_VERSION" | bc -l) -eq 1 ]; then
        echo -e "${RED}❌ Helm version $HELM_VERSION is too old. Required version is at least $REQUIRED_VERSION${NC}"
        echo -e "${YELLOW}Please upgrade Helm using: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ Helm version $HELM_VERSION meets the minimum requirement of $REQUIRED_VERSION${NC}"
    fi
}

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
        --runai-only)
            RUNAI_ONLY=true
            shift
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

# Validate required parameters
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

# Display summary
echo -e "\n${GREEN}"
cat << "EOF"
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
echo -e "Run.ai Only: $([ "$RUNAI_ONLY" = true ] && echo "Yes" || echo "No")"
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

echo -e "\n${BLUE}Starting installation...${NC}"

# Function to check if Run.ai is already installed
check_runai_installed() {
    echo -e "${BLUE}Checking if Run.ai is already installed...${NC}"
    
    # If in cluster-only mode, only check for runai cluster component
    if [ "$CLUSTER_ONLY" = true ]; then
        if helm list -n runai | grep -q "runai"; then
            echo -e "${YELLOW}⚠️ Warning: Run.ai cluster component appears to be already installed.${NC}"
            echo -e "${YELLOW}Helm releases found:${NC}"
            helm list -n runai | grep "runai"
            
            echo -e "\n${YELLOW}Do you want to continue with the installation? This might overwrite existing configuration.${NC}"
            echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort...${NC}"
            read
        else
            echo -e "${GREEN}✅ No existing Run.ai cluster installation detected.${NC}"
        fi
        return
    fi
    
    # Regular check for both components
    if helm list -A | grep -q "runai"; then
        echo -e "${YELLOW}⚠️ Warning: Run.ai appears to be already installed on this cluster.${NC}"
        echo -e "${YELLOW}Helm releases found:${NC}"
        helm list -A | grep "runai"
        
        echo -e "\n${YELLOW}Do you want to continue with the installation? This might overwrite existing configuration.${NC}"
        echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort...${NC}"
        read
    else
        echo -e "${GREEN}✅ No existing Run.ai installation detected.${NC}"
    fi
}

# Function to patch CoreDNS if internal DNS is enabled
patch_coredns() {
    echo -e "${BLUE}Patching CoreDNS to add $DNS_NAME -> $IP_ADDRESS${NC}"

    # First check if the DNS entry already exists
    if ! log_command "kubectl get cm coredns -n kube-system -o yaml" "Check CoreDNS ConfigMap"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to get CoreDNS ConfigMap${NC}"
        return 1
    fi

    # Get current Corefile
    CURRENT_COREFILE=$(kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}')
    
    # Check if our DNS entry already exists
    if echo "$CURRENT_COREFILE" | grep -q "$DNS_NAME"; then
        echo -e "${BLUE}DNS entry for $DNS_NAME already exists, updating IP address${NC}"
        # Replace the IP address for the existing entry
        NEW_COREFILE=$(echo "$CURRENT_COREFILE" | sed -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ $DNS_NAME/$IP_ADDRESS $DNS_NAME/g")
        
        # Create a temporary file with the new Corefile
        TEMP_COREFILE="${TEMP_DIR}/corefile.tmp"
        echo "$NEW_COREFILE" > "$TEMP_COREFILE"
        
        echo -e "${BLUE}New CoreDNS configuration:${NC}"
        if ! log_command "cat \"$TEMP_COREFILE\"" "New CoreDNS configuration"; then
            echo -e "${YELLOW}⚠️ Warning: Could not log new CoreDNS configuration${NC}"
        fi
        
        # Apply the updated ConfigMap
        if ! log_command "kubectl create configmap coredns -n kube-system --from-file=Corefile=\"$TEMP_COREFILE\" --dry-run=client -o yaml | kubectl apply -f -" "Update CoreDNS ConfigMap"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to update CoreDNS ConfigMap${NC}"
            return 1
        fi
    else
        echo -e "${BLUE}No DNS entry found, applying complete Corefile patch${NC}"
        
        # Apply the patch with the new DNS entry
        PATCH_DATA="
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf {
          prefer_udp
          max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
        hosts {
          $IP_ADDRESS $DNS_NAME
          fallthrough
        }
    }
"
        
        # Log the patch data
        echo -e "${BLUE}Applying CoreDNS patch:${NC}"
        echo "$PATCH_DATA" > "${TEMP_DIR}/coredns-patch.yaml"
        if ! log_command "cat \"${TEMP_DIR}/coredns-patch.yaml\"" "CoreDNS patch data"; then
            echo -e "${YELLOW}⚠️ Warning: Could not log CoreDNS patch data${NC}"
        fi
        
        # Apply the patch
        if ! log_command "kubectl patch cm coredns -n kube-system --type='merge' --patch=\"$PATCH_DATA\"" "Patch CoreDNS ConfigMap"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to patch CoreDNS ConfigMap${NC}"
            return 1
        fi
    fi

    # Restart CoreDNS to apply the changes
    echo -e "${BLUE}Restarting CoreDNS...${NC}"
    if ! log_command "kubectl -n kube-system delete pod -l k8s-app=kube-dns" "Restart CoreDNS pods"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to restart CoreDNS pods, continuing...${NC}"
        return 1
    fi

    # Wait for CoreDNS pods to be ready
    echo -e "${BLUE}Waiting for CoreDNS pods to be ready...${NC}"
    if ! log_command "kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=60s" "Wait for CoreDNS pods"; then
        echo -e "${YELLOW}⚠️ Warning: Timeout waiting for CoreDNS pods to be ready, continuing...${NC}"
    fi

    # Verify DNS resolution
    echo -e "${BLUE}Verifying DNS resolution...${NC}"
    
    # Create a temporary file to store nslookup output
    NSLOOKUP_OUTPUT="${TEMP_DIR}/nslookup_output.txt"
    
    echo "Running DNS test for $DNS_NAME..." >> "$LOG_FILE"
    
    # Run the test pod with nslookup and capture output
    kubectl run dns-test --rm -i --restart=Never --image=busybox -- nslookup $DNS_NAME > "$NSLOOKUP_OUTPUT" 2>&1
    
    # Log the complete nslookup output
    echo "DNS test output:" >> "$LOG_FILE"
    cat "$NSLOOKUP_OUTPUT" >> "$LOG_FILE"
    
    # Check if nslookup output contains any error messages
    if grep -q "can't resolve" "$NSLOOKUP_OUTPUT"; then
        echo -e "${RED}❌ DNS resolution failed - domain cannot be resolved${NC}"
        echo "DNS resolution failed - domain cannot be resolved" >> "$LOG_FILE"
        cat "$NSLOOKUP_OUTPUT"
    else
        # DNS resolution completed, check if we got an answer
        if grep -q "Address:" "$NSLOOKUP_OUTPUT"; then
            echo -e "${GREEN}✅ DNS resolution test successful${NC}"
            echo "DNS resolution test successful" >> "$LOG_FILE"
            
            # Log the resolved IP address
            RESOLVED_IP=$(grep "Address:" "$NSLOOKUP_OUTPUT" | tail -n1 | awk '{print $2}')
            echo "Resolved IP: $RESOLVED_IP" >> "$LOG_FILE"
            
            if [ -n "$IP_ADDRESS" ] && [ "$RESOLVED_IP" != "$IP_ADDRESS" ]; then
                echo "Warning: Resolved IP ($RESOLVED_IP) does not match configured IP ($IP_ADDRESS)" >> "$LOG_FILE"
            fi
        else
            echo -e "${YELLOW}⚠️ Warning: Unexpected nslookup output format${NC}"
            echo "Warning: Unexpected nslookup output format" >> "$LOG_FILE"
            cat "$NSLOOKUP_OUTPUT" >> "$LOG_FILE"
        fi
    fi
    
    # Cleanup temporary file
    rm -f "$NSLOOKUP_OUTPUT"

    echo -e "${GREEN}✅ CoreDNS updated with $DNS_NAME -> $IP_ADDRESS${NC}"
    echo "CoreDNS update completed for $DNS_NAME -> $IP_ADDRESS" >> "$LOG_FILE"
    return 0
}

# Function to patch Nginx Ingress Controller service
patch_nginx_service() {
    echo -e "${BLUE}Patching Nginx Ingress Controller service with IP: $IP_ADDRESS${NC}"
    
    # First, check if the service exists
    if ! kubectl get svc -n ingress-nginx ingress-nginx-controller &> /dev/null; then
        echo -e "${YELLOW}⚠️ Warning: Nginx Ingress Controller service not found${NC}"
        return 1
    fi
    
    # Check if the externalIP is already set to our IP
    CURRENT_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
    if [ "$CURRENT_IP" = "$IP_ADDRESS" ]; then
        echo -e "${GREEN}✅ Nginx Ingress Controller already has the correct externalIP: $IP_ADDRESS${NC}"
        return 0
    fi
    
    # Simple direct patch
    if ! log_command "kubectl -n ingress-nginx patch svc ingress-nginx-controller --type='merge' -p \"{\\\"spec\\\":{\\\"externalIPs\\\":[\\\"$IP_ADDRESS\\\"]}}\"" "Patch Nginx Ingress Controller service"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to patch Nginx Ingress service, you may need to manually set externalIPs to $IP_ADDRESS${NC}"
        return 1
    fi
}

# Function to install Knative
install_knative() {
    echo -e "${BLUE}Installing Knative (optional component)...${NC}"
    if ! log_command "kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.17.0/serving-crds.yaml" "Install Knative CRDs"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Knative CRDs, continuing...${NC}"
    fi
    if ! log_command "kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.17.0/serving-core.yaml" "Install Knative Core"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Knative Core, continuing...${NC}"
    fi
    if ! log_command "kubectl apply -f https://github.com/knative/net-kourier/releases/download/knative-v1.17.0/kourier.yaml" "Install Knative Kourier"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install Kourier, continuing...${NC}"
    fi
    if ! kubectl patch configmap/config-network \
        --namespace knative-serving \
        --type merge \
        --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}' > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Warning: Failed to configure Knative networking, continuing...${NC}"
    fi

    # Configure autoscaler and features
    echo -e "${BLUE}Configuring Knative autoscaler and features...${NC}"
    if ! log_command "kubectl patch configmap/config-autoscaler \
        --namespace knative-serving \
        --type merge \
        --patch '{\"data\":{\"enable-scale-to-zero\":\"true\"}}'" "Configure Knative autoscaler"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to configure Knative autoscaler${NC}"
    fi

    if ! log_command "kubectl patch configmap/config-features \
        --namespace knative-serving \
        --type merge \
        --patch '{\"data\":{\"kubernetes.podspec-schedulername\":\"enabled\",\"kubernetes.podspec-affinity\":\"enabled\",\"kubernetes.podspec-tolerations\":\"enabled\",\"kubernetes.podspec-volumes-emptydir\":\"enabled\",\"kubernetes.podspec-securitycontext\":\"enabled\",\"kubernetes.containerspec-addcapabilities\":\"enabled\",\"kubernetes.podspec-persistent-volume-claim\":\"enabled\",\"kubernetes.podspec-persistent-volume-write\":\"enabled\",\"multi-container\":\"enabled\",\"kubernetes.podspec-init-containers\":\"enabled\"}}'" "Configure Knative features"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to configure Knative features${NC}"
    fi

    echo -e "${GREEN}✅ Knative installation completed${NC}"
}

# Function to install prerequisites if not in runai-only mode
install_prerequisites() {
    # Check if Kubernetes is already installed
    if ! kubectl get nodes &> /dev/null; then
        echo -e "${RED}❌ Kubernetes cluster not found. Please install Kubernetes first or use --runai-only with an existing cluster.${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Installing prerequisites...${NC}"
    
    # Check if Nginx Ingress should be installed
    if [ "$INSTALL_NGINX" = true ]; then
        # Check if Nginx Ingress is already installed
        if kubectl get ns ingress-nginx &> /dev/null && kubectl get svc -n ingress-nginx ingress-nginx-controller &> /dev/null; then
            echo -e "${BLUE}Nginx Ingress Controller already installed.${NC}"
            if [ -n "$IP_ADDRESS" ]; then
                patch_nginx_service
            fi
        else
            # Install Nginx Ingress Controller
            echo -e "${BLUE}Installing Nginx Ingress Controller...${NC}"
            if ! log_command "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx" "Add Nginx Ingress Helm repo"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to add nginx helm repo, continuing...${NC}"
            fi
            
            if ! log_command "helm repo update" "Update Helm repos"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to update helm repos, continuing...${NC}"
            fi
            
            if ! log_command "helm upgrade -i nginx-ingress ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace --set controller.kind=DaemonSet --set controller.service.externalIPs=\"{$IP_ADDRESS}\"" "Install Nginx Ingress Controller"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to install nginx ingress, continuing...${NC}"
            else
                echo -e "${GREEN}✅ Nginx Ingress Controller installed successfully!${NC}"
                
                # Double-check that externalIPs is set correctly
                if [ -n "$IP_ADDRESS" ] && ! kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.externalIPs[0]}' | grep -q "$IP_ADDRESS"; then
                    echo -e "${YELLOW}⚠️ Warning: externalIPs not set correctly during installation, attempting to patch...${NC}"
                    patch_nginx_service
                fi
            fi
        fi
    else
        echo -e "${BLUE}Skipping Nginx Ingress Controller installation (--nginx flag not set)${NC}"
    fi
    
    # Check if Prometheus should be installed
    if [ "$INSTALL_PROMETHEUS" = true ]; then
        # Check if Prometheus is already installed
        if kubectl get ns monitoring &> /dev/null && kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus &> /dev/null; then
            echo -e "${BLUE}Prometheus Stack already installed.${NC}"
        else
            # Install Prometheus Stack
            echo -e "${BLUE}Installing Prometheus Stack...${NC}"
            if ! log_command "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts" "Add Prometheus Helm repo"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to add prometheus helm repo, continuing...${NC}"
            fi
            
            if ! log_command "helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace --set grafana.enabled=false" "Install Prometheus Stack"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to install prometheus stack, continuing...${NC}"
            else
                echo -e "${GREEN}✅ Prometheus Stack installed successfully!${NC}"
            fi
        fi
    else
        echo -e "${BLUE}Skipping Prometheus Stack installation (--prometheus flag not set)${NC}"
    fi
    
    # Check if GPU Operator should be installed
    if [ "$INSTALL_GPU_OPERATOR" = true ]; then
        # Check if GPU Operator is already installed
        if kubectl get ns gpu-operator &> /dev/null; then
            echo -e "${BLUE}NVIDIA GPU Operator already installed.${NC}"
        else
            # Install NVIDIA GPU Operator
            echo -e "${BLUE}Installing NVIDIA GPU Operator...${NC}"
            if ! log_command "helm repo add nvidia https://helm.ngc.nvidia.com/nvidia" "Add NVIDIA Helm repo"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to add NVIDIA helm repo, continuing...${NC}"
            fi
            
            if ! log_command "helm install --wait --generate-name -n gpu-operator --create-namespace nvidia/gpu-operator" "Install NVIDIA GPU Operator"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to install NVIDIA GPU operator, continuing...${NC}"
            else
                echo -e "${GREEN}✅ NVIDIA GPU Operator installed successfully!${NC}"
            fi
        fi
    else
        echo -e "${BLUE}Skipping NVIDIA GPU Operator installation (--gpu-operator flag not set)${NC}"
    fi
    
    # Check if local-path-storage is already installed
    if kubectl get ns local-path-storage &> /dev/null; then
        echo -e "${BLUE}Patching local-path-config ConfigMap...${NC}"
        kubectl -n local-path-storage patch cm local-path-config --type='merge' --patch='
        data:
          helperPod.yaml: |-
            apiVersion: v1
            kind: Pod
            metadata:
              name: helper-pod
            spec:
              containers:
              - name: helper-pod
                image: "docker.io/library/busybox:latest"
                imagePullPolicy: IfNotPresent
        ' 2>/dev/null || echo -e "${YELLOW}⚠️ Warning: Failed to patch local-path-config, continuing...${NC}"

        # Delete all pods in local-path-storage namespace
        echo -e "${BLUE}Deleting all pods in local-path-storage namespace to apply changes...${NC}"
        kubectl -n local-path-storage delete pods --all --force 2>/dev/null || echo -e "${YELLOW}⚠️ Warning: Failed to restart local-path-storage pods, continuing...${NC}"
    fi

    echo -e "${GREEN}✅ Prerequisites installation completed!${NC}"
}

# Function to generate or use provided certificates
setup_certificates() {
    # Create certificates directory with timestamp
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CERT_DIR="./certificates"
    CERTS_BACKUP_DIR="$CERT_DIR/certs-$TIMESTAMP"
    CURRENT_DIR="$(pwd)"
    
    # Check if user provided certificates
    if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
        echo -e "${BLUE}Using provided certificate and key files...${NC}"
        
        # Create backup directory
        mkdir -p "$CERTS_BACKUP_DIR"
        
        # Set certificate paths to the original files
        export CERT="$CERT_FILE"
        export KEY="$KEY_FILE"
        export FULL="$CERT_FILE"  # Use the provided certificate as the full chain
        
        # Backup the certificates (don't create secrets here)
        echo -e "${BLUE}Backing up certificates to $CERTS_BACKUP_DIR...${NC}"
        cp "$CERT_FILE" "$CERTS_BACKUP_DIR/runai.crt"
        cp "$KEY_FILE" "$CERTS_BACKUP_DIR/runai.key"
        cp "$CERT_FILE" "$CERTS_BACKUP_DIR/full-chain.pem"
        
        echo -e "${GREEN}✅ Using provided certificates and backed up to $CERTS_BACKUP_DIR${NC}"
    else
        # Generate self-signed certificates
        echo -e "${BLUE}Creating certificates in: $CERT_DIR${NC}"
        mkdir -p "$CERT_DIR"
        cd "$CERT_DIR"

        # Set the password environment variable
        export OPENSSL_PASSWORD='kirson'
        
        echo -e "${BLUE}Generating certificates...${NC}"
        # Generate the root key with the provided passphrase
        if ! openssl genrsa -des3 -passout env:OPENSSL_PASSWORD -out rootCA.key 2048; then
            echo -e "${RED}❌ Failed to generate root key${NC}"
            exit 1
        fi

        # Generate root certificate
        if ! openssl req -x509 -new -nodes -key rootCA.key -passin env:OPENSSL_PASSWORD -sha256 -days 730 \
            -out rootCA.pem -subj "/C=US/ST=IL/L=TLV/O=Jupyter/CN=self-signed-nvidia"; then
            echo -e "${RED}❌ Failed to generate root certificate${NC}"
            exit 1
        fi

        # Generate a private key for your service
        if ! openssl genrsa -out runai.key 2048; then
            echo -e "${RED}❌ Failed to generate service key${NC}"
            exit 1
        fi

        # Generate a CSR for your service
        if ! openssl req -new -key runai.key -out runai.csr \
            -subj "/C=US/ST=IL/L=TLV/O=RUNAI/CN=$DNS_NAME"; then
            echo -e "${RED}❌ Failed to generate CSR${NC}"
            exit 1
        fi

        # Create the configuration file for the extensions
        cat << EOF > openssl.cnf
basicConstraints = CA:FALSE
authorityKeyIdentifier = keyid,issuer
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DNS_NAME
DNS.2 = *.runai.$DNS_NAME
DNS.3 = *.${DNS_NAME#*.}
EOF

        # Create the certificate
        if ! openssl x509 -req -in runai.csr -CA rootCA.pem -CAkey rootCA.key \
            -passin env:OPENSSL_PASSWORD -CAcreateserial -out runai.crt -days 730 \
            -sha256 -extfile openssl.cnf; then
            echo -e "${RED}❌ Failed to create certificate${NC}"
            exit 1
        fi

        # Combine the certificates into a chain
        cat runai.crt rootCA.pem > full-chain.pem

        # Verify the certificate
        if ! openssl verify -CAfile rootCA.pem runai.crt; then
            echo -e "${YELLOW}⚠️ Warning: Certificate verification failed, but continuing...${NC}"
        else
            echo -e "${GREEN}✅ Certificate verified successfully${NC}"
        fi

        # After successful generation, copy to backup directory
        mkdir -p "$CERTS_BACKUP_DIR"
        cp runai.crt "$CERTS_BACKUP_DIR/"
        cp runai.key "$CERTS_BACKUP_DIR/"
        cp full-chain.pem "$CERTS_BACKUP_DIR/"
        
        # Set certificate paths
        export CERT="$CERT_DIR/runai.crt"
        export KEY="$CERT_DIR/runai.key"
        export FULL="$CERT_DIR/full-chain.pem"
        
        cd "$CURRENT_DIR"
    fi
}

# Function to install Run.ai
install_runai() {
    # Create namespaces
    echo -e "${BLUE}Creating namespaces...${NC}"
    if ! log_command "kubectl create ns runai" "Create runai namespace"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to create runai namespace, continuing...${NC}"
    fi
    
    # If not in cluster-only mode, install the backend
    if [ "$CLUSTER_ONLY" != true ]; then
        if ! log_command "kubectl create ns runai-backend" "Create runai-backend namespace"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to create runai-backend namespace, continuing...${NC}"
        fi
        
        # Handle certificates only if not using --no-cert
        if [ "$NO_CERT" != true ]; then
            echo -e "${BLUE}Creating/updating TLS secrets...${NC}"
            
            # Delete existing secrets first
            kubectl -n runai-backend delete secret runai-backend-tls 2>/dev/null || true
            kubectl -n runai-backend delete secret runai-ca-cert 2>/dev/null || true
            kubectl -n runai delete secret runai-ca-cert 2>/dev/null || true
            
            # Create new secrets
            if ! log_command "kubectl create secret tls runai-backend-tls -n runai-backend --cert=$CERT --key=$KEY" "Create TLS secret"; then
                echo -e "${RED}❌ Failed to create TLS secret${NC}"
                exit 1
            fi
            
            if ! log_command "kubectl create secret generic runai-ca-cert -n runai-backend --from-file=runai-ca.pem=$FULL" "Create CA cert secret in runai-backend namespace"; then
                echo -e "${RED}❌ Failed to create CA cert secret in runai-backend namespace${NC}"
                exit 1
            fi
            
            if ! log_command "kubectl create secret generic runai-ca-cert -n runai --from-file=runai-ca.pem=$FULL" "Create CA cert secret in runai namespace"; then
                echo -e "${RED}❌ Failed to create CA cert secret in runai namespace${NC}"
                exit 1
            fi
            
            echo -e "${GREEN}✅ Certificate secrets created successfully${NC}"
        else
            echo -e "${BLUE}Skipping certificate secrets creation as requested with --no-cert flag...${NC}"
        fi

        # Apply repository secret if provided
        if [ -n "$REPO_SECRET" ]; then
            echo -e "${BLUE}Applying repository secret from $REPO_SECRET...${NC}"
            if ! log_command "kubectl apply -f \"$REPO_SECRET\"" "Apply repository secret"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to apply repository secret from $REPO_SECRET, continuing...${NC}"
            else
                echo -e "${GREEN}✅ Repository secret applied successfully from $REPO_SECRET${NC}"
            fi
        fi

        # Install Run.ai backend
        echo -e "${BLUE}Installing Run.ai backend...${NC}"
        if ! log_command "helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod" "Add Run.ai backend Helm repo"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to add runai-backend helm repo, continuing...${NC}"
        fi
        if ! log_command "helm repo update" "Update Helm repos"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to update helm repos, continuing...${NC}"
        fi

        # Set Helm install options based on certificate configuration
        HELM_OPTS="--set global.domain=$DNS_NAME"
        if [ "$NO_CERT" != true ]; then
            HELM_OPTS="$HELM_OPTS --set global.customCA.enabled=true"
        fi

        # Use --output json to suppress normal output and redirect stderr to /dev/null
        if ! log_command "helm install runai-backend -n runai-backend runai-backend/control-plane --version \"$RUNAI_VERSION\" $HELM_OPTS" "Install Run.ai backend"; then
            echo -e "${RED}❌ Failed to install Run.ai backend${NC}"
            exit 1
        else
            echo -e "${GREEN}✅ Run.ai backend installation started${NC}"
        fi
        
        # Wait for pods to be ready
        echo -e "${BLUE}Waiting for all pods in the 'runai-backend' namespace to be running...${NC}"
        while true; do
            TOTAL_PODS=$(kubectl get pods -n runai-backend --no-headers | wc -l)
            RUNNING_PODS=$(kubectl get pods -n runai-backend --no-headers | grep "Running" | wc -l)
            NOT_READY=$((TOTAL_PODS - RUNNING_PODS))
            
            # Use carriage return to update the same line
            echo -ne "⏳ Waiting... ($RUNNING_PODS pods Running out of $TOTAL_PODS)    \r"
            
            if [ "$NOT_READY" -eq 0 ]; then
                # Print a newline and completion message when done
                echo -e "\n${GREEN}✅ All pods in 'runai-backend' namespace are now running!${NC}"
                break
            fi
            sleep 5
        done
        
        # Set up environment variables
        export control_plane_domain=$DNS_NAME
        export cluster_version=$RUNAI_VERSION
        export cluster_name=runai-cluster
        
        echo -e "${BLUE}Getting authentication token from existing backend...${NC}"
        while true; do
            token=$(curl --insecure --location --request POST "https://$control_plane_domain/auth/realms/runai/protocol/openid-connect/token" \
                --header 'Content-Type: application/x-www-form-urlencoded' \
                --data-urlencode 'grant_type=password' \
                --data-urlencode 'client_id=runai' \
                --data-urlencode 'username=test@run.ai' \
                --data-urlencode 'password=Abcd!234' \
                --data-urlencode 'scope=openid' \
                --data-urlencode 'response_type=id_token' | jq -r .access_token)
            
            if [ ! -z "$token" ] && [ "$token" != "null" ]; then
                break
            fi
            echo -e "${BLUE}⏳ Waiting for authentication service...${NC}"
            sleep 5
        done
        
        # Create cluster and get UUID
        echo -e "${BLUE}Creating cluster...${NC}"
        if ! log_command "curl --insecure -X 'POST' \"https://$control_plane_domain/api/v1/clusters\" -H 'accept: application/json' -H \"Authorization: Bearer $token\" -H 'Content-Type: application/json' -d '{\"name\": \"${cluster_name}\", \"version\": \"${cluster_version}\"}'" "Create cluster"; then
            echo -e "${RED}❌ Failed to create cluster${NC}"
            exit 1
        fi
        
        # Get UUID
        uuid=$(curl --insecure -X 'GET' \
            "https://$control_plane_domain/api/v1/clusters" \
            -H 'accept: application/json' \
            -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' | jq ".[] | select(.name | contains(\"$cluster_name\"))" | jq -r .uuid)
        
        # Get installation string
        echo -e "${BLUE}Getting installation information...${NC}"
        while true; do
            installationStr=$(curl --insecure "https://$control_plane_domain/api/v1/clusters/$uuid/cluster-install-info?version=$cluster_version" \
                -H 'accept: application/json' \
                -H "Authorization: Bearer $token" \
                -H 'Content-Type: application/json')
            
            echo "$installationStr" > input.json
            
            if grep -q "helm" input.json; then
                break
            fi
            echo -e "${BLUE}⏳ Waiting for valid installation information...${NC}"
            sleep 5
        done
    else
        # If in cluster-only mode, we need to check the existing backend configuration
        echo -e "${BLUE}Running in cluster-only mode, checking existing backend configuration...${NC}"
        
        # Check if runai-backend is installed and get its configuration
        if helm get values runai-backend -n runai-backend &>/dev/null; then
            echo -e "${BLUE}Existing runai-backend installation found, checking configuration...${NC}"
            
            # Check if customCA is enabled in the existing installation
            CUSTOM_CA_ENABLED=$(helm get values runai-backend -n runai-backend -o json | jq -r '.global.customCA.enabled // false')
            
            if [ "$CUSTOM_CA_ENABLED" = "true" ]; then
                echo -e "${BLUE}Custom CA is enabled in existing backend, will configure cluster accordingly${NC}"
                # Set NO_CERT to false to ensure we include customCA.enabled in the cluster installation
                NO_CERT=false
                
                # Copy the CA certificate from backend to cluster namespace
                echo -e "${BLUE}Copying existing CA certificate from backend to cluster namespace...${NC}"
                
                # Create runai namespace if it doesn't exist
                kubectl create ns runai 2>/dev/null || true
                
                # Check if the CA certificate exists in the backend namespace
                if kubectl get secret runai-ca-cert -n runai-backend &>/dev/null; then
                    # Extract the CA certificate data
                    CA_DATA=$(kubectl get secret runai-ca-cert -n runai-backend -o jsonpath='{.data.runai-ca\.pem}')
                    
                    if [ -n "$CA_DATA" ]; then
                        # Create the secret in the runai namespace
                        echo "$CA_DATA" | base64 --decode > /tmp/ca.pem
                        kubectl create secret generic runai-ca-cert -n runai --from-file=runai-ca.pem=/tmp/ca.pem --dry-run=client -o yaml | kubectl apply -f -
                        rm /tmp/ca.pem
                        
                        echo -e "${GREEN}✅ Successfully copied CA certificate to cluster namespace${NC}"
                    else
                        echo -e "${YELLOW}⚠️ Warning: Could not extract CA certificate data${NC}"
                    fi
                else
                    echo -e "${YELLOW}⚠️ Warning: CA certificate not found in backend namespace${NC}"
                fi
            else
                echo -e "${BLUE}Custom CA is not enabled in existing backend, will skip certificate configuration${NC}"
                # Set NO_CERT to true to skip customCA.enabled in the cluster installation
                NO_CERT=true
            fi
        else
            echo -e "${YELLOW}⚠️ Warning: Could not find existing runai-backend installation. Proceeding with default certificate settings.${NC}"
        fi
        
        # Continue with the API calls to get installation command
        # Set up environment variables
        export control_plane_domain=$DNS_NAME
        export cluster_version=$RUNAI_VERSION
        export cluster_name=runai-cluster

        echo -e "${BLUE}Getting authentication token from existing backend...${NC}"
        while true; do
            token=$(curl --insecure --location --request POST "https://$control_plane_domain/auth/realms/runai/protocol/openid-connect/token" \
                --header 'Content-Type: application/x-www-form-urlencoded' \
                --data-urlencode 'grant_type=password' \
                --data-urlencode 'client_id=runai' \
                --data-urlencode 'username=test@run.ai' \
                --data-urlencode 'password=Abcd!234' \
                --data-urlencode 'scope=openid' \
                --data-urlencode 'response_type=id_token' | jq -r .access_token)
            
            if [ ! -z "$token" ] && [ "$token" != "null" ]; then
                break
            fi
            echo -e "${BLUE}⏳ Waiting for authentication service...${NC}"
            sleep 5
        done

        # Create cluster and get UUID
        echo -e "${BLUE}Creating cluster...${NC}"
        if ! log_command "curl --insecure -X 'POST' \"https://$control_plane_domain/api/v1/clusters\" -H 'accept: application/json' -H \"Authorization: Bearer $token\" -H 'Content-Type: application/json' -d '{\"name\": \"${cluster_name}\", \"version\": \"${cluster_version}\"}'" "Create cluster"; then
            echo -e "${RED}❌ Failed to create cluster${NC}"
            exit 1
        fi

        # Get UUID
        uuid=$(curl --insecure -X 'GET' \
            "https://$control_plane_domain/api/v1/clusters" \
            -H 'accept: application/json' \
            -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' | jq ".[] | select(.name | contains(\"$cluster_name\"))" | jq -r .uuid)

        # Get installation string
        echo -e "${BLUE}Getting installation information...${NC}"
        while true; do
            installationStr=$(curl --insecure "https://$control_plane_domain/api/v1/clusters/$uuid/cluster-install-info?version=$cluster_version" \
                -H 'accept: application/json' \
                -H "Authorization: Bearer $token" \
                -H 'Content-Type: application/json')
            
            echo "$installationStr" > input.json
            
            if grep -q "helm" input.json; then
                break
            fi
            echo -e "${BLUE}⏳ Waiting for valid installation information...${NC}"
            sleep 5
        done
    fi
    
    # Create installation script
    echo -e "${BLUE}Creating installation script...${NC}"
    installation_str=$(jq -r '.installationStr' input.json)

    # If NO_CERT is true, remove the global.customCA.enabled=true parameter
    if [ "$NO_CERT" = true ]; then
        formatted_command=$(echo "$installation_str" | sed -E '
            s/\\ --set /\n--set /g;
            s/--set cluster.url=/--set cluster.url=/g;
            s/--version="([^"]+)" \\$/--version="\1"/;
            s/--set global.customCA.enabled=true//g')
    else
        formatted_command=$(echo "$installation_str" | sed -E '
            s/\\ --set /\n--set /g;
            s/--set cluster.url=/--set cluster.url=/g;
            s/--version="([^"]+)" \\$/--version="\1"/;
            s/--create-namespace/--set global.customCA.enabled=true --create-namespace/')
    fi

    echo "$formatted_command" > install.sh
    chmod +x install.sh
    
    echo -e "${GREEN}✅ Run.ai installation script created successfully!${NC}"
    
    # Log the contents of install.sh
    echo -e "${BLUE}Contents of install.sh:${NC}"
    echo -e "${YELLOW}$(cat install.sh)${NC}"
    echo -e "\n${BLUE}Executing installation script...${NC}"
    
    # Execute the installation script
    echo -e "${BLUE}Installing Run.ai cluster components...${NC}"
    
    # Log the full command
    echo "Executing installation commands:" >> "$LOG_FILE"
    echo "$(cat install.sh)" >> "$LOG_FILE"
    
    # Execute install.sh silently and log all output
    echo -e "${BLUE}Executing installation script...${NC}"
    if ./install.sh >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}✅ Run.ai cluster components installed successfully${NC}"
    else
        echo -e "${RED}❌ Run.ai installation failed. Please check the logs at $LOG_FILE for details${NC}"
        exit 1
    fi
    
    # Wait for all pods in runai namespace to be ready
    echo -e "${BLUE}Waiting for all pods in the 'runai' namespace to be running...${NC}"
    while true; do
        TOTAL_PODS=$(kubectl get pods -n runai --no-headers | wc -l)
        RUNNING_PODS=$(kubectl get pods -n runai --no-headers | grep "Running" | wc -l)
        NOT_READY=$((TOTAL_PODS - RUNNING_PODS))
        
        # Use carriage return to update the same line
        echo -ne "⏳ Waiting... ($RUNNING_PODS pods Running out of $TOTAL_PODS)    \r"
        
        if [ "$NOT_READY" -eq 0 ]; then
            # Print a newline and completion message when done
            echo -e "\n${GREEN}✅ All pods in 'runai' namespace are now running!${NC}"
            break
        fi
        sleep 5
    done
    
    echo -e "${GREEN}✅ Run.ai installation completed successfully!${NC}"
}  # End of install_runai function

# Simplified status function that only shows pod counts
show_simple_status() {
    # Get pod counts
    BACKEND_TOTAL=$(kubectl get pods -n runai-backend --no-headers 2>/dev/null | wc -l || echo "0")
    BACKEND_RUNNING=$(kubectl get pods -n runai-backend --no-headers 2>/dev/null | grep "Running" | wc -l || echo "0")
    
    if [ "$BACKEND_TOTAL" -gt 0 ]; then
        BACKEND_PCT=$((BACKEND_RUNNING * 100 / BACKEND_TOTAL))
        echo -e "Run.ai Backend: ${GREEN}$BACKEND_RUNNING/$BACKEND_TOTAL pods running ($BACKEND_PCT%)${NC}"
    fi
    
    CLUSTER_TOTAL=$(kubectl get pods -n runai --no-headers 2>/dev/null | wc -l || echo "0")
    CLUSTER_RUNNING=$(kubectl get pods -n runai --no-headers 2>/dev/null | grep "Running" | wc -l || echo "0")
    
    if [ "$CLUSTER_TOTAL" -gt 0 ]; then
        CLUSTER_PCT=$((CLUSTER_RUNNING * 100 / CLUSTER_TOTAL))
        echo -e "Run.ai Cluster: ${GREEN}$CLUSTER_RUNNING/$CLUSTER_TOTAL pods running ($CLUSTER_PCT%)${NC}"
    fi
}

# Function to update local /etc/hosts file
update_local_hosts() {
    echo -e "${BLUE}Updating local /etc/hosts file with $IP_ADDRESS $DNS_NAME...${NC}"
    
    # Check if we have sudo access
    if ! sudo -n true 2>/dev/null; then
        echo -e "${YELLOW}⚠️ Sudo access required to update /etc/hosts file${NC}"
        echo -e "${YELLOW}Please enter your password when prompted${NC}"
    fi
    
    # Check if the entry already exists
    if grep -q "$DNS_NAME" /etc/hosts; then
        # Update the existing entry
        if ! grep -q "$IP_ADDRESS $DNS_NAME" /etc/hosts; then
            echo -e "${BLUE}Updating existing entry in /etc/hosts...${NC}"
            sudo sed -i.bak "s/.*$DNS_NAME/$IP_ADDRESS $DNS_NAME/" /etc/hosts
        else
            echo -e "${GREEN}✅ /etc/hosts already contains the correct entry${NC}"
            return 0
        fi
    else
        # Add a new entry
        echo -e "${BLUE}Adding new entry to /etc/hosts...${NC}"
        echo "$IP_ADDRESS $DNS_NAME" | sudo tee -a /etc/hosts > /dev/null
    fi
    
    # Verify the entry was added
    if grep -q "$IP_ADDRESS $DNS_NAME" /etc/hosts; then
        echo -e "${GREEN}✅ Successfully updated /etc/hosts with $IP_ADDRESS $DNS_NAME${NC}"
    else
        echo -e "${YELLOW}⚠️ Failed to update /etc/hosts. Please manually add the following line:${NC}"
        echo -e "${YELLOW}$IP_ADDRESS $DNS_NAME${NC}"
    fi
}

# Function to configure Bright Cluster Manager
configure_bcm() {
    echo -e "${BLUE}Configuring Bright Cluster Manager for Run.ai access...${NC}"
    
    # Step 1: Get the HTTPS port from ingress-nginx-controller
    echo -e "${BLUE}Getting HTTPS port from ingress-nginx-controller...${NC}"
    local nginx_ports=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
    
    if [ -z "$nginx_ports" ]; then
        echo -e "${RED}❌ Error: Could not find HTTPS nodePort in ingress-nginx-controller${NC}"
        return 1
    fi
    
    local https_port=$nginx_ports
    echo -e "${GREEN}✅ Found HTTPS nodePort: $https_port${NC}"
    
    # Step 2: Get the last node name from kubectl get nodes
    echo -e "${BLUE}Getting the last worker node name...${NC}"
    if ! log_command "kubectl get nodes --sort-by=.metadata.name -o jsonpath='{.items[-1:].metadata.name}'" "Get last node name"; then
        echo -e "${RED}❌ Error: Could not get node list${NC}"
        return 1
    fi
    
    local last_node=$(kubectl get nodes --sort-by=.metadata.name -o jsonpath='{.items[-1:].metadata.name}')
    
    if [ -z "$last_node" ]; then
        echo -e "${RED}❌ Error: Could not find any nodes in the cluster${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Found last node: $last_node${NC}"
    
    # Step 3: Verify the node exists in Bright Cluster Manager
    echo -e "${BLUE}Verifying node exists in Bright Cluster Manager...${NC}"
    if ! log_command "cmsh -c \"device list\"" "List BCM devices"; then
        echo -e "${RED}❌ Error: Could not list devices in Bright Cluster Manager${NC}"
        return 1
    fi
    
    if ! cmsh -c "device list" | grep -q "$last_node"; then
        echo -e "${RED}❌ Error: Node $last_node not found in Bright Cluster Manager${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Node $last_node found in Bright Cluster Manager${NC}"
    
    # Step 4: Configure nginx reverse proxy in Bright Cluster Manager
    echo -e "${BLUE}Configuring nginx reverse proxy in Bright Cluster Manager...${NC}"
    if ! log_command "cmsh -c \"device list | grep -i headnode\"" "Find BCM headnode"; then
        echo -e "${RED}❌ Error: Could not find headnode in Bright Cluster Manager${NC}"
        return 1
    fi
    
    local headnode=$(cmsh -c "device list" | grep -i headnode | awk '{print $2}')
    
    if [ -z "$headnode" ]; then
        echo -e "${RED}❌ Error: Could not find headnode in Bright Cluster Manager${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Using headnode: $headnode${NC}"
    
    # Create a temporary file with cmsh commands
    local bcm_temp="$TEMP_DIR/bcm-temp"
    cat > "$bcm_temp" << EOF
device use $headnode
roles
use nginx
nginxreverseproxy
list
add 443 $last_node $https_port 'runai'
commit
EOF

    # Log the content of the BCM commands file
    echo -e "${BLUE}BCM commands to execute:${NC}"
    if ! log_command "cat \"$bcm_temp\"" "BCM commands file content"; then
        echo -e "${YELLOW}⚠️ Warning: Could not log BCM commands file content${NC}"
    fi
    
    # Execute the cmsh commands from the file
    if ! log_command "cmsh -q -x -f \"$bcm_temp\"" "Execute BCM commands"; then
        echo -e "${YELLOW}⚠️ Warning: Could not configure Bright Cluster Manager nginx reverse proxy${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Successfully configured Bright Cluster Manager nginx reverse proxy${NC}"
    echo -e "${GREEN}✅ Run.ai is now accessible via Bright Cluster Manager at https://$DNS_NAME${NC}"
    
    # Show the configured reverse proxy details
    echo -e "${BLUE}Configured reverse proxy details:${NC}"
    if ! log_command "cmsh -c \"device use $headnode; roles; use nginx; nginxreverseproxy; list | grep -A 1 '$DNS_NAME'\"" "Show BCM reverse proxy configuration"; then
        echo -e "${YELLOW}⚠️ Warning: Could not show reverse proxy configuration${NC}"
    else
        echo -e "${YELLOW}$(cmsh -c "device use $headnode; roles; use nginx; nginxreverseproxy; list" | grep -A 1 "$DNS_NAME")${NC}"
    fi
    
    return 0
}

# Main execution
# Check Helm version first
check_helm_version

# Check if Run.ai is already installed
check_runai_installed

# Update local hosts file if IP is provided
if [ -n "$IP_ADDRESS" ] && [ -n "$DNS_NAME" ]; then
    update_local_hosts
fi

# Apply internal DNS patch if flag is set
if [ "$INTERNAL_DNS" = true ]; then
    patch_coredns
fi

# Configure Bright Cluster Manager if flag is set
if [ "$BCM_CONFIG" = true ]; then
    if configure_bcm; then
        echo -e "${GREEN}✅ Bright Cluster Manager configuration completed${NC}"
    else
        echo -e "${YELLOW}⚠️ Warning: Failed to configure Bright Cluster Manager, continuing with installation${NC}"
    fi
fi

# Patch Nginx if flag is set
if [ "$PATCH_NGINX" = true ]; then
    if [ -z "$IP_ADDRESS" ]; then
        echo -e "${RED}❌ Error: --ip is required when using --patch-nginx${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Patching Nginx Ingress Controller with external IP...${NC}"
    if patch_nginx_service; then
        echo -e "${GREEN}✅ NGINX listen to $IP_ADDRESS${NC}"
    else
        echo -e "${RED}❌ Failed to patch Nginx Ingress Controller${NC}"
        exit 1
    fi
fi

# Install prerequisites if not in runai-only mode
if [ "$RUNAI_ONLY" = false ]; then
    install_prerequisites
else
    # Even in runai-only mode, we need to ensure NGINX is properly configured if the flag is set
    if [ "$INSTALL_NGINX" = true ] && [ -n "$IP_ADDRESS" ]; then
        echo -e "${BLUE}Checking NGINX configuration...${NC}"
        patch_nginx_service
        echo -e "${GREEN}✅ NGINX listen to $IP_ADDRESS${NC}"
    fi
fi

# Install Knative if flag is set
if [ "$INSTALL_KNATIVE" = true ]; then
    install_knative
fi

# Setup certificates if not skipped
if [ "$NO_CERT" = true ]; then
    echo -e "${BLUE}Skipping certificate setup as requested with --no-cert flag...${NC}"
else
    # Setup certificates
    setup_certificates
fi

# Install Run.ai
install_runai

# Update local /etc/hosts file
update_local_hosts

echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                                       ║${NC}"
echo -e "${GREEN}║              Installation Completed Successfully!                     ║${NC}"
echo -e "${GREEN}║                                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
echo -e "\n${BLUE}You can access Run.ai at: ${GREEN}https://$DNS_NAME${NC}"
echo -e "${BLUE}Default credentials: ${GREEN}test@run.ai / Abcd!234${NC}\n"

# Final success message
echo -e "${GREEN}✅ Run.ai installation completed successfully${NC}"
echo
echo -e "${GREEN}You can access Run.ai at: https://${DNS_NAME}${NC}"
echo -e "${GREEN}Default credentials: test@run.ai / Abcd!234${NC}"
echo

# Add certificate instructions if using self-signed certificates
if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ]; then
    echo -e "${YELLOW}For self-signed certificates, please copy certificates/rootCA.pem to your browser or operating system${NC}"
    echo
fi

echo -e "${BLUE}Thank you for using the AI Factory One-Click Installer!${NC}"

