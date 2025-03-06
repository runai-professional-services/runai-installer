#!/bin/bash

# Welcome screen
echo -e "\n\033[1;32m"  # Start bold green text
cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║              Welcome to AI Factory Appliance Installation             ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
echo -e "\033[0m"  # Reset text formatting

echo -e "\033[1m"  # Start bold text
echo "This installation includes:"
echo "• Full Kubernetes cluster setup"
echo "• Run.ai Resource Management Platform"
echo "• Self-signed certificates configuration"
echo "• Storage system initialization"
echo "• NGINX Ingress Controller"
echo "• Monitoring and observability tools"
echo "• GPU Operator for NVIDIA DGX systems"
echo -e "\nThe installer will handle all prerequisites needed for running"
echo "your DGX Appliance successfully."
echo -e "\nPlease copy kubespray/certificates/rootCA.pem to your browser or Laptop Secret"
echo -e "\033[0m"  # Reset text formatting

echo -e "\n\033[33mPress Enter to continue...\033[0m"
read

# Add at the top of the script, after the initial variable declarations
PART3_EXECUTED=false

# Variables for internal DNS
INTERNAL_DNS=false
FQDN=""
IP=""
RUNAI_ONLY=false  # Add this variable for the new option

# Variables for certificates
CERT_FILE=""
KEY_FILE=""

# Function to show usage
show_usage() {
    echo "Usage: $0 [-p PART] [--dns DNS_NAME] [--runai-version VERSION] [--repo-secret FILE] [--knative] [--internal-dns] [--ip IP_ADDRESS] [--runai-only] [--cert CERT_FILE] [--key KEY_FILE]"
    echo "  -p PART                Specify which part to run (1, 2, 3, or 4)"
    echo "  --dns DNS_NAME         Specify DNS name for Run.ai certificates"
    echo "  --runai-version VER    Specify Run.ai version to install"
    echo "  --repo-secret FILE     Optional: Specify repository secret file location"
    echo "  --knative              Optional: Install Knative serving"
    echo "  --internal-dns         Optional: Configure internal DNS"
    echo "  --ip IP_ADDRESS        Required if --internal-dns is set: Specify IP address for internal DNS"
    echo "  --runai-only           Optional: Skip prerequisites and directly install Run.ai"
    echo "  --cert CERT_FILE       Optional: Use provided certificate file instead of generating self-signed"
    echo "  --key KEY_FILE         Optional: Use provided key file instead of generating self-signed"
    echo ""
    echo "Examples:"
    echo "  $0 -p 1 --dns runai.kirson.lab --ip 172.21.140.20  # Run only part 1 with specified DNS and IP"
    echo "  $0 --dns runai.kirson.lab --internal-dns --ip 172.21.140.20  # Run all parts with internal DNS"
    echo "  $0 --dns runai.kirson.lab --runai-version 2.5.0 --runai-only  # Install only Run.ai without prerequisites"
    echo "  $0 --dns runai.kirson.lab --runai-version 2.5.0 --cert /path/to/cert.pem --key /path/to/key.pem  # Use provided certificates"
    exit 1
}

