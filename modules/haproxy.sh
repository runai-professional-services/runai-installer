#!/bin/bash
# HAProxy Kubernetes Ingress (HAProxyTech), per NVIDIA Run:ai “Migrate from NGINX to HAProxy Ingress”
# (Vanilla Kubernetes): https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation/install-using-helm/upgrade
# Ingress class for Run:ai charts: haproxy (see --use-haproxy in runai-installer.sh).

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
        if [ -n "$IP_ADDRESS" ]; then
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
    if ! log_command "helm upgrade --install haproxy-kubernetes-ingress haproxytech/kubernetes-ingress --namespace haproxy-controller --create-namespace --set controller.ingressClassResource.enabled=true --set controller.service.type=NodePort --set controller.service.nodePorts.http=32080 --set controller.service.nodePorts.https=32443 > /dev/null 2>&1" "Install HAProxy Kubernetes Ingress"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to install HAProxy Ingress, continuing...${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ HAProxy Kubernetes Ingress installed${NC}"
    echo -e "${BLUE}Waiting for HAProxy Ingress service...${NC}"
    sleep 10

    if [ -n "$IP_ADDRESS" ]; then
        service_info=$(get_haproxy_service_info)
        local svc_name
        svc_name=$(echo "$service_info" | cut -d: -f1)
        local ns
        ns=$(echo "$service_info" | cut -d: -f2)
        if [ -n "$svc_name" ] && [ -n "$ns" ]; then
            local current_ip
            current_ip=$(kubectl get svc -n "$ns" "$svc_name" -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
            if [ -z "$current_ip" ] || [ "$current_ip" != "$IP_ADDRESS" ]; then
                echo -e "${YELLOW}⚠️ Setting external IP on HAProxy Ingress service...${NC}"
                patch_haproxy_service
            fi
        fi
    fi

    return 0
}

get_haproxy_service_info() {
    local service_name=""
    local namespace="haproxy-controller"

    if ! kubectl get ns "$namespace" &>/dev/null; then
        echo ":"
        return
    fi

    local candidate
    for candidate in \
        haproxy-kubernetes-ingress-kubernetes-ingress \
        haproxy-kubernetes-ingress; do
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
    if [ -z "$IP_ADDRESS" ]; then
        echo -e "${RED}❌ Error: IP address is required for patching HAProxy Ingress${NC}"
        echo -e "${YELLOW}Use --ip with --patch-haproxy (or pass --ip when installing with --haproxy)${NC}"
        return 1
    fi

    echo -e "${BLUE}Patching HAProxy Ingress service with external IP: $IP_ADDRESS${NC}"

    local service_info
    service_info=$(get_haproxy_service_info)
    local service_name
    service_name=$(echo "$service_info" | cut -d: -f1)
    local namespace
    namespace=$(echo "$service_info" | cut -d: -f2)

    if [ -z "$service_name" ] || [ -z "$namespace" ]; then
        echo -e "${RED}❌ Error: Could not find HAProxy Ingress service in namespace haproxy-controller${NC}"
        kubectl get svc -n haproxy-controller 2>/dev/null || echo "No services in haproxy-controller"
        return 1
    fi

    echo -e "${BLUE}Found HAProxy service: $service_name in namespace: $namespace${NC}"

    local current_ip
    current_ip=$(kubectl get svc -n "$namespace" "$service_name" -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
    if [ "$current_ip" = "$IP_ADDRESS" ]; then
        echo -e "${GREEN}✅ HAProxy Ingress already has externalIP: $IP_ADDRESS${NC}"
        return 0
    fi

    if [ -n "$current_ip" ]; then
        echo -e "${YELLOW}⚠️ Warning: HAProxy Ingress currently has externalIP: $current_ip — changing to: $IP_ADDRESS${NC}"
    fi

    if ! log_command "kubectl patch svc -n \"$namespace\" \"$service_name\" --type='merge' -p '{\"spec\":{\"externalIPs\":[\"$IP_ADDRESS\"]}}'" "Patch HAProxy Ingress service (external IP)"; then
        echo -e "${RED}❌ Failed to patch HAProxy Ingress service${NC}"
        return 1
    fi

    local new_ip
    new_ip=$(kubectl get svc -n "$namespace" "$service_name" -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null)
    if [ "$new_ip" = "$IP_ADDRESS" ]; then
        echo -e "${GREEN}✅ HAProxy Ingress patched with externalIP: $IP_ADDRESS${NC}"
        return 0
    fi

    echo -e "${RED}❌ Patch did not set expected external IP (got: ${new_ip:-empty})${NC}"
    return 1
}

