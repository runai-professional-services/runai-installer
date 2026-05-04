#!/bin/bash

# Add at the top of the script, after the initial variable declarations
PART3_EXECUTED=false

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --full                 Install complete Kubernetes cluster (default)"
    echo "  --core                 Install only core Kubernetes (no add-ons)"
    echo "  --addons               Install only add-ons (requires existing cluster)"
    echo "  --clean                Reset/clean existing Kubernetes cluster"
    echo "  --nginx                Include Nginx Ingress Controller"
    echo "  --prometheus           Include Prometheus monitoring stack"
    echo "  --gpu                  Include NVIDIA GPU Operator"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Full installation with all add-ons"
    echo "  $0 --core                             # Core Kubernetes only"
    echo "  $0 --addons --nginx --prometheus      # Install add-ons only"
    echo "  $0 --clean                            # Reset cluster"
    echo "  $0 --full --gpu                       # Full installation with GPU support"
    exit 1
}

# Function for Part 1: Kubespray installation
run_part1() {
    echo "Running Part 1: Kubespray installation"
    # Check and install python3-pip
    if ! command -v pip3 &> /dev/null; then
        echo "Installing python3-pip..."
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip > /dev/null 2>&1; then
            echo "❌ Failed to install python3-pip"
            exit 1
        fi
        echo "✅ python3-pip installed successfully"
    fi

    # Check and install helm
    if ! command -v helm &> /dev/null; then
        echo "Installing helm..."
        if ! curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > /dev/null 2>&1; then
            echo "❌ Failed to download helm installation script"
            exit 1
        fi
        chmod 700 get_helm.sh
        if ! ./get_helm.sh > /dev/null 2>&1; then
            echo "❌ Failed to install helm"
            rm -f get_helm.sh
            exit 1
        fi
        rm -f get_helm.sh
        echo "✅ Helm installed successfully"
    fi

    # Ensure we're in the kubespray directory
    if [ ! -d "kubespray" ]; then
        echo "Error: This script must be run from the directory containing kubespray!"
        exit 1
    fi
    cd kubespray

    # Function to get all IP addresses
    get_ip_addresses() {
        echo "Available IP addresses:"
        echo "----------------------"
        ip -o addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print NR")", $2, $4}'
    }

    # Function to validate IP selection
    validate_ip_selection() {
        local selection=$1
        local max_count=$(ip -o addr show | grep 'inet ' | grep -v '127.0.0.1' | wc -l)
        if [[ ! $selection =~ ^[0-9]+$ ]] || [ $selection -lt 1 ] || [ $selection -gt $max_count ]; then
            return 1
        fi
        return 0
    }

    # Get hostname
    HOSTNAME=$(hostname)

    # Display IP addresses and get user selection
    get_ip_addresses
    echo
    echo "Please select an IP address by number:"
    read IP_SELECTION

    # Validate selection
    while ! validate_ip_selection $IP_SELECTION; do
        echo "Invalid selection. Please choose a number from the list above:"
        read IP_SELECTION
    done

    # Get the selected IP address
    SELECTED_IP=$(ip -o addr show | grep 'inet ' | grep -v '127.0.0.1' | awk 'NR=='$IP_SELECTION'{print $4}' | cut -d'/' -f1)

    echo "Selected IP: $SELECTED_IP"
    echo "Hostname: $HOSTNAME"

    # Create inventory.ini with proper hostname
    cat > ./inventory/runai/inventory.ini << EOF
[kube_control_plane]
${HOSTNAME}  ansible_host=${HOSTNAME}

[etcd:children]
kube_control_plane

