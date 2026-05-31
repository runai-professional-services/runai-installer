#!/bin/bash
# HAProxy Kubernetes Ingress (HAProxyTech), per NVIDIA Run:ai “Migrate from NGINX to HAProxy Ingress”
# (Vanilla Kubernetes): https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/upgrade
# Ingress class for Run:ai charts: haproxy (see --use-haproxy in runai-installer.sh).
#
# Default Service/NS match: helm upgrade --install haproxy-kubernetes-ingress ... -n haproxy-controller
# → Service haproxy-kubernetes-ingress in namespace haproxy-controller (override via env if needed).
#
# Service externalIPs: set HAPROXY_EXTERNAL_IPS (comma-separated) or pass a single IP as IP_ADDRESS (--ip).
# runai-installer: --haproxy-external-ips sets HAPROXY_EXTERNAL_IPS and overrides --ip for HAProxy only.

HAPROXY_NAMESPACE="${HAPROXY_NAMESPACE:-haproxy-controller}"
HAPROXY_SERVICE_NAME="${HAPROXY_SERVICE_NAME:-haproxy-kubernetes-ingress}"

# Fills HAPROXY_EXT_IPS: prefer HAPROXY_EXTERNAL_IPS (comma-separated), else IP_ADDRESS (single).
haproxy_resolve_external_ips() {
    HAPROXY_EXT_IPS=()
    local raw="${HAPROXY_EXTERNAL_IPS:-}"
    raw="${raw//$'\r'/}"
    if [ -n "$raw" ]; then
        local parts
        IFS=',' read -ra parts <<< "$raw"
        local part
        for part in "${parts[@]}"; do
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            [ -n "$part" ] && HAPROXY_EXT_IPS+=("$part")
        done
    fi
    if [ ${#HAPROXY_EXT_IPS[@]} -eq 0 ] && [ -n "${IP_ADDRESS:-}" ]; then
        HAPROXY_EXT_IPS=("$IP_ADDRESS")
    fi
    [ ${#HAPROXY_EXT_IPS[@]} -gt 0 ]
}

haproxy_sorted_external_ips_json() {
    printf '%s\n' "${HAPROXY_EXT_IPS[@]}" | sort | jq -R . | jq -s -c 'sort'
}

haproxy_current_svc_external_ips_sorted_json() {
    kubectl get svc -n "$1" "$2" -o json | jq -c '(.spec.externalIPs // []) | sort'
}

haproxy_merge_patch_external_ips_json() {
    printf '%s\n' "${HAPROXY_EXT_IPS[@]}" | jq -R . | jq -s -c '{spec: {externalIPs: .}}'
}

haproxy_persist_external_ips_with_helm() {
    if ! haproxy_resolve_external_ips; then
        return 1
    fi
    if ! command -v helm >/dev/null 2>&1; then
        return 1
    fi
    local helm_extra="" i
    for (( i = 0; i < ${#HAPROXY_EXT_IPS[@]}; i++ )); do
        helm_extra="$helm_extra --set-string controller.service.externalIPs[$i]=${HAPROXY_EXT_IPS[i]}"
    done
    log_command "helm upgrade haproxy-kubernetes-ingress haproxytech/kubernetes-ingress --namespace \"$HAPROXY_NAMESPACE\" --reuse-values $helm_extra > /dev/null 2>&1" "Persist HAProxy externalIPs in Helm values"
}

install_haproxy() {
    echo -e "${BLUE}Installing HAProxy Kubernetes Ingress...${NC}"

    local service_info
    service_info=$(get_haproxy_service_info)
    local existing_service
    existing_service=$(echo "$service_info" | cut -d: -f1)
    local existing_namespace
    existing_namespace=$(echo "$service_info" | cut -d: -f2)

    if [ -n "$existing_service" ] && [ -n "$existing_namespace" ]; then
        echo -e "${BLUE}HAProxy Ingress already present in namespace: $existing_namespace (service: $existing_service)${NC}"
        if haproxy_resolve_external_ips; then
            patch_haproxy_service
        fi
        return 0
    fi

    if ! log_command "helm repo add haproxytech https://haproxytech.github.io/helm-charts" "Add HAProxyTech Helm repo"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to add haproxytech helm repo, continuing...${NC}"
    fi
    if ! log_command "helm repo update > /dev/null 2>&1" "Update Helm repos (HAProxy)"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to update helm repos, continuing...${NC}"
    fi

    # Same flags as doc: helm install ... --namespace haproxy-controller --set controller.ingressClassResource.enabled=true ...
    # Use upgrade --install so a second run is safe if the release exists but detection above missed it.
    local helm_install_cmd
    helm_install_cmd="helm upgrade --install haproxy-kubernetes-ingress haproxytech/kubernetes-ingress --namespace haproxy-controller --create-namespace --set controller.ingressClassResource.enabled=true --set controller.service.type=NodePort --set controller.service.nodePorts.http=32080 --set controller.service.nodePorts.https=32443"
    if haproxy_resolve_external_ips; then
        local i
        for (( i = 0; i < ${#HAPROXY_EXT_IPS[@]}; i++ )); do
            helm_install_cmd="$helm_install_cmd --set-string controller.service.externalIPs[$i]=${HAPROXY_EXT_IPS[i]}"
        done
    fi
    if ! log_command "$helm_install_cmd > /dev/null 2>&1" "Install HAProxy Kubernetes Ingress"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install HAProxy Ingress, continuing...${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ HAProxy Kubernetes Ingress installed${NC}"
    echo -e "${BLUE}Waiting for HAProxy Ingress service...${NC}"
    sleep 10

    if haproxy_resolve_external_ips; then
        service_info=$(get_haproxy_service_info)
        local svc_name
        svc_name=$(echo "$service_info" | cut -d: -f1)
        local ns
        ns=$(echo "$service_info" | cut -d: -f2)
        if [ -n "$svc_name" ] && [ -n "$ns" ]; then
            local desired_json current_json
            desired_json=$(haproxy_sorted_external_ips_json)
            current_json=$(haproxy_current_svc_external_ips_sorted_json "$ns" "$svc_name")
            if [ "$desired_json" != "$current_json" ]; then
                echo -e "${YELLOW}⚠️ Setting external IP(s) on HAProxy Ingress service...${NC}"
                patch_haproxy_service
            fi
        fi
    fi

    return 0
}

get_haproxy_service_info() {
    local service_name=""
    local namespace="$HAPROXY_NAMESPACE"

    if ! kubectl get ns "$namespace" &>/dev/null; then
        echo ":"
        return
    fi

    # Prefer the Service name that matches our Helm release (haproxy-kubernetes-ingress) in haproxy-controller.
    local candidate
    for candidate in \
        "$HAPROXY_SERVICE_NAME" \
        haproxy-kubernetes-ingress-kubernetes-ingress; do
        if kubectl get svc -n "$namespace" "$candidate" &>/dev/null; then
            service_name="$candidate"
            break
        fi
    done

    if [ -z "$service_name" ]; then
        candidate=$(kubectl get svc -n "$namespace" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -E 'ingress|haproxy' | head -1)
        if [ -n "$candidate" ]; then
            service_name="$candidate"
        fi
    fi

    echo "$service_name:$namespace"
}

patch_haproxy_service() {
    if ! haproxy_resolve_external_ips; then
        echo -e "${RED}❌ Error: external IP(s) required for patching HAProxy Ingress${NC}"
        echo -e "${YELLOW}Use --ip, --haproxy-external-ips (runai-installer), or env HAPROXY_EXTERNAL_IPS (comma-separated).${NC}"
        return 1
    fi

    local desired_json
    desired_json=$(haproxy_sorted_external_ips_json)
    local patch_payload
    patch_payload=$(haproxy_merge_patch_external_ips_json)

    local service_name=""
    local namespace="$HAPROXY_NAMESPACE"
    local hpq=false
    [ "${HAPROXY_PATCH_QUIET:-false}" = true ] && hpq=true

    # Prefer fixed Service from our Helm install: haproxy-controller / haproxy-kubernetes-ingress
    if kubectl get svc -n "$namespace" "$HAPROXY_SERVICE_NAME" &>/dev/null; then
        service_name="$HAPROXY_SERVICE_NAME"
    else
        local service_info
        service_info=$(get_haproxy_service_info)
        service_name=$(echo "$service_info" | cut -d: -f1)
        namespace=$(echo "$service_info" | cut -d: -f2)
    fi

    if [ -z "$service_name" ] || [ -z "$namespace" ]; then
        echo -e "${RED}❌ Error: Could not find HAProxy Ingress service (expected ${HAPROXY_NAMESPACE}/${HAPROXY_SERVICE_NAME})${NC}"
        kubectl get svc -n "$HAPROXY_NAMESPACE" 2>/dev/null || echo "No services in ${HAPROXY_NAMESPACE}"
        return 1
    fi

    local current_json
    current_json=$(haproxy_current_svc_external_ips_sorted_json "$namespace" "$service_name")
    if [ "$current_json" = "$desired_json" ]; then
        if [ "$hpq" != true ]; then
            echo -e "${GREEN}✅ HAProxy Ingress already has externalIPs: ${HAPROXY_EXT_IPS[*]}${NC}"
        fi
        return 0
    fi

    local patch_q
    patch_q=$(printf '%q' "$patch_payload")

    # --automatic: one patch + Helm persist, no chatty verify loop (clusters may reconcile spec.externalIPs oddly).
    if [ "$hpq" = true ]; then
        if log_command "kubectl patch svc -n \"$namespace\" \"$service_name\" --type='merge' -p $patch_q" "Patch HAProxy Ingress service (external IPs)"; then
            haproxy_persist_external_ips_with_helm >/dev/null 2>&1 || true
            return 0
        fi
        echo -e "${RED}❌ Failed to patch HAProxy Ingress service${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}Patching HAProxy Ingress service with external IPs: ${HAPROXY_EXT_IPS[*]}${NC}"
    echo -e "${BLUE}Target: ${HAPROXY_NAMESPACE}/${HAPROXY_SERVICE_NAME} (same as --haproxy install)${NC}"
    echo -e "${BLUE}Patching Service: $namespace/$service_name${NC}"

    if [ "$current_json" != "[]" ] && [ -n "$current_json" ]; then
        echo -e "${YELLOW}⚠️ Warning: HAProxy Ingress currently has externalIPs (sorted): $current_json — changing to match: $desired_json${NC}"
    fi

    if ! log_command "kubectl patch svc -n \"$namespace\" \"$service_name\" --type='merge' -p $patch_q" "Patch HAProxy Ingress service (external IPs)"; then
        echo -e "${RED}❌ Failed to patch HAProxy Ingress service${NC}"
        return 1
    fi

    haproxy_persist_external_ips_with_helm >/dev/null 2>&1 || true

    current_json=$(haproxy_current_svc_external_ips_sorted_json "$namespace" "$service_name")
    if [ "$current_json" != "$desired_json" ]; then
        echo -e "${RED}❌ Patch did not set expected externalIPs (got: ${current_json:-empty})${NC}"
        return 1
    fi

    # Verify the field remains after short reconciles; if it disappears, retry via Helm + patch.
    local attempt
    for attempt in 1 2 3; do
        sleep 2
        current_json=$(haproxy_current_svc_external_ips_sorted_json "$namespace" "$service_name")
        if [ "$current_json" = "$desired_json" ]; then
            echo -e "${GREEN}✅ HAProxy Ingress patched with externalIPs: ${HAPROXY_EXT_IPS[*]}${NC}"
            return 0
        fi
        haproxy_persist_external_ips_with_helm >/dev/null 2>&1 || true
        kubectl patch svc -n "$namespace" "$service_name" --type='merge' -p "$patch_payload" >/dev/null 2>&1 || true
    done

    current_json=$(haproxy_current_svc_external_ips_sorted_json "$namespace" "$service_name")
    echo -e "${RED}❌ externalIPs are reverted after patch (current sorted: ${current_json:-empty})${NC}"
    return 1
}

