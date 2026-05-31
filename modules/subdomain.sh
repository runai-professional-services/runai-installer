#!/bin/bash

# Subdomain Support Module for Run.ai Installer
# This module handles wildcard ingress creation for subdomain support.
# Run:ai 2.25 auto-apply (runai-cluster-domain-star-ingress) is for vanilla Kubernetes only.
# Kirson second Ingress + curl TLS probes run only with ingressClassName haproxy.
# Other classes (e.g. nginx) get the simple single wildcard Ingress only. OpenShift excluded (Routes).

# Ingress class for runai-cluster-domain-star-ingress: align with --use-haproxy / --use-nginx,
# installed ingress add-ons, or default to haproxy (matches --automatic vanilla defaults).
runai_cluster_domain_star_ingress_class() {
    if [ "${RUNAI_K8S_DISTRIBUTION:-}" = "openshift" ]; then
        return 1
    fi
    if [ -n "${RUNAI_INGRESS_CLASS:-}" ]; then
        printf '%s' "$RUNAI_INGRESS_CLASS"
        return 0
    fi
    if [ "${INSTALL_HAPROXY:-false}" = true ]; then
        printf '%s' "haproxy"
        return 0
    fi
    if [ "${INSTALL_NGINX:-false}" = true ]; then
        printf '%s' "nginx"
        return 0
    fi
    printf '%s' "haproxy"
    return 0
}

# True when installing Run:ai control plane / cluster chart version 2.25.x (from --runai-version / resolved semver).
runai_install_version_is_2_25() {
    local mm
    mm="$(printf '%s' "${RUNAI_VERSION:-}" | grep -oE '^[0-9]+\.[0-9]+' | head -1)"
    [ "$mm" = "2.25" ]
}

# Concrete hostname under the wildcard cert (SAN includes *.<DNS_NAME>); second Ingress uses same TLS secret.
RUNAI_225_STAR_TLS_PROBE_HOST_LABEL="${RUNAI_225_STAR_TLS_PROBE_HOST_LABEL:-kirson}"

