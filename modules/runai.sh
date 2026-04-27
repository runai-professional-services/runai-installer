#!/bin/bash
# shellcheck source=runai-wait-helpers.sh
# When this file is sourced from a mktemp copy in runai-installer.sh, BASH_SOURCE[0] is /tmp/...; resolve helpers from the real modules dir.
_runai_wait_helpers_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runai-wait-helpers.sh"
if [ ! -f "$_runai_wait_helpers_src" ] && [ -n "${RUNAI_INSTALLER_DIR:-}" ] && [ -f "$RUNAI_INSTALLER_DIR/modules/runai-wait-helpers.sh" ]; then
    _runai_wait_helpers_src="$RUNAI_INSTALLER_DIR/modules/runai-wait-helpers.sh"
fi
if [ ! -f "$_runai_wait_helpers_src" ]; then
    echo "❌ runai-wait-helpers.sh not found (expected next to runai.sh or \${RUNAI_INSTALLER_DIR}/modules/)." >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
. "$_runai_wait_helpers_src"
unset _runai_wait_helpers_src

# OpenShift: when using --no-cert, the runai cluster Helm pre-install still HTTPS GETs
# controlPlaneUrl/_version and must trust TLS for the *Route* hostname (default `*.apps` router).
# We create runai-ca-cert (same PEM in runai and runai-backend) and keep global.customCA.enabled on the cluster install.
# Run:ai mounts / uses that secret for in-cluster clients (e.g. HTTPS to the same FQDN) — the label
# run.ai/cluster-wide=true (applied later) is the product’s “use this CA for the stack”, not OpenShift’s
# cluster-wide /etc/pki. For the whole cluster, admins still configure Cluster Proxy spec.trustedCA
# (user-ca-bundle) separately if they need that.
#
# PEM source: (1) --openshift-ingress-cacert FILE, or (2) automatic: openshift-ingress/router-ca
# (router CA for `*.apps` *Routes*), or TLS probe to global.domain. Set RUNAI_OCP_NO_AUTO_INGRESS_CA=1 to skip
# and leave customCA out (old behavior; pre-install may fail on private CAs).
runai_inject_openshift_ingress_cacert_for_cluster_if_needed() {
    # Vanilla / non-OCP: no-op. All router-ca / runai-ca / auto-fetch logic only runs when
    # RUNAI_K8S_DISTRIBUTION=openshift (from --openshift). Does not change plain Kubernetes installs.
    RUNAI_INJECTED_OCP_CLUSTER_CA=0
    if [ "${RUNAI_K8S_DISTRIBUTION:-}" != "openshift" ] || [ "${NO_CERT:-false}" != true ]; then
        return 0
    fi

    local cacert="${RUNAI_OCP_INGRESS_CACERT_FILE:-}" auto_tmp=""
    local osh
    osh="${RUNAI_INSTALLER_DIR:+$RUNAI_INSTALLER_DIR/}modules/openshift.sh"
    [ -f "$osh" ] || osh="./modules/openshift.sh"
    if [ -n "$cacert" ]; then
        if [ ! -f "$cacert" ]; then
            echo -e "${RED}❌ --openshift-ingress-cacert: not a file: $cacert${NC}" >&2
            return 1
        fi
    elif [ "${RUNAI_OCP_NO_AUTO_INGRESS_CA:-false}" = true ] || [ "${RUNAI_OCP_NO_AUTO_INGRESS_CA:-0}" = 1 ]; then
        echo -e "${YELLOW}⚠️ OpenShift: RUNAI_OCP_NO_AUTO_INGRESS_CA set; skipping router/Route trust PEM and global.customCA for runai (cluster pre-install may fail on unknown CA).${NC}" >&2
        return 0
    else
        if [ ! -f "$osh" ]; then
            echo -e "${RED}❌ Missing $osh (cannot auto-fetch OpenShift default router CA for apps subdomains / Routes)${NC}" >&2
            return 1
        fi
        # shellcheck source=modules/openshift.sh
        . "$osh" || { echo -e "${RED}❌ Failed to source $osh${NC}" >&2; return 1; }
        auto_tmp=$(mktemp) || { echo -e "${RED}❌ mktemp failed${NC}" >&2; return 1; }
        if ! runai_openshift_auto_fetch_ingress_cacert_to "$auto_tmp" "${control_plane_domain:-$DNS_NAME}"; then
            rm -f "$auto_tmp" 2>/dev/null
            echo -e "${RED}❌ OpenShift: could not obtain trust material for the Route/HTTPS host ${control_plane_domain:-$DNS_NAME} (configmap router-ca, or TLS probe to that name).${NC}" >&2
            runai_openshift_print_ingress_cacert_hint "${control_plane_domain:-$DNS_NAME}" 2>&1
            echo -e "${YELLOW}  → Pass --openshift-ingress-cacert, or set RUNAI_OCP_NO_AUTO_INGRESS_CA=1 to skip (not recommended).${NC}" >&2
            return 1
        fi
        cacert="$auto_tmp"
        echo -e "${GREEN}✅ OpenShift: using auto-fetched ingress trust material for runai cluster (global.customCA)${NC}"
    fi

    if [ -z "$cacert" ] || [ ! -f "$cacert" ]; then
        return 0
    fi
    echo -e "${BLUE}OpenShift: applying default router / Route trust PEM to runai (secret runai-ca-cert) for cluster Helm customCA…${NC}"
    kubectl create namespace runai 2>/dev/null || true
    if ! kubectl create secret generic runai-ca-cert -n runai \
        --from-file=runai-ca.pem="$cacert" --dry-run=client -o yaml | kubectl apply -f -; then
        if [ -n "$auto_tmp" ] && [ "$auto_tmp" = "$cacert" ]; then
            rm -f "$auto_tmp" 2>/dev/null
        fi
        echo -e "${RED}❌ Could not create secret runai-ca-cert in runai (check RBAC)${NC}" >&2
        return 1
    fi
    # Same trust bundle as create_certificates: backend may read it; must apply before we rm auto_tmp.
    kubectl create namespace runai-backend 2>/dev/null || true
    if ! kubectl create secret generic runai-ca-cert -n runai-backend \
        --from-file=runai-ca.pem="$cacert" --dry-run=client -o yaml | kubectl apply -f -; then
        echo -e "${YELLOW}⚠️ OpenShift: could not mirror runai-ca-cert to runai-backend (RBAC?); runai namespace secret is the minimum for the cluster release.${NC}" >&2
    else
        echo -e "${GREEN}✅ OpenShift: runai-ca-cert also applied in runai-backend (same CA as in-cluster clients that trust customCA).${NC}"
    fi
    if [ -n "$auto_tmp" ] && [ "$auto_tmp" = "$cacert" ]; then
        rm -f "$auto_tmp" 2>/dev/null
    fi
    RUNAI_INJECTED_OCP_CLUSTER_CA=1
    return 0
}