# Function for Part 1: Kubespray installation
run_part1() {
    echo "Running Part 1: Kubespray installation"
    
    # Check and install jq
    if ! command -v jq &> /dev/null; then
        echo "Installing jq..."
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y jq > /dev/null 2>&1; then
            echo "❌ Failed to install jq"
            exit 1
        fi
        echo "✅ jq installed successfully"
    fi

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

    # Get hostname
    HOSTNAME=$(hostname)

    # Create inventory.ini with proper hostname
    cat > ./inventory/runai/inventory.ini << EOF
[kube_control_plane]
${HOSTNAME} ansible_host=${HOSTNAME}

[etcd:children]
kube_control_plane

[kube_node]
${HOSTNAME} ansible_host=${HOSTNAME}
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
    
    # Check if Kubernetes is already installed
    if kubectl get nodes &> /dev/null; then
        echo "✅ Kubernetes cluster already installed!"
        echo "============================================"
        echo "          Kubernetes is Ready!              "
        echo "============================================"
        echo ""
        echo ""
        echo "============================================"
        echo "     Continuing to Run.ai installation...   "
        echo "============================================"
        echo ""
        
        # Skip to Run.ai installation
        PART3_EXECUTED=true  # Set flag to skip Part 3
        run_part4
        exit 0
    fi

    echo "This may take 15-30 minutes. Please be patient."

    # Run ansible-playbook if Kubernetes is not installed
    if ! ansible-playbook -i inventory/runai/inventory.ini cluster.yml -b; then
        echo -e "\n❌ Kubernetes cluster installation failed."
        exit 1
    fi

    # Check if ansible-playbook was successful
    if [ $? -eq 0 ]; then
        echo -e "\n✅ Kubernetes cluster installation completed successfully!"
        echo "============================================"
        echo "          Kubernetes is Ready!              "
        echo "============================================"
        echo ""
        echo ""
        echo "============================================"
        echo "     Continuing to Run.ai installation...   "
        echo "============================================"
        echo ""
        
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
            
            # Install Nginx Ingress Controller
            echo "Installing Nginx Ingress Controller..."
            if ! helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to add nginx helm repo, continuing..."
            fi
            
            if ! helm repo update > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to update helm repos, continuing..."
            fi
            
            if ! helm upgrade -i nginx-ingress ingress-nginx/ingress-nginx \
                --namespace nginx-ingress --create-namespace \
                --set controller.kind=DaemonSet \
                --set controller.service.externalIPs="{$IP}" > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to install nginx ingress, continuing..."
            else
                echo "✅ Nginx Ingress Controller installed successfully!"
            fi
            
            # Install Prometheus Stack
            echo "Installing Prometheus Stack..."
            if ! helm repo add prometheus-community https://prometheus-community.github.io/helm-charts > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to add prometheus helm repo, continuing..."
            fi
            
            if ! helm repo update > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to update helm repos, continuing..."
            fi
            
            if ! helm install prometheus prometheus-community/kube-prometheus-stack \
                -n monitoring --create-namespace --set grafana.enabled=false > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to install prometheus stack, continuing..."
            else
                echo "✅ Prometheus Stack installed successfully!"
            fi
            
            # Install NVIDIA GPU Operator
            echo "Installing NVIDIA GPU Operator..."
            if ! helm repo add nvidia https://helm.ngc.nvidia.com/nvidia > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to add NVIDIA helm repo, continuing..."
            fi
            
            if ! helm repo update > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to update helm repos, continuing..."
            fi
            
            if ! helm install --wait --generate-name \
                -n gpu-operator --create-namespace \
                nvidia/gpu-operator > /dev/null 2>&1; then
                echo "⚠️ Warning: Failed to install NVIDIA GPU operator, continuing..."
            else
                echo "✅ NVIDIA GPU Operator installed successfully!"
            fi
            
            echo "✅ Kubernetes cluster installation completed successfully!"
            PART3_EXECUTED=true  # Set the flag after successful installation

            # Patch local-path-config ConfigMap
            echo "Patching local-path-config ConfigMap..."
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
            '
            
            echo "✅ Local Path Storage configured successfully!"
            
            # Continue to Run.ai installation
            run_part4
        else
            echo "❌ Failed to configure kubectl"
            exit 1
        fi
    else
        echo "❌ Kubernetes cluster installation failed"
        exit 1
    fi
}

# Function for Part 2: Storage setup
run_part2() {
    echo "Running Part 2: Storage setup"
    # Storage setup logic here
}

# Function for Part 3: Kubernetes installation
run_part3() {
    echo "Running Part 3: Kubernetes installation"
    # Kubernetes installation logic here
}