# Echo to terminal and mirror into installation LOG_FILE when set (plain echo lines often never hit LOG_FILE).
runai_subdomain_msg() {
    echo -e "$1"
    if [ -n "${LOG_FILE:-}" ]; then
        echo -e "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# After successful cluster Helm for Run:ai 2.25 on non-OpenShift clusters: ensure wildcard Ingress
# for *.<DNS_NAME> (same host source as --dns / --automatic AUTO_DNS). Never on OpenShift (--openshift).
# Skipped when --subdomain will apply the same manifest.
maybe_apply_runai_225_cluster_domain_star_ingress() {
    if [ "${SUBDOMAIN_SUPPORT:-false}" = true ]; then
        return 0
    fi
    if [ "${RUNAI_K8S_DISTRIBUTION:-}" = "openshift" ]; then
        if runai_install_version_is_2_25; then
            echo -e "${BLUE}Run:ai 2.25: skipping cluster-domain star Ingress (OpenShift uses Routes, not Ingress).${NC}"
        fi
        return 0
    fi
    if ! runai_install_version_is_2_25; then
        return 0
    fi
    if [ -z "${DNS_NAME:-}" ]; then
        echo -e "${YELLOW}⚠️ Run:ai 2.25: skipping cluster-domain star Ingress (DNS_NAME not set)${NC}"
        return 0
    fi
    local icl
    if ! icl="$(runai_cluster_domain_star_ingress_class)"; then
        return 0
    fi
    if [ "$icl" != "haproxy" ]; then
        echo -e "${BLUE}Run:ai 2.25: applying simple wildcard Ingress only (${GREEN}*.${DNS_NAME}${BLUE}, class ${icl}; kirson + TLS probes are ${YELLOW}HAProxy-only${BLUE}).${NC}"
        create_simple_cluster_domain_star_ingress "$icl" "Run:ai 2.25 cluster-domain star Ingress (simple)"
        return $?
    fi
    echo -e "${BLUE}Run:ai 2.25: applying cluster-domain star Ingress pair + TLS probes (${GREEN}*.${DNS_NAME}${BLUE} + ${GREEN}${RUNAI_225_STAR_TLS_PROBE_HOST_LABEL}.${DNS_NAME}${BLUE}, ingressClassName: haproxy)...${NC}"
    runai_225_apply_cluster_domain_star_ingress_pair_and_probe "$icl" "Run:ai 2.25 cluster-domain star Ingress"
}

# First path backend from an existing Ingress in namespace runai (chart objects).
# Note: Ingress uses spec.rules[].http for L7 routes; clients still use HTTPS when spec.tls is set.
# Prints: SERVICE PORT
runai_cluster_discover_ingress_backend() {
    local raw line sn pnum pname pn
    if ! command -v jq &>/dev/null; then
        return 1
    fi
    raw=$(kubectl get ingress -n runai -o json 2>/dev/null) || return 1
    line=$(printf '%s' "$raw" | jq -r '.items[]?
      | .spec.rules[]?
      | select(.http != null)
      | .http.paths[]?
      | select(.backend.service != null)
      | "\(.backend.service.name)|\(.backend.service.port.number // "")|\(.backend.service.port.name // "")"' 2>/dev/null | head -1)
    [ -n "$line" ] || return 1
    IFS='|' read -r sn pnum pname <<< "$line"
    if [ -z "$sn" ] || [ "$sn" = "null" ]; then
        return 1
    fi
    if [ -n "$pnum" ] && [ "$pnum" != "null" ]; then
        printf '%s %s\n' "$sn" "$pnum"
        return 0
    fi
    if [ -n "$pname" ] && [ "$pname" != "null" ]; then
        pn=$(kubectl get svc "$sn" -n runai -o jsonpath="{.spec.ports[?(@.name==\"$pname\")].port}" 2>/dev/null)
        if [ -n "$pn" ]; then
            printf '%s %s\n' "$sn" "$pn"
            return 0
        fi
    fi
    return 1
}

runai_cluster_star_ingress_annotations_block() {
    local ingress_class="$1"
    case "$ingress_class" in
        nginx)
            printf '%s\n' '    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"'
            ;;
        haproxy)
            printf '%s\n' '    haproxy.org/ssl-redirect: "true"'
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

# When the upstream Service speaks TLS (common on 443/8443), tell the ingress controller.
# Override for other ports: RUNAI_225_INGRESS_BACKEND_HTTPS=true
runai_cluster_star_ingress_backend_https_annotations_block() {
    local ingress_class="$1"
    local port="${2:-}"
    local force=false
    case "${RUNAI_225_INGRESS_BACKEND_HTTPS:-}" in
        1|true|TRUE|yes|YES) force=true ;;
    esac
    if [ "$force" != true ]; then
        [ "$port" = "443" ] || [ "$port" = "8443" ] || return 0
    fi
    case "$ingress_class" in
        nginx)
            printf '%s\n' '    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"'
            ;;
        haproxy)
            printf '%s\n' '    haproxy.org/server-ssl: "true"'
            ;;
        *)
            return 0
            ;;
    esac
}

# Resolve CA file for TLS verify (same material as installer certs when available).
runai_225_tls_probe_ca_file() {
    if [ -n "${FULL:-}" ] && [ -f "$FULL" ]; then
        printf '%s' "$FULL"
        return 0
    fi
    if [ -f "./certificates/full-chain.pem" ]; then
        printf '%s' "./certificates/full-chain.pem"
        return 0
    fi
    if [ -n "${CERT_DIR:-}" ] && [ -f "${CERT_DIR}/full-chain.pem" ]; then
        printf '%s' "${CERT_DIR}/full-chain.pem"
        return 0
    fi
    return 1
}

runai_225_http_code_tls_ok() {
    local code="$1"
    [[ "$code" =~ ^[0-9]{3}$ ]] && [ "$code" != "000" ]
}

