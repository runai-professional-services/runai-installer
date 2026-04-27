#!/bin/bash
# OpenShift (OCP) detection and helpers for Run:ai.
# See: https://run-ai-docs.nvidia.com/self-hosted/getting-started/installation
# Control plane: --set global.config.kubernetesDistribution=openshift
#                 --set global.domain=runai.apps.<OPENSHIFT_BASE_DOMAIN>
# External HTTPS uses route.route.openshift.io to the default cluster *router* (`*.apps`); not vanilla Ingress.
#
# Expects kubectl with access to the cluster. Uses kubectl only (no hard dependency on oc).
#
# OpenShift is the production path here: this module only *reports* recommended
# OLM / platform operators; it never installs or upgrades them.

# Returns 0 if the cluster is OpenShift / OKD (best-effort).
runai_cluster_is_openshift() {
    if ! command -v kubectl &>/dev/null; then
        return 1
    fi
    if kubectl get namespace openshift &>/dev/null; then
        return 0
    fi
    if kubectl get crd clusterversions.config.openshift.io &>/dev/null; then
        return 0
    fi
    if kubectl api-resources --api-group=config.openshift.io -o name 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

# Prints the cluster base domain (e.g. ocp.example.com) or empty.
runai_openshift_get_base_domain() {
    local bd=""
    bd="$(kubectl get dns.config cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null || true)"
    if [ -z "$bd" ]; then
        bd="$(kubectl get dns.config default -o jsonpath='{.spec.baseDomain}' 2>/dev/null || true)"
    fi
    if [ -z "$bd" ]; then
        # Fallback: default ingress reports an apps subdomain; strip the leading "apps."
        local idom=""
        idom="$(kubectl get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}' 2>/dev/null || true)"
        if [ -n "$idom" ] && [ "$idom" != "null" ]; then
            case "$idom" in
                apps.*) bd="${idom#apps.}" ;;
                *) bd="$idom" ;;
            esac
        fi
    fi
    printf '%s' "$bd"
}

# FQDN recommended by NVIDIA for control plane on OpenShift: runai.apps.<BASE_DOMAIN>
runai_openshift_default_runai_domain() {
    local bd
    bd="$(runai_openshift_get_base_domain)"
    if [ -z "$bd" ]; then
        return 1
    fi
    printf 'runai.apps.%s' "$bd"
    return 0
}