# Function for Part 4: Run.ai installation
run_part4() {
    echo "Running Part 4: Run.ai installation"
    # Run.ai installation logic here
}

# Function to install Knative
install_knative() {
    echo "Installing Knative (optional component)..."
    if ! kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.17.0/serving-crds.yaml > /dev/null 2>&1; then
        echo "⚠️ Warning: Failed to install Knative CRDs, continuing..."
    fi
    
    if ! kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.17.0/serving-core.yaml > /dev/null 2>&1; then
        echo "⚠️ Warning: Failed to install Knative Core, continuing..."
    fi
    
    if ! kubectl apply -f https://github.com/knative/net-kourier/releases/download/knative-v1.17.0/kourier.yaml > /dev/null 2>&1; then
        echo "⚠️ Warning: Failed to install Knative Kourier, continuing..."
    fi
    
    if ! kubectl patch configmap/config-network \
        --namespace knative-serving \
        --type merge \
        --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}' > /dev/null 2>&1; then
        echo "⚠️ Warning: Failed to configure Knative network, continuing..."
    fi
    
    echo "✅ Knative installation completed!"
}

# Function to patch CoreDNS for internal DNS
patch_coredns() {
    echo "[INFO] Patching CoreDNS to add internal DNS entry for $FQDN -> $IP"
    
    # Get the current CoreDNS ConfigMap
    kubectl -n kube-system get configmap coredns -o yaml > coredns-configmap.yaml
    
    # Update the ConfigMap with the new hosts entry
    kubectl -n kube-system patch configmap coredns --type='merge' --patch="
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

            hosts $FQDN {
              $IP $FQDN
              fallthrough
            }
        }
    "

    # Restart CoreDNS to apply the changes
    echo "[INFO] Restarting CoreDNS..."
    kubectl -n kube-system delete pod -l k8s-app=kube-dns

    echo "[SUCCESS] CoreDNS updated with $FQDN -> $IP"
}