# HTTPS GET probe; verifies TLS when CA file is available.
runai_225_curl_tls_probe_host() {
    local host="$1"
    local ca=""
    if ca="$(runai_225_tls_probe_ca_file 2>/dev/null)" && [ -n "$ca" ]; then
        local code
        code=$(curl -sS -o /dev/null --connect-timeout 15 --max-time 45 --cacert "$ca" -w '%{http_code}' -L "https://${host}/" 2>/dev/null || printf '000')
        if runai_225_http_code_tls_ok "$code"; then
            return 0
        fi
    fi
    local code2
    code2=$(curl -sS -k -o /dev/null --connect-timeout 15 --max-time 45 -w '%{http_code}' -L "https://${host}/" 2>/dev/null || printf '000')
    runai_225_http_code_tls_ok "$code2"
}

runai_225_tls_probe_hosts_report() {
    local apex="$1"
    local sub="$2"
    runai_subdomain_msg "${BLUE}Run:ai 2.25: TLS probe https://${apex}/ ...${NC}"
    if runai_225_curl_tls_probe_host "$apex"; then
        runai_subdomain_msg "${GREEN}✅ TLS/HTTPS OK for ${apex}${NC}"
    else
        runai_subdomain_msg "${YELLOW}⚠️ TLS/HTTPS probe failed for ${apex} (ingress sync, DNS, or path / — check LOG_FILE)${NC}"
    fi
    runai_subdomain_msg "${BLUE}Run:ai 2.25: TLS probe https://${sub}/ (kirson Ingress / wildcard cert)...${NC}"
    if runai_225_curl_tls_probe_host "$sub"; then
        runai_subdomain_msg "${GREEN}✅ TLS/HTTPS OK for ${sub}${NC}"
    else
        runai_subdomain_msg "${YELLOW}⚠️ TLS/HTTPS probe failed for ${sub}${NC}"
    fi
}

# Wildcard + concrete host Ingresses sharing runai-cluster-domain-star-tls-secret; optional curl probes.
runai_225_apply_cluster_domain_star_ingress_pair_and_probe() {
    local ingress_class="$1"
    local log_suffix="${2:-Run:ai 2.25 cluster-domain star Ingress}"

    if [ -z "$DNS_NAME" ] || [ -z "$ingress_class" ]; then
        echo -e "${RED}❌ runai_225_apply_cluster_domain_star_ingress_pair_and_probe: DNS_NAME and ingress class required${NC}"
        return 1
    fi

    local be_svc="" be_port="" ann="" be_https_ann="" kir="${RUNAI_225_STAR_TLS_PROBE_HOST_LABEL}.${DNS_NAME}"
    local meta_ann="" kstat=0

    local be_tmp
    be_tmp=$(mktemp "${TMPDIR:-/tmp}/runai-be.XXXXXX") || return 1
    if runai_cluster_discover_ingress_backend >"$be_tmp" 2>/dev/null; then
        read -r be_svc be_port <"$be_tmp"
    fi
    rm -f "$be_tmp"

    ann=$(runai_cluster_star_ingress_annotations_block "$ingress_class")
    if [ -n "$be_svc" ] && [ -n "$be_port" ]; then
        be_https_ann=$(runai_cluster_star_ingress_backend_https_annotations_block "$ingress_class" "$be_port")
        if [ -n "$be_https_ann" ]; then
            if [ -n "$ann" ]; then
                ann=$(printf '%s\n%s' "$ann" "$be_https_ann")
            else
                ann="$be_https_ann"
            fi
        fi
    fi
    [ -n "$ann" ] && meta_ann=$(printf '\n  annotations:\n%s' "$ann")

    if [ -n "$be_svc" ] && [ -n "$be_port" ]; then
        echo -e "${BLUE}Using backend for star Ingresses: ${GREEN}${be_svc}:${be_port}${NC} (from existing runai Ingress; clients use HTTPS via spec.tls)"
        # Two Ingress objects may reference the same tls secret (supported).
        kubectl apply -f - << EOF || kstat=$?
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: runai-cluster-domain-star-ingress
  namespace: runai${meta_ann}
spec:
  ingressClassName: $ingress_class
  tls:
  - hosts:
    - '*.$DNS_NAME'
    secretName: runai-cluster-domain-star-tls-secret
  rules:
  - host: '*.$DNS_NAME'
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $be_svc
            port:
              number: ${be_port}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: runai-cluster-domain-kirson-ingress
  namespace: runai${meta_ann}
spec:
  ingressClassName: $ingress_class
  tls:
  - hosts:
    - '$kir'
    secretName: runai-cluster-domain-star-tls-secret
  rules:
  - host: '$kir'
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $be_svc
            port:
              number: ${be_port}
EOF
    else
        runai_subdomain_msg "${YELLOW}⚠️ No path/backend found on existing runai Ingress (spec.rules[].http) — applying TLS-only wildcard (no paths); skipping kirson Ingress + TLS HTTPS probes.${NC}"
        kubectl apply -f - << EOF || kstat=$?
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: runai-cluster-domain-star-ingress
  namespace: runai
spec:
  ingressClassName: $ingress_class
  rules:
  - host: '*.$DNS_NAME'
  tls:
  - hosts:
    - '*.$DNS_NAME'
    secretName: runai-cluster-domain-star-tls-secret
EOF
    fi

    if [ "$kstat" -ne 0 ]; then
        echo -e "${RED}❌ Failed to apply cluster-domain star Ingress(es)${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Cluster-domain star Ingress(es) applied${NC}"
    if command -v log_command &> /dev/null; then
        log_command "echo 'Cluster-domain star Ingress apply succeeded'" "Create $log_suffix"
    fi

    if [ -n "$be_svc" ] && [ -n "$be_port" ]; then
        runai_subdomain_msg "${BLUE}Waiting for ingress controller to reconcile before TLS probes...${NC}"
        sleep 8
        runai_225_tls_probe_hosts_report "$DNS_NAME" "$kir"
    fi
    return 0
}