[kube_node]
${HOSTNAME}  ansible_host=${HOSTNAME}
EOF

    echo "Installation configuration completed successfully!"
    echo "inventory.ini has been created with hostname: $HOSTNAME"

    # Get current user
    CURRENT_USER=$(whoami)

    # Create sudoers file for current user
    echo "Creating sudoers file for $CURRENT_USER..."
    SUDOERS_FILE="/etc/sudoers.d/$CURRENT_USER"
    if ! sudo bash -c "echo '$CURRENT_USER ALL=(ALL) NOPASSWD: ALL' > $SUDOERS_FILE"; then
        echo "❌ Failed to create sudoers file for $CURRENT_USER"
        exit 1
    fi

    # Set correct permissions for sudoers file
    if ! sudo chmod 0440 $SUDOERS_FILE; then
        echo "❌ Failed to set permissions on sudoers file"
        exit 1
    fi
    echo "✅ Sudoers file created successfully for $CURRENT_USER"

    # Generate SSH keys if they don't exist
    if [ ! -f ~/.ssh/id_rsa ]; then
        echo "Generating SSH keys..."
        ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

        # Copy SSH key to local host for passwordless SSH
        echo "Copying SSH key to local host..."
        ssh-copy-id $CURRENT_USER@$HOSTNAME || {
            echo "Error: Failed to copy SSH key. Please ensure SSH server is running."
            exit 1
        }
    fi

    # Add user to sudo group if not already there
    if ! groups $CURRENT_USER | grep -q '\bsudo\b'; then
        echo "Adding user $CURRENT_USER to sudo group..."
        # We need to use sudo here as adding to sudo group requires root privileges
        if ! sudo usermod -aG sudo $CURRENT_USER; then
            echo "Error: Failed to add user to sudo group. Please run this script with sudo privileges."
            exit 1
        fi
        echo "User $CURRENT_USER has been added to sudo group."
        echo "Please log out and log back in for the changes to take effect."
    fi

    # Test sudo access
    if ! sudo -n true 2>/dev/null; then
        echo "Please enter your password to verify sudo access:"
        sudo ls > /dev/null
    fi

    echo "Setup completed successfully!"

    # Install Python requirements
    echo "Installing Python requirements..."
    if ! pip install -r requirements.txt; then
        echo "❌ Failed to install Python requirements. Please check your Python installation."
        exit 1
    fi
    echo "✅ Python requirements installed successfully!"

    # Create .kube directory in home directory (only once, at the beginning)
    echo "Creating .kube directory..."
    mkdir -p $HOME/.kube
    if [ ! -d $HOME/.kube ]; then
        echo "❌ Failed to create .kube directory"
        exit 1
    fi
    echo "✅ .kube directory created successfully"

    # Ensure correct PATH
    REQUIRED_PATH="/home/$CURRENT_USER/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
    if [[ "$PATH" != *"/home/$CURRENT_USER/.local/bin"* ]]; then
        echo "Updating PATH environment..."
        export PATH="/home/$CURRENT_USER/.local/bin:$PATH"
    fi

    echo "Starting Kubernetes cluster installation..."
    echo "This may take 15-30 minutes. Please be patient."

    # Run ansible-playbook
    if ! ansible-playbook -i inventory/runai/inventory.ini cluster.yml -b; then
        echo -e "\n❌ Kubernetes cluster installation failed."
        exit 1
    fi

    # Check if ansible-playbook was successful
    if [ $? -eq 0 ]; then
        echo -e "\n✅ Kubernetes cluster installation completed successfully!"

        # Copy admin.conf and set ownership (using sudo for both operations)
        echo "Setting up kubectl configuration..."
        if ! sudo bash -c "cp -f /etc/kubernetes/admin.conf $HOME/.kube/config && chown $CURRENT_USER:$CURRENT_USER $HOME/.kube/config"; then
            echo "❌ Failed to copy and set ownership of kubernetes admin.conf"
            exit 1
        fi

        # Test kubectl
        echo "Testing kubectl configuration..."
        if kubectl get nodes; then
            echo "✅ Kubectl is configured correctly!"
            PART3_EXECUTED=true  # Set the flag after successful installation
        else
            echo "❌ Kubectl test failed. Please check your configuration."
            exit 1
        fi
    else
        echo -e "\n❌ Kubernetes cluster installation failed. Please check the errors above."
        exit 1
    fi
}

# Function for Part 2: kubectl configuration
run_part2() {
    echo "Running Part 2: kubectl configuration"
    # Create .kube directory and copy config
    mkdir -p $HOME/.kube
    echo "Setting up kubectl configuration..."
    if ! sudo bash -c "cp -f /etc/kubernetes/admin.conf $HOME/.kube/config && chown $CURRENT_USER:$CURRENT_USER $HOME/.kube/config"; then
        echo "❌ Failed to copy and set ownership of kubernetes admin.conf"
        exit 1
    fi

    # Test kubectl
    echo "Testing kubectl configuration..."
    if kubectl get nodes; then
        echo "✅ Kubectl is configured correctly!"
    else
        echo "❌ Kubectl test failed. Please check your configuration."
        exit 1
    fi
}