# Resolves a PEM for TLS the default OpenShift *router* uses for `*.apps` *Routes* (CA bundle and/or server chain) into OUT_FILE.
# (OCP: external access is via route.route.openshift.io; the cluster router terminates HTTPS; not vanilla Ingress.)
# Order: 1) openshift-ingress/router-ca  2) default-ingress-cert CM  3) TLS probe to the Run:ai FQDN (host on a Route).
# Returns 0 on success. Requires kube read access to openshift-ingress; openssl optional for 3.
runai_openshift_auto_fetch_ingress_cacert_to() {
    local out="$1" fqdn="${2:-}"
    local json key val tmp

    [ -n "$out" ] || return 1
    : >"$out" 2>/dev/null || return 1

    # 1) router CA bundle (OCP 4+)
    if kubectl get -n openshift-ingress configmap router-ca -o name &>/dev/null; then
        json=$(kubectl get -n openshift-ingress configmap router-ca -o json 2>/dev/null) || true
        if [ -n "$json" ] && command -v jq &>/dev/null; then
            for key in ca-bundle.crt certificate.pem ca.crt; do
                val=$(echo "$json" | jq -r --arg k "$key" '.data[$k] // empty' 2>/dev/null) || true
                if [ -n "$val" ] && [ "${#val}" -ge 20 ]; then
                    printf '%s' "$val" | tr -d '\r' >"$out"
                    if head -1 "$out" 2>/dev/null | grep -qE 'BEGIN (CERTIFICATE|X509|TRUSTED)'; then
                        return 0
                    fi
                fi
            done
            # Any key that looks like PEM
            for key in $(echo "$json" | jq -r '.data|keys[]' 2>/dev/null); do
                val=$(echo "$json" | jq -r --arg k "$key" '.data[$k] // empty' 2>/dev/null) || true
                if [ -n "$val" ] && [ "${#val}" -ge 20 ]; then
                    printf '%s' "$val" | tr -d '\r' >"$out"
                    if head -1 "$out" 2>/dev/null | grep -qE 'BEGIN (CERTIFICATE|X509|TRUSTED)'; then
                        return 0
                    fi
                fi
            done
        else
            for key in "ca-bundle.crt" "certificate.pem" "ca.crt" "tls.crt"; do
                if val=$(kubectl get -n openshift-ingress configmap router-ca -o jsonpath="{.data['$key']}" 2>/dev/null) && [ -n "$val" ]; then
                    printf '%s' "$val" | tr -d '\r' >"$out"
                    if head -1 "$out" 2>/dev/null | grep -qE 'BEGIN (CERTIFICATE|X509|TRUSTED)'; then
                        return 0
                    fi
                fi
            done
        fi
    fi

    # 1b) some builds: extra CM next to router-ca
    if kubectl get -n openshift-ingress configmap default-ingress-cert -o name &>/dev/null; then
        json=$(kubectl get -n openshift-ingress configmap default-ingress-cert -o json 2>/dev/null) || true
        if [ -n "$json" ] && command -v jq &>/dev/null; then
            for key in $(echo "$json" | jq -r '.data|keys[]' 2>/dev/null); do
                val=$(echo "$json" | jq -r --arg k "$key" '.data[$k] // empty' 2>/dev/null) || true
                if [ -n "$val" ] && [ "${#val}" -ge 20 ]; then
                    printf '%s' "$val" | tr -d '\r' >"$out"
                    if head -1 "$out" 2>/dev/null | grep -qE 'BEGIN (CERTIFICATE|X509|TRUSTED)'; then
                        return 0
                    fi
                fi
            done
        fi
    fi

    # 2) HTTPS probe: PEM chain as presented for the FQDN (served by the default OpenShift router for that Route)
    fqdn="${fqdn#https://}"; fqdn="${fqdn%%/*}"
    if [ -z "$fqdn" ] || [ "$fqdn" = "null" ] || [ "$fqdn" = "runai.apps.<baseDomain>" ]; then
        return 1
    fi
    if ! command -v openssl &>/dev/null; then
        return 1
    fi
    local tcmd=()
    if command -v timeout &>/dev/null; then
        tcmd=( timeout 15 )
    fi
    tmp=$(mktemp) || return 1
    if ! echo | "${tcmd[@]}" openssl s_client -showcerts -connect "${fqdn}:443" -servername "$fqdn" 2>/dev/null >"$tmp"; then
        echo | "${tcmd[@]}" openssl s_client -connect "${fqdn}:443" -servername "$fqdn" 2>/dev/null >"$tmp" || true
    fi
    if [ -s "$tmp" ] && sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$tmp" 2>/dev/null | tr -d '\r' >"$out" && [ -s "$out" ]; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Hints: PEM that trusts TLS for the OpenShift Route to Run:ai (e.g. runai.apps.example.com) — the flag name says
# "ingress" (router CAs live under openshift-ingress) but the user-facing object is a Route, not a K8s Ingress.
# The cluster Helm pre-install GETs https://<global.domain>/_version; the error
# "certificate signed by unknown authority" is fixed the same way as: curl --cacert router-ca.pem "https://…/_version"
runai_openshift_print_ingress_cacert_hint() {
    local h="${1:-runai.apps.<baseDomain>}"
    h="${h#https://}"; h="${h%%/*}"
    cat <<EOF
By default, runai-installer (with --openshift --no-cert) fetches the CA the default OpenShift router uses for `*.apps` *Routes* (configmap router-ca in openshift-ingress) or the live TLS chain to your global.domain (Route hostname).

To fix failures manually, pass a PEM that verifies HTTPS to your Route, then re-run with:
  --openshift --no-cert --openshift-ingress-cacert /path/to/router-or-chain.pem
Or set RUNAI_OCP_NO_AUTO_INGRESS_CA=1 to skip the secret and global.customCA (not recommended; pre-install may fail on unknown CA).

Obtain a PEM (pick one; OCP build-dependent):
  • Try router CA:  oc -n openshift-ingress get configmap router-ca -o jsonpath='{.data.certificate\\.pem}' > /tmp/ingress-router-ca.pem
  • Or list configmaps:  oc -n openshift-ingress get configmap
  • From a machine that resolves the Route, inspect chain:  openssl s_client -showcerts -connect ${h}:443 -servername ${h} < /dev/null 2>&1
    (for multi-CA, concatenate needed intermediate + root into one PEM; same idea as "curl --cacert")

Validate like the Helm pre-install (HTTPS GET to _version):
  curl -fsS --cacert /path/to/ingress-router-or-chain.pem "https://${h}/_version" || true
(Replace with your global.domain, e.g. $h)
EOF
}

# PSA labels (namespace runai) — see Run:ai system requirements (OpenShift + restricted).
runai_openshift_label_runai_namespace_psa() {
    local ns="runai"
    if ! kubectl get namespace "$ns" &>/dev/null; then
        return 0
    fi
    kubectl label namespace "$ns" --overwrite \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/warn=privileged 2>/dev/null || true
}

# Apply distribution for Helm; exports nothing — prints extra --set flags for consumers that build commands.
runai_helm_set_openshift_distribution() {
    printf '%s' "--set global.config.kubernetesDistribution=openshift"
}

# Build a one-shot lowercase string of OLM + subscriptions for heuristics (no extra kubectl round-trips in callers).
runai_openshift__olm_snapshot() {
    ( kubectl get csv -A 2>/dev/null; echo; kubectl get sub -A 2>/dev/null ) 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '\r'
}

# best-effort: one of  present  |  absent  |  unknown
# Uses OLM (CSV/Subscription) first, then namespaces/CRD hints. Never changes the cluster.
runai_openshift_nfd_status() {
    local snap
    snap="$(runai_openshift__olm_snapshot)"
    if echo "$snap" | grep -qE 'node-?feature-?discov|nfd-?operat|nfd-?rhel|nfd[.0-9_-]'; then
        echo present
        return 0
    fi
    if kubectl get namespace openshift-nfd -o name 2>/dev/null | grep -q 'namespace/openshift-nfd'; then
        echo present
        return 0
    fi
    if kubectl get crd 2>/dev/null | grep -qiE 'nfd\.openshift|nodefeature' 2>/dev/null; then
        echo present
        return 0
    fi
    echo absent
    return 0
}

# NVIDIA GPU Operator (or equivalent CSV) on OpenShift
runai_openshift_gpu_operator_status() {
    local snap
    snap="$(runai_openshift__olm_snapshot)"
    if echo "$snap" | grep -qE 'gpu-?operat|nvidia-?gpu'; then
        echo present
        return 0
    fi
    for ns in nvidia-gpu-operator gpu-operator; do
        if kubectl get namespace "$ns" -o name 2>/dev/null | grep -qE "namespace/$ns"; then
            echo present
            return 0
        fi
    done
    if kubectl get crd 2>/dev/null | grep -qE 'nvidia\.com' 2>/dev/null; then
        echo present
        return 0
    fi
    if kubectl get pods -n gpu-operator --no-headers 2>/dev/null | grep -q .; then
        echo present
        return 0
    fi
    if kubectl get pods -n nvidia-gpu-operator --no-headers 2>/dev/null | grep -q .; then
        echo present
        return 0
    fi
    echo absent
    return 0
}

# OpenShift Serverless = Knative on OCP (OperatorHub). Best-effort: OLM, namespaces, API objects, CRD hints.
runai_openshift_knative_serverless_status() {
    local snap
    snap="$(runai_openshift__olm_snapshot)"
    if echo "$snap" | grep -qE 'serverless' || ( echo "$snap" | grep -q 'knative' && echo "$snap" | grep -qE 'kourier|serving|operator' ); then
        echo present
        return 0
    fi
    for ns in knative-serving knative-eventing openshift-serverless openshift-knative; do
        if kubectl get namespace "$ns" -o name 2>/dev/null | grep -qE "namespace/$ns"; then
            echo present
            return 0
        fi
    done
    if kubectl get knativeserving -A 2>/dev/null | tail -n +2 2>/dev/null | grep -q .; then
        echo present
        return 0
    fi
    if kubectl get crd 2>/dev/null | grep -qEi 'serving\.knative|operator\.knative' 2>/dev/null; then
        echo present
        return 0
    fi
    echo absent
    return 0
}

# Human label for a status token.
runai_openshift_status_pretty() {
    case "$1" in
        present)  printf 'present' ;;
        absent)   printf 'not detected' ;;
        *)        printf 'unknown' ;;
    esac
}