# Single wildcard Ingress (no kirson companion, no installer TLS probes).
create_simple_cluster_domain_star_ingress() {
    local ingress_class="$1"
    local log_suffix="${2:-wildcard cluster-domain star Ingress}"

    cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: runai-cluster-domain-star-ingress
  namespace: runai
spec:
  ingressClassName: $ingress_class
  rules:
  - host: '*.$DNS_NAME'
  tls:
  - hosts:
    - '*.$DNS_NAME'
    secretName: runai-cluster-domain-star-tls-secret
EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Wildcard ingress created successfully${NC}"
        if command -v log_command &> /dev/null; then
            log_command "echo 'Wildcard ingress applied successfully'" "Create $log_suffix"
        fi
        return 0
    fi
    echo -e "${RED}❌ Failed to create wildcard ingress${NC}"
    return 1
}

# $1 = ingress class name, $2 = optional log description suffix
create_subdomain_ingress_with_class() {
    local ingress_class="$1"
    local log_suffix="${2:-wildcard ingress for subdomain support}"

    if [ -z "$DNS_NAME" ]; then
        echo -e "${RED}❌ Error: DNS_NAME is required for wildcard cluster-domain Ingress${NC}"
        return 1
    fi
    if [ -z "$ingress_class" ]; then
        echo -e "${RED}❌ Error: ingress class is empty${NC}"
        return 1
    fi

    if runai_install_version_is_2_25 && [ "${RUNAI_K8S_DISTRIBUTION:-}" != "openshift" ] && [ "$ingress_class" = "haproxy" ]; then
        runai_225_apply_cluster_domain_star_ingress_pair_and_probe "$ingress_class" "$log_suffix"
        return $?
    fi

    if runai_install_version_is_2_25 && [ "${RUNAI_K8S_DISTRIBUTION:-}" != "openshift" ] && [ "$ingress_class" != "haproxy" ]; then
        echo -e "${BLUE}Run:ai 2.25: simple wildcard only for class ${ingress_class} (kirson + TLS probes: HAProxy-only).${NC}"
    fi

    create_simple_cluster_domain_star_ingress "$ingress_class" "$log_suffix"
}