# Function for Part 3: Optional components installation
run_part3() {
    echo "Running Part 3: Optional components installation"

    # Check if Kubernetes cluster is accessible
    if ! kubectl get nodes &> /dev/null; then
        echo "❌ Error: Cannot access Kubernetes cluster. Please ensure kubectl is configured."
        return 1
    fi

    # Get current user and selected IP for the installations
    CURRENT_USER=$(whoami)

    # Get the selected IP address (we need to ask again in part 3)
    echo "Available IP addresses:"
    echo "----------------------"
    ip -o addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print NR")", $2, $4}'
    echo
    echo "Please select an IP address by number:"
    read IP_SELECTION
    SELECTED_IP=$(ip -o addr show | grep 'inet ' | grep -v '127.0.0.1' | awk 'NR=='$IP_SELECTION'{print $4}' | cut -d'/' -f1)
    echo "Selected IP: $SELECTED_IP"

    # Install Nginx Ingress Controller if requested
    if [ "$INSTALL_NGINX" = true ]; then
        echo "Installing Nginx Ingress Controller..."
        
        # Check if Nginx Ingress is already installed
        if kubectl get ns nginx-ingress &> /dev/null && kubectl get svc -n nginx-ingress ingress-nginx-controller &> /dev/null; then
            echo "✅ Nginx Ingress Controller already installed."
        else
            # Add helm repo
            if ! helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to add nginx helm repo, continuing..."
            fi

            # Update helm repos
            if ! helm repo update > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to update helm repos, continuing..."
            fi

            # Create nginx values file with proper configuration
            local values_file="/tmp/nginx-values.yaml"
            cat > "$values_file" << EOF
controller:
  allowSnippetAnnotations: true
  extraArgs:
    enable-ssl-passthrough: ""
  replicaCount: 2
  service:
    externalTrafficPolicy: Cluster
    nodePorts:
      http: "30080"
      https: "30443"
    type: NodePort
  tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
      operator: Exists
    - effect: NoSchedule
      key: node-role.kubernetes.io/control-plane
      operator: Exists
EOF

            # Install Nginx Ingress Controller with specific version and values
            if ! helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
                --version 4.12.2 \
                --namespace nginx-ingress \
                --create-namespace \
                -f "$values_file" > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to install nginx ingress, continuing..."
            else
                echo "✅ Nginx Ingress Controller installed successfully!"
                
                # Wait for service to be ready
                echo "Waiting for nginx ingress service to be ready..."
                sleep 10
                
                # Patch service with external IP if needed
                if kubectl get svc -n nginx-ingress ingress-nginx-controller &> /dev/null; then
                    kubectl patch svc ingress-nginx-controller -n nginx-ingress \
                        --type='merge' \
                        -p="{\"spec\":{\"externalIPs\":[\"$SELECTED_IP\"]}}" > /dev/null 2>&1
                    echo "✅ Nginx service patched with external IP: $SELECTED_IP"
                fi
            fi
            
            # Clean up temporary values file
            rm -f "$values_file"
        fi
    fi

    # Install Prometheus Stack if requested
    if [ "$INSTALL_PROMETHEUS" = true ]; then
        echo "Installing Prometheus Stack..."
        
        # Check if Prometheus is already installed
        if kubectl get ns monitoring &> /dev/null && kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus &> /dev/null; then
            echo "✅ Prometheus Stack already installed."
        else
            # Add helm repo
            if ! helm repo add prometheus-community https://prometheus-community.github.io/helm-charts > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to add prometheus helm repo, continuing..."
            fi

            # Update helm repos
            if ! helm repo update > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to update helm repos, continuing..."
            fi

            # Install Prometheus Stack
            if ! helm install prometheus prometheus-community/kube-prometheus-stack \
                -n monitoring --create-namespace \
                --set grafana.enabled=false > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to install prometheus stack, continuing..."
            else
                echo "✅ Prometheus Stack installed successfully!"
            fi
        fi
    fi

    # Install NVIDIA GPU Operator if requested (same chart pin + values as runai-installer modules/prerequisites.sh)
    if [ "$INSTALL_GPU_OPERATOR" = true ]; then
        echo "Installing NVIDIA GPU Operator..."
        _K8_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
        # shellcheck source=/dev/null
        . "${_K8_ROOT}/modules/gpu-operator-values.sh"
        _GPU_VALUES="$(runai_gpu_operator_values_file_for_host "${_K8_ROOT}/modules")"
        _GPU_CHART_VER="${GPU_OPERATOR_CHART_VERSION:-v25.10.1}"
        echo "  GPU Operator values profile: $(runai_gpu_operator_values_profile_label "$_GPU_VALUES") ($_GPU_VALUES)"

        if helm status gpu-operator -n gpu-operator &>/dev/null; then
            echo "✅ NVIDIA GPU Operator already installed (Helm release gpu-operator)."
        elif [ ! -f "$_GPU_VALUES" ]; then
            echo "⚠️ Warning: GPU Operator values missing: $_GPU_VALUES — skipping GPU Operator."
        else
            if ! helm repo add nvidia https://helm.ngc.nvidia.com/nvidia > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to add NVIDIA helm repo, continuing..."
            fi
            if ! helm repo update nvidia > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to update NVIDIA helm repo, continuing..."
            fi
            _gpu_helm_ok=false
            if [ -n "${GPU_OPERATOR_HELM_VALUES_FILE:-}" ] && [ -f "${GPU_OPERATOR_HELM_VALUES_FILE}" ]; then
                helm upgrade --install gpu-operator nvidia/gpu-operator \
                    --namespace gpu-operator --create-namespace \
                    --version "${_GPU_CHART_VER}" --wait --timeout 25m \
                    -f "${_GPU_VALUES}" -f "${GPU_OPERATOR_HELM_VALUES_FILE}" > /dev/null 2>&1 && _gpu_helm_ok=true
            else
                helm upgrade --install gpu-operator nvidia/gpu-operator \
                    --namespace gpu-operator --create-namespace \
                    --version "${_GPU_CHART_VER}" --wait --timeout 25m \
                    -f "${_GPU_VALUES}" > /dev/null 2>&1 && _gpu_helm_ok=true
            fi
            if [ "$_gpu_helm_ok" != true ]; then
                echo "⚠️ Warning: Failed to install NVIDIA GPU operator, continuing..."
            else
                echo "✅ NVIDIA GPU Operator installed successfully! (chart ${_GPU_CHART_VER})"
            fi
        fi
    fi

    if [ "$INSTALL_NGINX" = true ] || [ "$INSTALL_PROMETHEUS" = true ] || [ "$INSTALL_GPU_OPERATOR" = true ]; then
        echo "✅ Optional components installation completed!"
    else
        echo "ℹ️ No optional components selected for installation."
    fi
}