# Color a status for terminal output (parent usually sets GREEN/YELLOW/NC from runai-installer.sh).
runai_openshift__cstatus() {
    local st="$1" txt
    txt="$(runai_openshift_status_pretty "$st")"
    case "$st" in
        present) printf '%s%s%s' "${GREEN:-}" "$txt" "${NC:-}" ;;
        *)       printf '%s%s%s' "${YELLOW:-}" "$txt" "${NC:-}" ;;
    esac
}

# Pretty list for the installer. Report-only: never installs or upgrades operators.
# Knative = OpenShift Serverless on OCP (operator packaging varies by version).
runai_openshift_print_recommended_prereq_operators() {
    : "${GREEN:=$'\e[0;32m'}${YELLOW:=$'\e[0;33m'}${BLUE:=$'\e[0;34m'}${NC:=$'\e[0m'}"
    local nfd gpu kn
    nfd="$(runai_openshift_nfd_status)"
    gpu="$(runai_openshift_gpu_operator_status)"
    kn="$(runai_openshift_knative_serverless_status)"

    echo -e "  ${YELLOW}OpenShift (production) — recommended operators: status only; we do not install or change them here.${NC}"
    echo -e "  ${BLUE}NFD (Node Feature Discovery)${NC}      →  $(runai_openshift__cstatus "$nfd")  ${YELLOW}(prerequisite for GPU Operator)${NC}"
    echo -e "  ${BLUE}NVIDIA GPU Operator${NC}                 →  $(runai_openshift__cstatus "$gpu")  ${YELLOW}(Run:ai GPU)${NC}"
    echo -e "  ${BLUE}Knative (OpenShift Serverless)${NC}     →  $(runai_openshift__cstatus "$kn")  ${YELLOW}(Knative on OCP)${NC}"
    echo -e "  If something is not detected, install via ${BLUE}OperatorHub${NC} / your platform runbook; this installer will not do it for you."
}