# Function to create wildcard ingress for subdomain support
create_subdomain_ingress() {
    echo -e "${BLUE}Creating wildcard ingress for subdomain support...${NC}"

    if [ -z "$DNS_NAME" ]; then
        echo -e "${RED}❌ Error: DNS_NAME is required for subdomain support${NC}"
        return 1
    fi

    local icl
    if ! icl="$(runai_cluster_domain_star_ingress_class)"; then
        echo -e "${YELLOW}⚠️ Skipping wildcard Ingress on OpenShift (platform Routes).${NC}"
        return 0
    fi

    create_subdomain_ingress_with_class "$icl" "wildcard ingress for subdomain support"
}

# Function to enable subdomain support in RunaiConfig
enable_subdomain_support() {
    echo -e "${BLUE}Enabling subdomain support in RunaiConfig...${NC}"
    
    # Check if RunaiConfig already has subdomain support enabled
    echo -e "${BLUE}Checking current subdomain support status...${NC}"
    local current_subdomain=$(kubectl get runaiconfig runai -n runai -o jsonpath='{.spec.global.subdomainSupport}' 2>/dev/null)
    
    if [ "$current_subdomain" = "true" ]; then
        echo -e "${GREEN}✅ Subdomain support is already enabled in RunaiConfig${NC}"
        return 0
    fi
    
    # Wait for all Run.ai pods to be ready (simplified check)
    echo -e "${BLUE}Waiting for Run.ai pods to be ready...${NC}"
    local max_attempts=12  # 1 minute max wait
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        TOTAL_PODS=$(kubectl get pods -n runai --no-headers | wc -l)
        RUNNING_PODS=$(kubectl get pods -n runai --no-headers | grep "Running" | wc -l)
        NOT_READY=$((TOTAL_PODS - RUNNING_PODS))

        echo -e "${YELLOW}⏳ Waiting for Run.ai pods... ($RUNNING_PODS/$TOTAL_PODS ready, attempt $((attempt + 1))/$max_attempts)${NC}"

        if [ "$NOT_READY" -eq 0 ] && [ "$TOTAL_PODS" -gt 0 ]; then
            echo -e "${GREEN}✅ All Run.ai pods are ready, applying subdomain support patch${NC}"
            break
        fi
        
        sleep 5
        ((attempt++))
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo -e "${YELLOW}⚠️ Timeout waiting for all pods to be ready, proceeding with patch anyway${NC}"
    fi
    
    # Apply the patch
    if kubectl patch RunaiConfig runai -n runai --type="merge" \
        -p '{"spec":{"global":{"subdomainSupport": true}}}'; then
        echo -e "${GREEN}✅ Subdomain support enabled successfully${NC}"
        
        # Log the command
        if command -v log_command &> /dev/null; then
            log_command "kubectl patch RunaiConfig runai -n runai --type=\"merge\" -p '{\"spec\":{\"global\":{\"subdomainSupport\": true}}}'" "Enable subdomain support"
        fi
    else
        echo -e "${RED}❌ Failed to enable subdomain support${NC}"
        return 1
    fi
}

# Function to handle subdomain support setup
handle_subdomain_support() {
    echo -e "${BLUE}Setting up subdomain support...${NC}"
    
    # Create wildcard ingress
    if create_subdomain_ingress; then
        echo -e "${GREEN}✅ Wildcard ingress created${NC}"
    else
        echo -e "${RED}❌ Failed to create wildcard ingress${NC}"
        return 1
    fi
    
    # Enable subdomain support (patch will be applied after all pods are ready)
    if enable_subdomain_support; then
        echo -e "${GREEN}✅ Subdomain support enabled${NC}"
    else
        echo -e "${RED}❌ Failed to enable subdomain support${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Subdomain support setup completed successfully${NC}"
    return 0
}
