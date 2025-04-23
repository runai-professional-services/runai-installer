#!/bin/bash

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
} 