# Function to create namespaces
create_namespaces() {
    echo -e "${BLUE}Creating namespaces...${NC}"
    kubectl create namespace runai 2>/dev/null || true
    kubectl create namespace runai-backend 2>/dev/null || true
    echo -e "${GREEN}✅ Namespaces created${NC}"
}

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

# Function to get authentication token
get_auth_token() {
    local max_attempts=50
    local attempt=1
    local auth_url="https://$control_plane_domain/auth/realms/runai/protocol/openid-connect/token"
    
    echo -ne "Waiting for back-end token...\r"
    
    while [ $attempt -le $max_attempts ]; do
        # Store the raw response for debugging
        raw_response=$(curl --insecure --silent --location --request POST "$auth_url" \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode 'grant_type=password' \
            --data-urlencode 'client_id=runai' \
            --data-urlencode 'username=test@run.ai' \
            --data-urlencode 'password=Abcd!234' \
            --data-urlencode 'scope=openid' \
            --data-urlencode 'response_type=id_token')

        # Debug output
        echo "Raw response: $raw_response" >> "$LOG_FILE"

        # Try to parse the token, with error handling
        if [ -n "$raw_response" ]; then
            # Check if the response is valid JSON
            if echo "$raw_response" | jq . >/dev/null 2>&1; then
                token=$(echo "$raw_response" | jq -r '.access_token // empty')
                if [ -n "$token" ] && [ "$token" != "null" ]; then
                    return 0
                fi
            fi
        fi

        sleep 5
        ((attempt++))
    done
    
    return 1
}