# Function for Run.ai only installation
run_runai_only() {
    echo "Running Run.ai only installation..."
    
    # Create certificates directory
    CERT_DIR="./certificates"
    CURRENT_DIR="$(pwd)"
    
    # Check if user provided certificates
    if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
        echo "Using provided certificate and key files..."
        
        # Create certificates directory if it doesn't exist
        mkdir -p "$CERT_DIR"
        
        # Copy provided certificate and key to the certificates directory
        cp "$CERT_FILE" "$CERT_DIR/runai.crt"
        cp "$KEY_FILE" "$CERT_DIR/runai.key"
        
        # Set certificate paths
        export CERT="$CERT_DIR/runai.crt"
        export KEY="$CERT_DIR/runai.key"
        export FULL="$CERT_FILE"  # Use the provided certificate as the full chain
        
        echo "✅ Using provided certificates"
    else
        echo "Creating certificates in: $CERT_DIR"
        mkdir -p "$CERT_DIR"
        cd "$CERT_DIR"

        # Set the password environment variable
        export OPENSSL_PASSWORD='kirson'
        
        echo "Generating certificates..."
        # Generate the root key with the provided passphrase
        if ! openssl genrsa -des3 -passout env:OPENSSL_PASSWORD -out rootCA.key 2048; then
            echo "❌ Failed to generate root key"
            exit 1
        fi

        # Generate root certificate
        if ! openssl req -x509 -new -nodes -key rootCA.key -passin env:OPENSSL_PASSWORD -sha256 -days 730 \
            -out rootCA.pem -subj "/C=US/ST=IL/L=TLV/O=Jupyter/CN=ww"; then
            echo "❌ Failed to generate root certificate"
            exit 1
        fi

        # Generate a private key for your service
        if ! openssl genrsa -out runai.key 2048; then
            echo "❌ Failed to generate service key"
            exit 1
        fi

        # Generate a CSR for your service
        if ! openssl req -new -key runai.key -out runai.csr \
            -subj "/C=US/ST=IL/L=TLV/O=RUNAI/CN=$DNS_NAME"; then
            echo "❌ Failed to generate CSR"
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
            echo "❌ Failed to create certificate"
            exit 1
        fi

        # Combine the certificates into a chain
        cat runai.crt rootCA.pem > full-chain.pem

        # Verify the certificate
        if ! openssl verify -CAfile rootCA.pem runai.crt; then
            echo "⚠️ Warning: Certificate verification failed, but continuing..."
        else
            echo "✅ Certificate verified successfully"
        fi

        # Set certificate paths with full directory
        export CERT="$CERT_DIR/runai.crt"
        export KEY="$CERT_DIR/runai.key"
        export FULL="$CERT_DIR/full-chain.pem"

        # Return to original directory
        cd "$CURRENT_DIR"
    fi

    # Apply internal DNS patch if flag is set
    if [ "$INTERNAL_DNS" = true ]; then
        patch_coredns
    fi

    # Create namespaces and secrets
    echo "Creating namespaces and secrets..."
    kubectl create ns runai 2>/dev/null || true
    kubectl create ns runai-backend 2>/dev/null || true
    kubectl -n runai-backend delete secret runai-backend-tls 2>/dev/null || true

    # Create secrets using the full paths
    echo "Creating/updating secrets..."
    kubectl create secret tls runai-backend-tls -n runai-backend --cert=$CERT --key=$KEY 2>/dev/null || \
    kubectl create secret tls runai-backend-tls -n runai-backend --cert=$CERT --key=$KEY --dry-run=client -o yaml | kubectl apply -f -

    kubectl -n runai-backend create secret generic runai-ca-cert --from-file=runai-ca.pem=$FULL 2>/dev/null || \
    kubectl -n runai-backend create secret generic runai-ca-cert --from-file=runai-ca.pem=$FULL --dry-run=client -o yaml | kubectl apply -f -

    kubectl -n runai create secret generic runai-ca-cert --from-file=runai-ca.pem=$FULL 2>/dev/null || \
    kubectl -n runai create secret generic runai-ca-cert --from-file=runai-ca.pem=$FULL --dry-run=client -o yaml | kubectl apply -f -

    echo "✅ Secrets created/updated successfully"

    # Apply repository secret if provided
    if [ -n "$REPO_SECRET" ]; then
        echo "Applying repository secret from $REPO_SECRET..."
        if ! kubectl apply -f "$REPO_SECRET"; then
            echo "⚠️ Warning: Failed to apply repository secret from $REPO_SECRET, continuing..."
        else
            echo "✅ Repository secret applied successfully from $REPO_SECRET"
        fi
    fi

    # Install Run.ai backend
    echo "Installing Run.ai backend..."
    helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod
    helm repo update
    
    if ! helm install runai-backend -n runai-backend runai-backend/control-plane \
        --version "$RUNAI_VERSION" \
        --set global.domain=$DNS_NAME \
        --set global.customCA.enabled=true; then
        echo "❌ Failed to install Run.ai backend"
        exit 1
    fi
    
    # Wait for pods to be ready
    echo "Waiting for all pods in the 'runai-backend' namespace to be running..."
    while true; do
        NOT_READY=$(kubectl get pods -n runai-backend --no-headers | grep -v "Running" | wc -l)
        if [ "$NOT_READY" -eq 0 ]; then
            echo "✅ All pods in 'runai-backend' namespace are now running!"
            break
        else
            echo "⏳ Waiting... ($NOT_READY pods not ready)"
        fi
        sleep 5
    done
    
    # Set up environment variables
    export control_plane_domain=$DNS_NAME
    export cluster_version=$RUNAI_VERSION
    export cluster_name=appliance
    
    # Get token and create cluster
    echo "Getting authentication token..."
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
        echo "⏳ Waiting for authentication service..."
        sleep 5
    done
    
    # Create cluster and get UUID
    echo "Creating cluster..."
    curl --insecure -X 'POST' \
        "https://$control_plane_domain/api/v1/clusters" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "{
            \"name\": \"${cluster_name}\",
            \"version\": \"${cluster_version}\"
        }"
    
    # Get UUID
    uuid=$(curl --insecure -X 'GET' \
        "https://$control_plane_domain/api/v1/clusters" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' | jq ".[] | select(.name | contains(\"$cluster_name\"))" | jq -r .uuid)
    
    # Get installation string
    echo "Getting installation information..."
    while true; do
        installationStr=$(curl --insecure "https://$control_plane_domain/api/v1/clusters/$uuid/cluster-install-info?version=$cluster_version" \
            -H 'accept: application/json' \
            -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json')
        
        echo "$installationStr" > input.json
        
        if grep -q "helm" input.json; then
            break
        fi
        echo "⏳ Waiting for valid installation information..."
        sleep 5
    done
    
    # Create installation script
    echo "Creating installation script..."
    installation_str=$(jq -r '.installationStr' input.json)
    formatted_command=$(echo "$installation_str" | sed -E '
        s/\\ --set /\n--set /g;
        s/--set cluster.url=/--set cluster.url=/g;
        s/--version="([^"]+)" \\$/--version="\1"/;
        s/--create-namespace/--set global.customCA.enabled=true --create-namespace/')
    
    echo "$formatted_command" > install.sh
    chmod +x install.sh
    
    echo "✅ Run.ai installation script created successfully!"
    echo "Executing installation script..."
    
    # Execute the installation script
    if ! ./install.sh; then
        echo "❌ Run.ai installation failed"
        exit 1
    fi
    
    # Wait for all pods in runai namespace to be ready
    echo "Waiting for all pods in the 'runai' namespace to be running..."
    while true; do
        NOT_READY=$(kubectl get pods -n runai --no-headers | grep -v "Running" | wc -l)
        if [ "$NOT_READY" -eq 0 ]; then
            echo "✅ All pods in 'runai' namespace are now running!"
            break
        else
            echo "⏳ Waiting... ($NOT_READY pods not ready)"
        fi
        sleep 5
    done
    
    echo "✅ Run.ai installation completed successfully!"
}