# Function to clean/reset Kubernetes cluster
run_clean() {
    echo "Running cluster cleanup/reset..."
    
    # Ensure we're in the kubespray directory
    if [ ! -d "kubespray" ]; then
        echo "Error: This script must be run from the directory containing kubespray!"
        exit 1
    fi
    cd kubespray

    # Check if inventory file exists
    if [ ! -f "inventory/runai/inventory.ini" ]; then
        echo "Error: inventory/runai/inventory.ini not found!"
        echo "Please run Part 1 first to create the inventory file."
        exit 1
    fi

    echo "⚠️ Warning: This will completely reset your Kubernetes cluster!"
    echo "All data and configurations will be lost."
    echo -n "Are you sure you want to continue? (yes/no): "
    read confirmation

    if [ "$confirmation" != "yes" ]; then
        echo "Cleanup cancelled."
        exit 0
    fi

    echo "Starting cluster reset..."
    if ! ansible-playbook reset.yml -i inventory/runai/inventory.ini -b; then
        echo "❌ Cluster reset failed."
        exit 1
    fi

    echo "✅ Kubernetes cluster has been reset successfully!"
    echo "You can now run the installation again if needed."
}

# Parse command line arguments
INSTALL_MODE="full"  # Default to full installation
INSTALL_NGINX=false
INSTALL_PROMETHEUS=false
INSTALL_GPU_OPERATOR=false
CLEAN_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            INSTALL_MODE="full"
            shift
            ;;
        --core)
            INSTALL_MODE="core"
            shift
            ;;
        --addons)
            INSTALL_MODE="addons"
            shift
            ;;
        --nginx)
            INSTALL_NGINX=true
            shift
            ;;
        --prometheus)
            INSTALL_PROMETHEUS=true
            shift
            ;;
        --gpu)
            INSTALL_GPU_OPERATOR=true
            shift
            ;;
        --clean)
            CLEAN_MODE=true
            shift
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            ;;
    esac
done

# Check if clean mode is requested
if [ "$CLEAN_MODE" = true ]; then
    run_clean
    exit 0
fi

# Main execution
case $INSTALL_MODE in
    "full")
        echo "🚀 Starting full Kubernetes installation..."
        run_part1
        run_part2
        if [ "$PART3_EXECUTED" = false ]; then
            run_part3
        fi
        ;;
    "core")
        echo "🔧 Installing core Kubernetes only..."
        run_part1
        run_part2
        ;;
    "addons")
        echo "📦 Installing add-ons only..."
        run_part3
        ;;
    *)
        echo "Invalid installation mode: $INSTALL_MODE"
        show_usage
        ;;
esac

