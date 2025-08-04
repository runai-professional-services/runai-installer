#!/bin/bash

# Function to handle air-gapped installation
handle_air_gapped() {
    echo -e "${BLUE}Starting air-gapped installation...${NC}"
    
    # Validate required air-gapped parameters
    if [ -z "$AIR_GAPPED_FILE" ]; then
        echo -e "${RED}❌ Error: --file is required for air-gapped installation${NC}"
        return 1
    fi
    
    if [ -z "$REGISTRY_URL" ]; then
        echo -e "${RED}❌ Error: --registry is required for air-gapped installation${NC}"
        return 1
    fi
    
    if [ -z "$REGISTRY_SECRET_FILE" ]; then
        echo -e "${RED}❌ Error: --registry-secret is required for air-gapped installation${NC}"
        return 1
    fi
    
    # Handle certificate setup if not using --no-cert
    if [ "$NO_CERT" != true ]; then
        echo -e "${BLUE}Setting up certificates for air-gapped installation...${NC}"
        
        # Handle custom certificates if provided
        if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
            echo -e "${BLUE}Using custom certificates...${NC}"
            export CERT="$CERT_FILE"
            export KEY="$KEY_FILE"
            
            if [ -n "$CA_CERT_FILE" ]; then
                export FULL="$CA_CERT_FILE"
            else
                export FULL="$CERT_FILE"
            fi
        else
            echo -e "${BLUE}Generating self-signed certificates...${NC}"
            # Generate self-signed certificates
            source ./modules/certificates.sh
            setup_certificates
        fi
    else
        echo -e "${BLUE}Skipping certificate setup as requested with --no-cert flag...${NC}"
    fi
    
    # Check if the tar.gz file exists
    if [ ! -f "$AIR_GAPPED_FILE" ]; then
        echo -e "${RED}❌ Error: Air-gapped file not found: $AIR_GAPPED_FILE${NC}"
        return 1
    fi
    
    # Check if the registry secret file exists
    if [ ! -f "$REGISTRY_SECRET_FILE" ]; then
        echo -e "${RED}❌ Error: Registry secret file not found: $REGISTRY_SECRET_FILE${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Creating air-gapped directory...${NC}"
    
    # Create air-gapped directory
    AIR_GAPPED_DIR="./air-gapped"
    mkdir -p "$AIR_GAPPED_DIR"
    
    # Get the filename from the path
    FILENAME=$(basename "$AIR_GAPPED_FILE")
    
    echo -e "${BLUE}Copying air-gapped file to air-gapped directory...${NC}"
    
    # Copy the file to air-gapped directory
    if ! cp "$AIR_GAPPED_FILE" "$AIR_GAPPED_DIR/"; then
        echo -e "${RED}❌ Error: Failed to copy air-gapped file to air-gapped directory${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Changing to air-gapped directory...${NC}"
    
    # Store current directory
    ORIGINAL_DIR=$(pwd)
    
    # Change to air-gapped directory
    cd "$AIR_GAPPED_DIR" || {
        echo -e "${RED}❌ Error: Failed to change to air-gapped directory${NC}"
        return 1
    }
    
    echo -e "${BLUE}Extracting air-gapped file...${NC}"
    
    # Extract the tar.gz file (suppress output)
    if ! tar -xzf "$FILENAME" > /dev/null 2>&1; then
        echo -e "${RED}❌ Error: Failed to extract air-gapped file${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Air-gapped file extracted successfully${NC}"
    
    # Configure BCM if requested
    if [ "$BCM_CONFIG" = true ]; then
        echo -e "${BLUE}Configuring Bright Cluster Manager...${NC}"
        source ./modules/bcm.sh
        if configure_bcm; then
            echo -e "${GREEN}✅ Bright Cluster Manager configuration completed successfully${NC}"
        else
            echo -e "${RED}❌ Bright Cluster Manager configuration failed${NC}"
            return 1
        fi
    fi
    
    # Configure internal DNS if requested
    if [ "$INTERNAL_DNS" = true ]; then
        echo -e "${BLUE}Configuring internal DNS...${NC}"
        source ./modules/dns.sh
        patch_coredns
    fi
    
    # Apply registry secret to runai namespace
    echo -e "${BLUE}Applying registry secret to runai namespace...${NC}"
    
    if ! log_command "kubectl apply -f $REGISTRY_SECRET_FILE -n runai" "Apply registry secret to runai namespace"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to apply registry secret to runai namespace${NC}"
        echo -e "${YELLOW}⚠️ Continuing installation anyway...${NC}"
    else
        echo -e "${GREEN}✅ Registry secret applied to runai namespace successfully${NC}"
    fi
    
    # Apply registry secret to runai-backend namespace
    echo -e "${BLUE}Applying registry secret to runai-backend namespace...${NC}"
    
    if ! log_command "kubectl apply -f $REGISTRY_SECRET_FILE -n runai-backend" "Apply registry secret to runai-backend namespace"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to apply registry secret to runai-backend namespace${NC}"
        echo -e "${YELLOW}⚠️ Continuing installation anyway...${NC}"
    else
        echo -e "${GREEN}✅ Registry secret applied to runai-backend namespace successfully${NC}"
    fi
    
    # Export registry URL and domain
    echo -e "${BLUE}Setting registry URL: $REGISTRY_URL${NC}"
    export REGISTRY_URL="$REGISTRY_URL"
    echo -e "${BLUE}Setting domain: $DNS_NAME${NC}"
    export DOMAIN="$DNS_NAME"
    
    # Check if setup.sh exists
    if [ ! -f "./setup.sh" ]; then
        echo -e "${RED}❌ Error: setup.sh not found in air-gapped directory${NC}"
        return 1
    fi
    
    # Make setup.sh executable
    chmod +x ./setup.sh
    
    echo -e "${BLUE}Running setup.sh from air-gapped directory...${NC}"
    
    # Run setup.sh directly to show progress in real-time
    if ! ./setup.sh; then
        echo -e "${RED}❌ Error: Failed to run setup.sh${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ All files uploaded successfully${NC}"
    
    # Install Run.ai backend using helm
    echo -e "${BLUE}Installing Run.ai backend...${NC}"
    if [ -n "$DOMAIN" ]; then
        if ! log_command "helm upgrade -i runai-backend charts/control-plane.tgz --set global.domain=\"$DOMAIN\" --set global.customCA.enabled=true -n runai-backend -f custom-env.yaml" "Install Run.ai backend"; then
            echo -e "${RED}❌ Failed to install Run.ai backend${NC}"
            return 1
        fi
        echo -e "${GREEN}✅ Run.ai backend installed successfully!${NC}"
    else
        echo -e "${RED}❌ Error: DOMAIN environment variable is not set${NC}"
        return 1
    fi
    
    # Wait for backend pods to be ready
    echo -e "${BLUE}Waiting for Run.ai backend pods to be ready...${NC}"
    while true; do
        TOTAL_PODS=$(kubectl get pods -n runai-backend --no-headers | wc -l)
        RUNNING_PODS=$(kubectl get pods -n runai-backend --no-headers | grep "Running" | wc -l)
        NOT_READY=$((TOTAL_PODS - RUNNING_PODS))

        echo -ne "⏳ Waiting... ($RUNNING_PODS pods Running out of $TOTAL_PODS)    \r"

        if [ "$NOT_READY" -eq 0 ]; then
            echo -e "\n${GREEN}✅ All Run.ai backend pods are now running!${NC}"
            break
        fi
        sleep 5
    done
    
    # Set up environment variables for API calls
    export control_plane_domain=$DNS_NAME
    export cluster_version=$RUNAI_VERSION
    export cluster_name=runai-cluster
    
    # Check if authentication service is responding
    echo -e "${BLUE}Checking if authentication service is responding...${NC}"
    local max_attempts=50
    local attempt=1
    local auth_url="https://$control_plane_domain/auth/realms/runai/protocol/openid-connect/token"
    
    while [ $attempt -le $max_attempts ]; do
        if curl --insecure --silent --request POST "$auth_url" \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode 'grant_type=password' \
            --data-urlencode 'client_id=runai' \
            --data-urlencode 'username=test@run.ai' \
            --data-urlencode 'password=Abcd!234' \
            --data-urlencode 'scope=openid' \
            --data-urlencode 'response_type=id_token' >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Authentication service is responding${NC}"
            break
        fi
        
        echo -ne "⏳ Waiting for authentication service to respond... (Attempt $attempt/$max_attempts)\r"
        sleep 5
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        echo -e "\n${RED}❌ Authentication service is not responding after $max_attempts attempts${NC}"
        return 1
    fi
    
    # Get authentication token
    echo -e "${BLUE}Getting authentication token...${NC}"
    local token=""
    attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        raw_response=$(curl --insecure --silent --location --request POST "$auth_url" \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode 'grant_type=password' \
            --data-urlencode 'client_id=runai' \
            --data-urlencode 'username=test@run.ai' \
            --data-urlencode 'password=Abcd!234' \
            --data-urlencode 'scope=openid' \
            --data-urlencode 'response_type=id_token')

        if [ -n "$raw_response" ]; then
            if echo "$raw_response" | jq . >/dev/null 2>&1; then
                token=$(echo "$raw_response" | jq -r '.access_token // empty')
                if [ -n "$token" ] && [ "$token" != "null" ]; then
                    echo -e "${GREEN}✅ Authentication token obtained${NC}"
                    break
                fi
            fi
        fi

        echo -ne "⏳ Waiting for authentication token... (Attempt $attempt/$max_attempts)\r"
        sleep 5
        ((attempt++))
    done
    
    if [ -z "$token" ]; then
        echo -e "\n${RED}❌ Failed to get authentication token${NC}"
        return 1
    fi
    
    # Create cluster and get UUID
    echo -e "${BLUE}Creating cluster...${NC}"
    if ! curl --insecure --silent -X 'POST' "https://$control_plane_domain/api/v1/clusters" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "{\"name\": \"${cluster_name}\", \"version\": \"${cluster_version}\"}" >/dev/null 2>&1; then
        echo -e "${RED}❌ Failed to create cluster${NC}"
        return 1
    fi
    
    # Get UUID
    echo -e "${BLUE}Getting cluster UUID...${NC}"
    uuid=$(curl --insecure --silent -X 'GET' \
        "https://$control_plane_domain/api/v1/clusters" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' | jq ".[] | select(.name | contains(\"$cluster_name\"))" | jq -r .uuid)
    
    if [ -z "$uuid" ] || [ "$uuid" = "null" ]; then
        echo -e "${RED}❌ Failed to get cluster UUID${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Cluster created with UUID: $uuid${NC}"
    
    # Get installation string
    echo -e "${BLUE}Getting installation information...${NC}"
    local installationStr=""
    attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        installationStr=$(curl --insecure --silent "https://$control_plane_domain/api/v1/clusters/$uuid/cluster-install-info?version=$cluster_version" \
            -H 'accept: application/json' \
            -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json')

        if echo "$installationStr" | grep -q "helm"; then
            echo -e "${GREEN}✅ Installation information obtained${NC}"
            break
        fi
        
        echo -ne "⏳ Waiting for valid installation information... (Attempt $attempt/$max_attempts)\r"
        sleep 5
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        echo -e "\n${RED}❌ Failed to get installation information${NC}"
        return 1
    fi
    
    # Extract and format the installation command
    echo -e "${BLUE}Installing Run.ai cluster components...${NC}"
    installation_str=$(echo "$installationStr" | jq -r '.installationStr')
    
    # Format the command to use local chart instead of remote repo and remove helm repo commands
    formatted_command=$(echo "$installation_str" | sed -E '
        s/helm repo add runai[^\\]*\\?//g;
        s/helm repo update\\?//g;
        s/helm upgrade -i runai-cluster runai\/runai-cluster/helm upgrade -i runai-cluster charts\/runai-cluster.tgz/g;
        s/\\ --set /\n--set /g;
        s/--set cluster.url=/--set cluster.url=/g;
        s/--version="[^"]*"//g;
        s/--create-namespace/--set global.customCA.enabled=true --create-namespace/')
    
    # Add our registry setting
    formatted_command=$(echo "$formatted_command" | sed "s|--create-namespace|--set global.image.registry=$REGISTRY_URL --create-namespace|")
    
    echo "$formatted_command" > install.sh
    chmod +x install.sh
    
    # Log the cluster installation command
    echo "Cluster installation command:" >> "$LOG_FILE"
    echo "$(cat install.sh)" >> "$LOG_FILE"
    
    # Execute the installation script with retry logic
    local max_retries=3
    local retry_count=0
    local install_success=false
    
    while [ $retry_count -lt $max_retries ] && [ "$install_success" = false ]; do
        if [ $retry_count -gt 0 ]; then
            echo -e "${YELLOW}⚠️ Retrying cluster installation (Attempt $((retry_count + 1))/$max_retries)...${NC}"
            sleep 10  # Wait 10 seconds before retry
        fi
        
        if log_command "./install.sh" "Install Run.ai cluster components"; then
            echo -e "${GREEN}✅ Run.ai cluster installation started${NC}"
            install_success=true
        else
            echo -e "${RED}❌ Run.ai cluster installation failed (Attempt $((retry_count + 1))/$max_retries)${NC}"
            ((retry_count++))
        fi
    done
    
    if [ "$install_success" = false ]; then
        echo -e "${RED}❌ Run.ai cluster installation failed after $max_retries attempts${NC}"
        return 1
    fi
    
    # Wait for cluster pods to be ready
    echo -e "${BLUE}Waiting for Run.ai cluster pods to be ready...${NC}"
    while true; do
        TOTAL_PODS=$(kubectl get pods -n runai --no-headers | wc -l)
        RUNNING_PODS=$(kubectl get pods -n runai --no-headers | grep "Running" | wc -l)
        NOT_READY=$((TOTAL_PODS - RUNNING_PODS))

        if [ "$NOT_READY" -eq 0 ]; then
            echo -e "${GREEN}✅ All Run.ai cluster pods are ready${NC}"
            break
        fi
        sleep 5
    done
    
    echo -e "${GREEN}✅ Air-gapped installation completed successfully${NC}"
    
    # Return to original directory for additional installations
    cd "$ORIGINAL_DIR" || {
        echo -e "${YELLOW}⚠️ Warning: Failed to return to original directory${NC}"
        return 1
    }
    
    # Note: Additional components will be installed by the main installer after this function returns
    # The main installer will handle: nginx, prometheus, gpu-operator, training, lws, storage-class, knative, etc.
    
    return 0
} 