




Search NVIDIA Corporation


1

15
2


Home
1

DMs
2

5
Activity
3

Later
4

More
0

Direct messages

Unreads

 
Find a DM

Chen Amiel
Thursday
You: in teams

Omer Dayan
Thursday
yes

Rom Freiman, Tal Levy
Thursday
שולח לך עוגת פרג של השף מס' אחד בצרפת ביום הזה, קירזון אתה אני יודע שויסקי יותר מעניין ממתוק :wink:

Rom Freiman
Thursday
So, yea. End of April if there are no surprises should be the release date

Alexander (Sasha) Fridman
Thursday
yes, in the office.…

Nir Lubliner, Tomer Kun
Thursday
Sure

Everett Lacey
Wednesday
You: Maube just mayre last test

Lalit Adithya V:no_entry:
Wednesday
So it is working for you now? Sorry, it is not clear

Noa Neria
Wednesday
You: Distributed inference projects 

Shay Asoolin
Wednesday
You: מעניין

Guy Meltzer
Wednesday
סבבה אח

Juana Nakfour:no_entry:
Wednesday
You: Hi Thanks !

Panos Lampropoulos:nvidia_eye:
Tuesday
You: :slightly_smiling_face:

Nir Lubliner, Robert Magno
Tuesday
OK invite shared for next week 11th

Shahar Siegman
Tuesday
You: כן - יאצ לי ממש לחוץ היום

Oz Bar-Shalom
Tuesday
לא כל כך הבנתי :sweat_smile: צריך הסבר

Tomer Kun
Tuesday
You: סבבה

Konstantin Cvetanov, Shahar Siegman, Tsila Ben Moshe Hazan
Monday
You: Please send some dates …

Itay Anavian
Monday
You: to test auto-scale…

Moran Guy
March 2nd
You: רק לוודא שהכל מובן :slightly_smiling_face:

Konstantin Cvetanov
February 27th
thank you !!

Eran Eliahu
February 27th
You: Top5 :slightly_smiling_face:

Brandon Golway
February 26th
You: Im working on something that might help

Robert Magno
February 26th
hyperpod should just be a regular EKS install, the only modification we did was for something around classic load balancers but that isnt required anymore

Dhaval Dave, Minakshi Sinha, Sourav Jyoti Das
February 26th
Sourav Jyoti Das moved some of the messages from this conversation to one with Clay Bunce, Dhaval Dave, and 6 others.



Everett Lacey




Messages

More

CanvasListBookmark folder


Search files
Photos and videos
See all










Documents

one-click-install-prod.sh
Shared by Erez Kirson on Feb 25th




appliance.tar
Shared by Erez Kirson on Feb 24th



runai-wizard
Shared by Erez Kirson on Feb 12th


File Details

one-click-install-prod.sh
Erez Kirson (you)
February 25th at 10:43 AM
Private file

#!/bin/bash
​
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
​
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
​
echo -e "\n\033[33mPress Enter to continue...\033[0m"
read
​
# Add at the top of the script, after the initial variable declarations
PART3_EXECUTED=false
​
# Variables for internal DNS
INTERNAL_DNS=false
FQDN=""
IP=""
RUNAI_ONLY=false  # Add this variable for the new option
​
# Variables for certificates
CERT_FILE=""
KEY_FILE=""
​
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
​
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
​
    # Check and install python3-pip
    if ! command -v pip3 &> /dev/null; then
        echo "Installing python3-pip..."
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip > /dev/null 2>&1; then
            echo "❌ Failed to install python3-pip"
            exit 1
        fi
        echo "✅ python3-pip installed successfully"
    fi
​
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
​
    # Ensure we're in the kubespray directory
    if [ ! -d "kubespray" ]; then
        echo "Error: This script must be run from the directory containing kubespray!"
        exit 1
    fi
    cd kubespray
​
    # Get hostname
    HOSTNAME=$(hostname)
​
    # Create inventory.ini with proper hostname
    cat > ./inventory/runai/inventory.ini << EOF
[kube_control_plane]
${HOSTNAME} ansible_host=${HOSTNAME}
​
[etcd:children]
kube_control_plane
​
[kube_node]
${HOSTNAME} ansible_host=${HOSTNAME}
EOF
​
    echo "Installation configuration completed successfully!"
    echo "inventory.ini has been created with hostname: $HOSTNAME"
​
    # Get current user
    CURRENT_USER=$(whoami)
​
    # Create sudoers file for current user
    echo "Creating sudoers file for $CURRENT_USER..."
    SUDOERS_FILE="/etc/sudoers.d/$CURRENT_USER"
    if ! sudo bash -c "echo '$CURRENT_USER ALL=(ALL) NOPASSWD: ALL' > $SUDOERS_FILE"; then
        echo "❌ Failed to create sudoers file for $CURRENT_USER"
        exit 1
    fi
​
    # Set correct permissions for sudoers file
    if ! sudo chmod 0440 $SUDOERS_FILE; then
        echo "❌ Failed to set permissions on sudoers file"
        exit 1
    fi
    echo "✅ Sudoers file created successfully for $CURRENT_USER"
​
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
​
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
​
    # Test sudo access
    if ! sudo -n true 2>/dev/null; then
        echo "Please enter your password to verify sudo access:"
        sudo ls > /dev/null
    fi
​
    echo "Setup completed successfully!"
​
    # Install Python requirements
    echo "Installing Python requirements..."
    if ! pip install -r requirements.txt; then
        echo "❌ Failed to install Python requirements. Please check your Python installation."
        exit 1
    fi
    echo "✅ Python requirements installed successfully!"
​
    # Create .kube directory in home directory (only once, at the beginning)
    echo "Creating .kube directory..."
    mkdir -p $HOME/.kube
    if [ ! -d $HOME/.kube ]; then
        echo "❌ Failed to create .kube directory"
        exit 1
    fi
    echo "✅ .kube directory created successfully"
​
    # Ensure correct PATH
    REQUIRED_PATH="/home/$CURRENT_USER/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
    if [[ "$PATH" != *"/home/$CURRENT_USER/.local/bin"* ]]; then
        echo "Updating PATH environment..."
        export PATH="/home/$CURRENT_USER/.local/bin:$PATH"
    fi
​
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
​
    echo "This may take 15-30 minutes. Please be patient."
​
    # Run ansible-playbook if Kubernetes is not installed
    if ! ansible-playbook -i inventory/runai/inventory.ini cluster.yml -b; then
        echo -e "\n❌ Kubernetes cluster installation failed."
        exit 1
    fi
​
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
                echo "⚠️ Warning: Fa...
Shared in

Everett Lacey
everett_lacey
14 days ago