# Parse arguments
PART=""
DNS_NAME=""
RUNAI_VERSION=""
REPO_SECRET=""
KNATIVE_INSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -p)
            PART="$2"
            if [[ ! $PART =~ ^[1-4]$ ]]; then
                echo "Invalid part number: $PART"
                show_usage
            fi
            shift 2
            ;;
        --dns)
            DNS_NAME="$2"
            shift 2
            ;;
        --runai-version)
            RUNAI_VERSION="$2"
            shift 2
            ;;
        --repo-secret)
            REPO_SECRET="$2"
            if [ ! -f "$REPO_SECRET" ]; then
                echo "❌ Repository secret file not found: $REPO_SECRET"
                exit 1
            fi
            shift 2
            ;;
        --knative)
            KNATIVE_INSTALL=true
            shift
            ;;
        --internal-dns)
            INTERNAL_DNS=true
            shift
            ;;
        --ip)
            IP="$2"
            shift 2
            ;;
        --runai-only)
            RUNAI_ONLY=true
            shift
            ;;
        --cert)
            CERT_FILE="$2"
            if [ ! -f "$CERT_FILE" ]; then
                echo "❌ Certificate file not found: $CERT_FILE"
                exit 1
            fi
            shift 2
            ;;
        --key)
            KEY_FILE="$2"
            if [ ! -f "$KEY_FILE" ]; then
                echo "❌ Key file not found: $KEY_FILE"
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            ;;
    esac
done

# Call the appropriate function based on the selected part
case $PART in
    1)
        run_part1
        ;;
    2)
        run_part2
        ;;
    3)
        run_part3
        ;;
    4)
        run_part4
        ;;
    *)
        echo "Invalid part number: $PART"
        show_usage
        ;;
esac 