# Function to check if authentication service is responding
check_auth_service() {
    local max_attempts=50
    local attempt=1
    local auth_url="https://$control_plane_domain/auth/realms/runai/protocol/openid-connect/token"
    
    echo -e "${BLUE}Checking if authentication service is responding...${NC}"
    
    while [ $attempt -le $max_attempts ]; do
        # Try a POST request with minimal data
        if curl --insecure --silent --request POST "$auth_url" \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode 'grant_type=password' \
            --data-urlencode 'client_id=runai' \
            --data-urlencode 'username=test@run.ai' \
            --data-urlencode 'password=Abcd!234' \
            --data-urlencode 'scope=openid' \
            --data-urlencode 'response_type=id_token' >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Authentication service is responding${NC}"
            return 0
        fi
        
        echo -ne "⏳ Waiting for authentication service to respond... (Attempt $attempt/$max_attempts)\r"
        sleep 5
        ((attempt++))
    done
    
    echo -e "\n${RED}❌ Authentication service is not responding after $max_attempts attempts${NC}"
    return 1
}

# Register cluster in control plane API if missing (idempotent; safe to re-run).
ensure_cluster_registered() {
    local clusters_json
    clusters_json=$(curl --insecure --silent -X GET \
        "https://$control_plane_domain/api/v1/clusters" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json') || return 1
    uuid=$(echo "$clusters_json" | jq -r ".[] | select(.name | contains(\"$cluster_name\")) | .uuid" | head -1)
    if [ -n "$uuid" ] && [ "$uuid" != "null" ]; then
        echo -e "${GREEN}✅ Cluster $cluster_name already registered (uuid=$uuid); skipping create.${NC}"
        return 0
    fi
    echo -e "${BLUE}Creating cluster $cluster_name...${NC}"
    if ! log_command "curl --insecure --silent -X POST \"https://$control_plane_domain/api/v1/clusters\" -H 'accept: application/json' -H \"Authorization: Bearer $token\" -H 'Content-Type: application/json' -d '{\"name\": \"${cluster_name}\", \"version\": \"${cluster_version}\"}'" "Create cluster"; then
        return 1
    fi
    clusters_json=$(curl --insecure --silent -X GET \
        "https://$control_plane_domain/api/v1/clusters" \
        -H 'accept: application/json' \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json') || return 1
    uuid=$(echo "$clusters_json" | jq -r ".[] | select(.name | contains(\"$cluster_name\")) | .uuid" | head -1)
    if [ -z "$uuid" ] || [ "$uuid" = "null" ]; then
        echo -e "${RED}❌ Could not resolve cluster UUID after create${NC}" >&2
        return 1
    fi
    return 0
}

# Function to install Run.ai
install_runai() {
    # Create namespaces first
    create_namespaces

    # NGC: docker-registry secret for nvcr.io (required for image pulls; full install and cluster-only)
    if [ "${RUNAI_ARTIFACT_SOURCE:-jfrog}" = ngc ] && [ "${AIR_GAPPED_MODE:-false}" != true ]; then
        echo -e "${BLUE}Applying NGC nvcr.io pull secret (runai-reg-creds)...${NC}"
        if ! runai_ngc_apply_image_pull_secrets; then
            echo -e "${RED}❌ NGC image pull secret setup failed${NC}"
            exit 1
        fi
    fi

    # If not in cluster-only mode, install the backend
    if [ "$CLUSTER_ONLY" != true ]; then
        # Certificate secrets are already created by the certificates module
        # No need to recreate them here to avoid conflicts

        # Apply repository secret if provided
        if [ -n "$REPO_SECRET" ]; then
            echo -e "${BLUE}Applying repository secret from $REPO_SECRET...${NC}"
            if ! log_command "kubectl apply -f \"$REPO_SECRET\"" "Apply repository secret"; then
                echo -e "${YELLOW}⚠️ Warning: Failed to apply repository secret from $REPO_SECRET, continuing...${NC}"
            else
                echo -e "${GREEN}✅ Repository secret applied successfully from $REPO_SECRET${NC}"
            fi
        fi

        # Install Run.ai backend (JFrog or NGC)
        echo -e "${BLUE}Installing Run.ai backend (artifact source: ${RUNAI_ARTIFACT_SOURCE:-jfrog})...${NC}"
        case "${RUNAI_ARTIFACT_SOURCE:-jfrog}" in
            ngc)
                if ! runai_ngc_add_repo; then
                    echo -e "${RED}❌ Failed to add NGC Helm repo${NC}"
                    exit 1
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

        local CP_CHART
        case "${RUNAI_ARTIFACT_SOURCE:-jfrog}" in
            ngc) CP_CHART=$(runai_ngc_control_plane_chart) ;;
            *) CP_CHART=$(runai_jfrog_control_plane_chart) ;;
        esac

        HELM_OPTS="--set global.domain=$DNS_NAME"
        if [ "$NO_CERT" != true ]; then
            HELM_OPTS="$HELM_OPTS --set global.customCA.enabled=true"
        fi
        if [ "${RUNAI_K8S_DISTRIBUTION:-}" = "openshift" ]; then
            HELM_OPTS="$HELM_OPTS --set global.config.kubernetesDistribution=openshift"
        fi
        # OpenShift: platform Routes only — do not set global.ingress.ingressClass (spurious env must not add haproxy/nginx).
        if [ "${RUNAI_K8S_DISTRIBUTION:-}" != "openshift" ]; then
            if [ -n "${RUNAI_INGRESS_CLASS:-}" ]; then
                HELM_OPTS="$HELM_OPTS --set global.ingress.ingressClass=$RUNAI_INGRESS_CLASS"
            elif [ "${INSTALL_HAPROXY:-false}" = true ]; then
                HELM_OPTS="$HELM_OPTS --set global.ingress.ingressClass=haproxy"
            fi
        fi

        if ! log_command "helm upgrade --install runai-backend -n runai-backend $CP_CHART --version \"$RUNAI_VERSION\" $HELM_OPTS > /dev/null 2>&1" "Install Run.ai backend"; then
            echo -e "${RED}❌ Failed to install Run.ai backend${NC}"
            exit 1
        else
            echo -e "${GREEN}✅ Run.ai backend installation started${NC}"
        fi

        # Wait for pods to be ready (recompute each tick: pod count can grow during rollout)
        echo -e "${BLUE}Waiting for Run.ai backend pods to be ready...${NC}"
        while true; do
            read -r TOTAL_PODS READY_PODS < <(runai_pod_readiness_counts runai-backend)
            HSTAT=$(runai_helm_info_status runai-backend runai-backend)
            NOT_READY=$((TOTAL_PODS - READY_PODS))

            echo -ne "⏳ Waiting... ($READY_PODS ready of $TOTAL_PODS, Helm runai-backend: $HSTAT)    \r"

            if [ "$NOT_READY" -eq 0 ] && [ "$TOTAL_PODS" -gt 0 ] && runai_helm_release_is_deployed runai-backend runai-backend; then
                echo -e "\n${GREEN}✅ Run.ai backend pods are ready and Helm is deployed (runai-backend)${NC}"
                break
            fi
            sleep 5
        done

        # Set up environment variables
        export control_plane_domain=$DNS_NAME
        export cluster_version=$RUNAI_VERSION
        export cluster_name=runai-cluster

        # Check if authentication service is responding before trying to get token
        if ! check_auth_service; then
            echo -e "${RED}❌ Authentication service is not available. Please check the backend installation.${NC}"
            exit 1
        fi

        # Get authentication token
        if ! get_auth_token; then
            echo -e "${RED}❌ Failed to get authentication token. Please check the backend installation.${NC}"
            exit 1
        fi

        if ! ensure_cluster_registered; then
            echo -e "${RED}❌ Failed to register cluster in control plane${NC}"
            exit 1
        fi

        # Get installation string
        echo -e "${BLUE}Getting installation information...${NC}"
        while true; do
            installationStr=$(curl --insecure --silent "https://$control_plane_domain/api/v1/clusters/$uuid/cluster-install-info?version=$cluster_version" \
                -H 'accept: application/json' \
                -H "Authorization: Bearer $token" \
                -H 'Content-Type: application/json')

            echo "$installationStr" > input.json

            if grep -q "helm" input.json; then
                break
            fi
            echo -ne "⏳ Waiting for valid installation information...\r"
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

        # Check if authentication service is responding before trying to get token
        if ! check_auth_service; then
            echo -e "${RED}❌ Authentication service is not available. Please check the backend installation.${NC}"
            exit 1
        fi

        # Get authentication token
        if ! get_auth_token; then
            echo -e "${RED}❌ Failed to get authentication token. Please check the backend installation.${NC}"
            exit 1
        fi

        if ! ensure_cluster_registered; then
            echo -e "${RED}❌ Failed to register cluster in control plane${NC}"
            exit 1
        fi

        # Get installation string
        echo -e "${BLUE}Getting installation information...${NC}"
        while true; do
            installationStr=$(curl --insecure --silent "https://$control_plane_domain/api/v1/clusters/$uuid/cluster-install-info?version=$cluster_version" \
                -H 'accept: application/json' \
                -H "Authorization: Bearer $token" \
                -H 'Content-Type: application/json')

            echo "$installationStr" > input.json

            if grep -q "helm" input.json; then
                break
            fi
            echo -ne "⏳ Waiting for valid installation information...\r"
            sleep 5
        done
    fi

    # Create installation script
    echo -e "${BLUE}Creating installation script...${NC}"
    installation_str=$(jq -r '.installationStr' input.json)

    if ! runai_inject_openshift_ingress_cacert_for_cluster_if_needed; then
        echo -e "${RED}❌ OpenShift apps-route CA injection failed${NC}" >&2
        exit 1
    fi
    if [ "$NO_CERT" = true ] && [ "${RUNAI_INJECTED_OCP_CLUSTER_CA:-0}" -eq 1 ]; then
        echo -e "${GREEN}✅ runai namespace has runai-ca-cert; cluster Helm will use customCA for HTTPS to ${control_plane_domain:-$DNS_NAME}${NC}"
    fi

    # If NO_CERT is true, remove global.customCA — unless we injected the OpenShift route CA
    if [ "$NO_CERT" = true ] && [ "${RUNAI_INJECTED_OCP_CLUSTER_CA:-0}" -ne 1 ]; then
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

    # Execute the installation script silently
    echo -e "${BLUE}Installing Run.ai cluster components...${NC}"

    # Log the full command
    echo "Executing installation commands:" >> "$LOG_FILE"
    echo "$(cat install.sh)" >> "$LOG_FILE"

    # Execute install.sh with progress (suppress Helm output)
    if ./install.sh > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Run.ai cluster installation started${NC}"
    else
        echo -e "${RED}❌ Run.ai installation failed. Please check the logs at $LOG_FILE for details${NC}"
        exit 1
    fi

    # Label the Run.ai CA certificate secret
    echo -e "${BLUE}Labeling Run.ai CA certificate secret...${NC}"
    if log_command "kubectl label secret runai-ca-cert -n runai run.ai/cluster-wide=true run.ai/name=runai-ca-cert --overwrite" "Label Run.ai CA certificate secret"; then
        echo -e "${GREEN}✅ Run.ai CA certificate secret labeled successfully${NC}"
    else
        echo -e "${YELLOW}⚠️ Warning: Failed to label Run.ai CA certificate secret, continuing...${NC}"
    fi

    # Wait for all pods in runai namespace to be ready (recompute each tick; total can
    # increase while Helm rolls out, which previously made "Running > total" and hung)
    echo -e "${BLUE}Waiting for Run.ai cluster pods to be ready...${NC}"
    while true; do
        read -r TOTAL_PODS READY_PODS < <(runai_pod_readiness_counts runai)
        HSTAT=$(runai_helm_info_status runai runai)
        NOT_READY=$((TOTAL_PODS - READY_PODS))

        echo -ne "⏳ Waiting... ($READY_PODS ready of $TOTAL_PODS, Helm runai: $HSTAT)    \r"

        if [ "$NOT_READY" -eq 0 ] && [ "$TOTAL_PODS" -gt 0 ] && runai_helm_release_is_deployed runai runai; then
            echo -e "\n${GREEN}✅ Run.ai cluster pods are ready and Helm is deployed (runai)${NC}"
            break
        fi
        sleep 5
    done

    echo -e "${GREEN}✅ Run.ai installation completed successfully!${NC}"
} 

