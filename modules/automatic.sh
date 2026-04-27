#!/bin/bash
# Opinionated automatic cluster preparation (--automatic in runai-installer.sh).
#
# Phases (see --automatic-stop-after): helm → nodes → prereqs → tests → haproxy → certs → tls/ingress (sanity-check) → storage → (full Run:ai @ latest if creds)
#   On OpenShift: no Helm prereq stack; no local-path; no HAProxy/Nginx; no route/ingress/TLS preflight; no auto certs; DNS = runai.apps.<base>.
#   helm       — Helm CLI (get_helm.sh)
#   nodes      — worker IP + <IP>.sslip.io (or OpenShift: runai.apps.<baseDomain>)
#   prereqs    — optional Prometheus / GPU Operator / Knative / LWS / Training (Helm --install-only)
#   tests      — preflight: (non-OCP) NGC (if NGC) + hardware / disk / storage; (OpenShift) NGC (if NGC) + StorageClass / PVC; no hardware/disk
#   haproxy    — HAProxy Ingress install/patch + externalIP verify
#   certs      — TLS files + secrets (modules/certificates.sh)
#   tls        — sanity-check.sh --dns … --use-haproxy (ingress + HTTPS)
#   storage    — default StorageClass + storage test if not already run in preflight
#
# Expects GREEN/YELLOW/BLUE/RED/NC from runai-installer.sh.
# Env: AUTOMATIC_STOP_AFTER=phase — exit successfully after that phase (debugging).
# Env: NGC_API_KEY + RUNAI_ARTIFACT_SOURCE=ngc from --ngc-key (for chained --ngc install).

REPO_ROOT="${REPO_ROOT:-$(pwd)}"

# HAProxy Service name/namespace must match modules/haproxy.sh (patch_haproxy_service / get_haproxy_service_info).
automatic_ensure_haproxy_sh_loaded() {
    if [ "${_RUNAI_HAPROXY_SH_LOADED:-false}" = true ]; then
        return 0
    fi
    if [ ! -f "$REPO_ROOT/modules/haproxy.sh" ]; then
        echo -e "${RED}❌ Missing $REPO_ROOT/modules/haproxy.sh${NC}" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$REPO_ROOT/modules/haproxy.sh"
    _RUNAI_HAPROXY_SH_LOADED=true
}

automatic_confirm() {
    if [ "${AUTO_YES:-false}" = true ]; then
        return 0
    fi
    local r
    read -r -p "Continue? [y/N]: " r
    case "$r" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Prompt with custom text (still respects AUTO_YES).
automatic_confirm_msg() {
    local prompt_msg="${1:-Proceed with automatic preparation? [y/N]: }"
    if [ "${AUTO_YES:-false}" = true ]; then
        echo -e "${GREEN}--yes:${NC} continuing without prompt."
        return 0
    fi
    local r
    echo -ne "${YELLOW}${prompt_msg}${NC} "
    read -r r
    case "$r" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

automatic_is_ngc_mode() {
    [ "${RUNAI_ARTIFACT_SOURCE:-jfrog}" = "ngc" ] && [ -n "${NGC_API_KEY:-}" ]
}

# Helm index HTTP 200 = good key + chart access (see sanity-check/modules/ngc-check.sh).
automatic_verify_ngc_api_key() {
    local ngc_mod="$REPO_ROOT/sanity-check/modules/ngc-check.sh"
    if [ ! -f "$ngc_mod" ]; then
        echo -e "${RED}❌ Missing ${ngc_mod}${NC}" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$ngc_mod"
    run_ngc_key_check_compact
}

# Credentials only — version defaults to latest (Helm search, or NGC: runai_version file) when missing or "latest".
automatic_has_install_credentials() {
    case "${RUNAI_ARTIFACT_SOURCE:-jfrog}" in
        ngc)
            [ -n "${NGC_API_KEY:-}" ] || return 1
            ;;
        *)
            [ -n "${REPO_SECRET:-}" ] && [ -f "${REPO_SECRET}" ] || return 1
            ;;
    esac
    return 0
}

# Set RUNAI_VERSION to a concrete semver: use existing value, or resolve "latest" via parent runai-installer.sh.
automatic_resolve_runai_version_for_automatic() {
    if [ -n "${RUNAI_VERSION:-}" ] && [ "$RUNAI_VERSION" != "latest" ]; then
        echo -e "${GREEN}Using Run:ai version: ${RUNAI_VERSION}${NC} (from command line)"
        export RUNAI_VERSION
        return 0
    fi

    echo -e "${BLUE}Resolving Run:ai control-plane version (Helm search or ${REPO_ROOT:-.}/runai_version with NGC)...${NC}"
    if ! declare -F get_latest_runai_version >/dev/null 2>&1; then
        echo -e "${RED}❌ get_latest_runai_version is not available (run from runai-installer.sh).${NC}" >&2
        return 1
    fi

    local raw detected
    raw="$(get_latest_runai_version)" || {
        echo -e "${RED}❌ Could not resolve Run:ai version (Helm repo / NGC key, or ${REPO_ROOT:-.}/runai_version).${NC}" >&2
        return 1
    }
    detected="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -z "$detected" ]; then
        echo -e "${RED}❌ Could not parse semver from version resolution.${NC}" >&2
        return 1
    fi
    RUNAI_VERSION="$detected"
    export RUNAI_VERSION
    echo -e "${GREEN}Using Run:ai version: ${RUNAI_VERSION}${NC}"
    return 0
}

# Printed once after kubectl check; then user must confirm before any changes.
automatic_print_nodes_brief() {
    local node_rows
    node_rows="$(kubectl get nodes --no-headers 2>/dev/null || true)"
    if [ -z "$node_rows" ]; then
        echo -e "  ${YELLOW}Kubernetes nodes:${NC} unavailable"
        return 0
    fi
    echo -e "  ${YELLOW}Kubernetes nodes:${NC}"
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        echo "    - $row"
    done <<< "$node_rows"
}

automatic_abs_path() {
    local p="$1"
    if [ -z "$p" ]; then
        printf '%s' ""
        return 0
    fi
    case "$p" in
        /*) printf '%s' "$p" ;;
        *) printf '%s/%s' "$REPO_ROOT" "$p" ;;
    esac
}

automatic_print_plan_summary() {
    local ctx server_line
    ctx=$(kubectl config current-context 2>/dev/null || echo "unknown")
    server_line=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Run:ai automatic preparation — planned actions${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}Kubernetes context:${NC}  ${ctx}"
    if [ -n "$server_line" ]; then
        echo -e "  ${YELLOW}API server:${NC}          ${server_line}"
    fi
    automatic_print_nodes_brief
    echo ""
    if [ -n "${DNS_NAME:-}" ]; then
        echo -e "  ${YELLOW}TLS DNS override:${NC}     ${GREEN}${DNS_NAME}${NC} (from ${BLUE}--dns${NC})"
    fi
    # Keep only worker capacity line in the plan banner.
    automatic_print_worker_capacity_one_line 2>&1
    automatic_print_default_storage_class_one_line 2>&1
    echo ""
    automatic_print_component_status_brief
    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        automatic_print_openshift_preconfirm_preview
    fi
    echo ""
    echo -e "  ${BLUE}Installation plan:${NC}"
    echo -e "  Installs the latest NVIDIA Run:ai version and runs sanity checks for cluster readiness."
    echo ""
    if [ "${AUTO_YES:-false}" = true ]; then
        echo -e "  ${GREEN}Non-interactive:${NC} ${BLUE}-y${NC} / ${BLUE}--yes${NC} is set (no confirmation prompts for this plan)."
    fi
    echo ""
}

automatic_print_default_storage_class_one_line() {
    local sc=""
    sc=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
    if [ -z "$sc" ]; then
        sc=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi
    if [ -z "$sc" ]; then
        echo -e "${BLUE}Default storage class -->${NC} ${YELLOW}not found${NC}" >&2
    else
        echo -e "${BLUE}Default storage class -->${NC} ${GREEN}${sc}${NC}" >&2
    fi
}

# Stop after a named phase when AUTOMATIC_STOP_AFTER matches (debug / one-step-at-a-time).
# "hardware" is an alias for "tests" (preflight sanity bundle).
automatic_stop_maybe() {
    local phase="$1"
    if [ -z "${AUTOMATIC_STOP_AFTER:-}" ]; then
        return 1
    fi
    local stop="${AUTOMATIC_STOP_AFTER}"
    [ "$stop" = "hardware" ] && stop="tests"
    [ "$phase" = "hardware" ] && phase="tests"
    if [ "$stop" = "$phase" ]; then
        echo -e "\n${YELLOW}── Stopped after phase: ${AUTOMATIC_STOP_AFTER} ──${NC}"
        return 0
    fi
    return 1
}

automatic_pick_worker_ip() {
    # Prefer nodes without control-plane / master roles.
    local ip
    ip=$(kubectl get nodes -l '!'node-role.kubernetes.io/control-plane -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' 2>/dev/null | head -1)
    if [ -z "$ip" ]; then
        ip=$(kubectl get nodes -l '!'node-role.kubernetes.io/master -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' 2>/dev/null | head -1)
    fi
    if [ -z "$ip" ]; then
        ip=$(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' 2>/dev/null | head -1)
    fi
    if [ -z "$ip" ]; then
        ip=$(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="ExternalIP")]}{.address}{"\n"}{end}{end}' 2>/dev/null | head -1)
    fi
    printf '%s' "$ip"
}

automatic_kib_to_gib() {
    local kib="$1"
    if [ -z "$kib" ] || ! [[ "$kib" =~ ^[0-9]+$ ]]; then
        printf '%s' "n/a"
        return 0
    fi
    awk -v v="$kib" 'BEGIN { printf "%.0f", v/1024/1024 }'
}

automatic_print_cluster_resources_summary() {
    local nodes_json
    nodes_json="$(kubectl get nodes -o json 2>/dev/null || true)"
    if [ -z "$nodes_json" ]; then
        echo -e "${YELLOW}Warning: unable to build cluster resources summary.${NC}" >&2
        return 0
    fi

    local total_nodes total_cpu total_mem_kib total_mem_gib gpu_nodes
    total_nodes="$(printf '%s' "$nodes_json" | jq '.items | length' 2>/dev/null || echo "0")"
    total_cpu="$(printf '%s' "$nodes_json" | jq -r '[.items[].status.capacity.cpu | tonumber] | add // 0' 2>/dev/null || echo "0")"
    total_mem_kib="$(printf '%s' "$nodes_json" | jq -r '[.items[].status.capacity.memory | sub("Ki$";"") | tonumber] | add // 0' 2>/dev/null || echo "0")"
    total_mem_gib="$(awk -v v="${total_mem_kib:-0}" 'BEGIN { printf "%.0f", v/1024/1024 }')"
    gpu_nodes="$(printf '%s' "$nodes_json" | jq -r '[.items[] | select((.status.capacity["nvidia.com/gpu"] // "0") != "0")] | length' 2>/dev/null || echo "0")"

    local gpu_line="None detected"
    if [ "$gpu_nodes" -gt 0 ]; then
        gpu_line="$gpu_nodes detected"
    fi

    echo ""
    echo "Cluster Resources Summary:"
    echo "----------------------------------------"
    echo "Total Nodes: $total_nodes"
    echo "Total CPU Cores: $total_cpu (minimum: 24)"
    echo "Total RAM: ${total_mem_gib}GB (minimum: 24GB)"
    echo "GPU Nodes: $gpu_line"
    echo "Minimum Disk Space: 110GB per node"
}

# One line for --automatic (full table is noisy). Distinguishes control-plane vs workers (scheduling).
automatic_print_cluster_resources_one_line() {
    local nn
    nn="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    nn="${nn:-0}"
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${BLUE}Cluster:${NC} ${nn} node(s)" >&2
        return 0
    fi

    local nodes_json
    nodes_json="$(kubectl get nodes -o json 2>/dev/null || true)"
    if [ -z "$nodes_json" ]; then
        echo -e "${BLUE}Cluster:${NC} ${nn} node(s)" >&2
        return 0
    fi

    local masters workers cpu_total mem_gib cpu_w mem_w_gib tainted_workers
    masters="$(printf '%s' "$nodes_json" | jq '[.items[] | select(
        .metadata.labels["node-role.kubernetes.io/control-plane"] != null or
        .metadata.labels["node-role.kubernetes.io/master"] != null
    )] | length' 2>/dev/null || echo "0")"
    workers="$(printf '%s' "$nodes_json" | jq '[.items[] | select(
        .metadata.labels["node-role.kubernetes.io/control-plane"] == null and
        .metadata.labels["node-role.kubernetes.io/master"] == null
    )] | length' 2>/dev/null || echo "0")"

    cpu_total="$(printf '%s' "$nodes_json" | jq -r '[.items[].status.capacity.cpu | tonumber] | add // 0' 2>/dev/null || echo "?")"
    mem_gib="$(printf '%s' "$nodes_json" | jq -r '[.items[].status.capacity.memory | sub("Ki$";"") | tonumber] | add // 0' 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')"

    local workers_json
    workers_json="$(printf '%s' "$nodes_json" | jq '[.items[] | select(
        .metadata.labels["node-role.kubernetes.io/control-plane"] == null and
        .metadata.labels["node-role.kubernetes.io/master"] == null
    )]' 2>/dev/null || echo "[]")"
    cpu_w="$(printf '%s' "$workers_json" | jq -r '[.[].status.capacity.cpu | tonumber] | add // 0' 2>/dev/null || echo "?")"
    mem_w_gib="$(printf '%s' "$workers_json" | jq -r '[.[].status.capacity.memory | sub("Ki$";"") | tonumber] | add // 0' 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')"

    tainted_workers="$(printf '%s' "$workers_json" | jq '[.[] | select(.spec.taints[]? | .effect == "NoSchedule")] | length' 2>/dev/null || echo "0")"

    echo -e "${BLUE}Cluster:${NC} ${nn} node(s) — ${masters} control-plane, ${workers} worker · ${cpu_total} CPU / ~${mem_gib} GiB RAM (total); workers: ~${cpu_w} CPU / ~${mem_w_gib} GiB RAM" >&2
    if [ "${masters:-0}" -gt 0 ] 2>/dev/null; then
        echo -e "  ${YELLOW}Tip:${NC} App workloads usually land on ${BLUE}worker${NC} nodes (control-plane is often tainted)." >&2
    fi
    if [ "${tainted_workers:-0}" -gt 0 ] 2>/dev/null; then
        echo -e "  ${YELLOW}Note:${NC} ${tainted_workers} worker node(s) have ${BLUE}NoSchedule${NC} taints — effective capacity may be lower." >&2
    fi
}

automatic_print_worker_capacity_one_line() {
    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi

    local nodes_json workers_json cpu_w mem_w_gib gpu_w
    local min_cpu=24 min_mem_gib=24 hw_status hw_color
    nodes_json="$(kubectl get nodes -o json 2>/dev/null || true)"
    if [ -z "$nodes_json" ]; then
        return 0
    fi

    workers_json="$(printf '%s' "$nodes_json" | jq '[.items[] | select(
        .metadata.labels["node-role.kubernetes.io/control-plane"] == null and
        .metadata.labels["node-role.kubernetes.io/master"] == null
    )]' 2>/dev/null || echo "[]")"

    cpu_w="$(printf '%s' "$workers_json" | jq -r '[.[].status.capacity.cpu | tonumber] | add // 0' 2>/dev/null || echo "0")"
    mem_w_gib="$(printf '%s' "$workers_json" | jq -r '[.[].status.capacity.memory | sub("Ki$";"") | tonumber] | add // 0' 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')"
    gpu_w="$(printf '%s' "$workers_json" | jq -r '[.[].status.capacity["nvidia.com/gpu"] | (tonumber? // 0)] | add // 0' 2>/dev/null || echo "0")"

    [[ "$cpu_w" =~ ^[0-9]+$ ]] || cpu_w=0
    [[ "$mem_w_gib" =~ ^[0-9]+$ ]] || mem_w_gib=0
    [[ "$gpu_w" =~ ^[0-9]+$ ]] || gpu_w=0

    if [ "$cpu_w" -ge "$min_cpu" ] && [ "$mem_w_gib" -ge "$min_mem_gib" ]; then
        hw_status="Passed"
        hw_color="${GREEN}"
    else
        hw_status="Failed"
        hw_color="${RED}"
    fi

    echo -e "${BLUE}Total Workers:${NC} ${cpu_w} CPU, ~${mem_w_gib} GiB RAM, ${gpu_w} GPU — ${hw_color}${hw_status}${NC} ${YELLOW}(min ${min_cpu} CPU / ${min_mem_gib} GiB RAM)${NC}" >&2
}

automatic_print_node_inventory() {
    local nodes_json
    nodes_json="$(kubectl get nodes -o json 2>/dev/null || true)"
    if [ -z "$nodes_json" ]; then
        echo -e "${YELLOW}Warning: unable to fetch node inventory details.${NC}" >&2
        return 0
    fi

    local node_rows
    node_rows="$(printf '%s' "$nodes_json" | jq -r '
      .items[] |
      . as $n |
      ($n.metadata.name) as $name |
      (if ($n.metadata.labels["node-role.kubernetes.io/control-plane"] != null or $n.metadata.labels["node-role.kubernetes.io/master"] != null)
       then "control-plane" else "worker" end) as $role |
      ($n.status.capacity.cpu // "n/a") as $cpu |
      ($n.status.capacity.memory // "") as $mem |
      ($n.status.capacity["ephemeral-storage"] // "") as $disk |
      (($n.status.conditions[]? | select(.type == "Ready") | .status) // "Unknown") as $ready |
      ([ $n.status.conditions[]? | select((.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") and .status == "True") | .type ] | join(",")) as $pressures |
      "\($name)|\($role)|\($cpu)|\($mem)|\($disk)|\($ready)|\($pressures)"
    ' 2>/dev/null || true)"

    if [ -z "$node_rows" ]; then
        echo -e "${YELLOW}Warning: no nodes found.${NC}" >&2
        return 0
    fi

    local row name role cpu mem_raw disk_raw ready pressures mem_gib disk_gib mem_kib disk_kib
    while IFS= read -r row; do
        [ -z "$row" ] && continue
        IFS='|' read -r name role cpu mem_raw disk_raw ready pressures <<< "$row"
        mem_kib="${mem_raw%Ki}"
        disk_kib="${disk_raw%Ki}"
        mem_gib="$(automatic_kib_to_gib "$mem_kib")"
        disk_gib="$(automatic_kib_to_gib "$disk_kib")"

        echo "  ${name} | ${role} | CPU Cores: ${cpu} | RAM: ${mem_gib}GB | Storage: ${disk_gib}GB" >&2

        if [ "$ready" != "True" ]; then
            echo -e "  ${YELLOW}Warning:${NC} node '${name}' Ready=${ready}" >&2
        fi
        if [ -n "$pressures" ]; then
            echo -e "  ${YELLOW}Warning:${NC} node '${name}' pressure flags: ${pressures}" >&2
        fi
    done <<< "$node_rows"
}

# Human-readable banners go to stderr; stdout is ONLY two lines: WORKER_IP then FQDN (for command substitution).
automatic_list_nodes_and_resolve_ip() {
    echo -e "\n${BLUE}▶ Nodes & DNS (sslip.io)${NC}" >&2

    local AUTO_IP
    AUTO_IP=$(automatic_pick_worker_ip)
    if [ -z "$AUTO_IP" ]; then
        echo -e "${RED}❌ Could not determine a node IP from kubectl${NC}" >&2
        return 1
    fi

    local AUTO_DNS="${AUTO_IP}.sslip.io"
    echo -e "${BLUE}Selected worker IP (preferred non-control-plane):${NC} ${GREEN}${AUTO_IP}${NC}" >&2
    echo -e "${BLUE}FQDN for TLS / Run:ai DNS:${NC} ${GREEN}${AUTO_DNS}${NC}" >&2
    echo -e "${YELLOW}  (sslip.io resolves ${AUTO_DNS} → ${AUTO_IP})${NC}" >&2

    # stdout: machine-readable only (do not echo banners here — breaks nodes_out=$(...))
    printf '%s\n%s\n' "$AUTO_IP" "$AUTO_DNS"
}

automatic_haproxy_ingress_present() {
    if helm status haproxy-kubernetes-ingress -n haproxy-controller &>/dev/null; then
        return 0
    fi
    if kubectl get svc -n haproxy-controller haproxy-kubernetes-ingress &>/dev/null; then
        return 0
    fi
    if kubectl get svc -n haproxy-controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -qE 'haproxy|ingress'; then
        return 0
    fi
    return 1
}

automatic_print_haproxy_gui_hint() {
    local worker_ip="$1"
    local dns_name="$2"
    local http_np="${HAPROXY_HTTP_NODEPORT:-32080}"
    local https_nodeport="${HAPROXY_HTTPS_NODEPORT:-32443}"
    local gui_https="${RUNAI_GUI_HTTPS_PORT:-443}"
    echo -e "\n${BLUE}Run:ai / HAProxy GUI (browser; sslip resolves to worker ${worker_ip}):${NC}"
    echo -e "  ${GREEN}https://${dns_name}:${gui_https}${NC}  (same port Run:ai UI uses)"
    echo -e "  ${GREEN}http://${dns_name}:${http_np}${NC}   (HTTP NodePort ${http_np})"
    echo -e "  ${YELLOW}Direct NodePort HTTPS (debug): https://${dns_name}:${https_nodeport}${NC}"
    echo -e "${YELLOW}  Service externalIPs should include ${worker_ip} so :${gui_https} reaches the ingress.${NC}"
}

automatic_resolve_haproxy_service_name() {
    local info svc_name
    if ! automatic_ensure_haproxy_sh_loaded; then
        return 1
    fi
    info="$(get_haproxy_service_info)"
    svc_name="$(printf '%s' "$info" | cut -d: -f1)"
    [ -n "$svc_name" ] || return 1
    printf '%s\n' "$svc_name"
}

automatic_verify_haproxy_external_ip() {
    local worker_ip="$1"
    local svc_name=""
    local svc_ns="haproxy-controller"
    local ext_ips=""
    local hpq=false
    [ "${HAPROXY_PATCH_QUIET:-false}" = true ] && hpq=true

    svc_name="$(automatic_resolve_haproxy_service_name || true)"

    if [ -z "$svc_name" ]; then
        echo -e "${RED}❌ Could not find HAProxy service in namespace ${svc_ns}${NC}" >&2
        return 1
    fi

    ext_ips="$(kubectl get svc -n "$svc_ns" "$svc_name" -o jsonpath='{range .spec.externalIPs[*]}{.}{" "}{end}' 2>/dev/null | sed 's/[[:space:]]*$//')"
    if printf '%s\n' "$ext_ips" | tr ' ' '\n' | grep -Fxq "$worker_ip"; then
        [ "$hpq" != true ] && echo -e "${GREEN}HAProxy externalIP check: ${svc_ns}/${svc_name} includes ${worker_ip}${NC}"
        return 0
    fi

    [ "$hpq" != true ] && echo -e "${YELLOW}HAProxy externalIP check: expected ${worker_ip}, current: ${ext_ips:-<empty>} — patching again...${NC}"
    if ! automatic_run_sub_installer --install-only --patch-haproxy --use-haproxy --ip "$worker_ip"; then
        [ "$hpq" != true ] && echo -e "${YELLOW}⚠️ HAProxy externalIP patch retry failed — continuing to connectivity checks.${NC}" >&2
        return 0
    fi

    ext_ips="$(kubectl get svc -n "$svc_ns" "$svc_name" -o jsonpath='{range .spec.externalIPs[*]}{.}{" "}{end}' 2>/dev/null | sed 's/[[:space:]]*$//')"
    if printf '%s\n' "$ext_ips" | tr ' ' '\n' | grep -Fxq "$worker_ip"; then
        [ "$hpq" != true ] && echo -e "${GREEN}HAProxy externalIP set to worker node IP: ${worker_ip}${NC}"
        return 0
    fi

    [ "$hpq" != true ] && echo -e "${YELLOW}⚠️ HAProxy service externalIPs still do not include ${worker_ip} (now: ${ext_ips:-<empty>}) — continuing to connectivity checks.${NC}" >&2
    return 0
}

automatic_dump_haproxy_service_debug() {
    local svc_ns="$1"
    local svc_name="$2"
    [ -n "$svc_ns" ] || svc_ns="haproxy-controller"
    [ -n "$svc_name" ] || return 0

    echo -e "${YELLOW}  Debug snapshot for ${svc_ns}/${svc_name}:${NC}" >&2
    echo -e "    externalIPs: $(kubectl get svc -n "$svc_ns" "$svc_name" -o jsonpath='{range .spec.externalIPs[*]}{.}{" "}{end}' 2>/dev/null | sed 's/[[:space:]]*$//' || echo "<query failed>")" >&2
    echo -e "    type: $(kubectl get svc -n "$svc_ns" "$svc_name" -o jsonpath='{.spec.type}' 2>/dev/null || echo "<query failed>")" >&2
    echo -e "    managed-by (managedFields):" >&2
    kubectl get svc -n "$svc_ns" "$svc_name" -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\n"}{end}' 2>/dev/null \
        | sort -u | sed 's/^/      - /' >&2 || true
    echo -e "    kubectl describe svc ${svc_ns}/${svc_name}:" >&2
    kubectl describe svc -n "$svc_ns" "$svc_name" 2>&1 | sed 's/^/    /' >&2 || true
}

automatic_repatch_haproxy_external_ip_for_network_check() {
    local worker_ip="$1"
    local info svc_name svc_ns

    if ! automatic_ensure_haproxy_sh_loaded; then
        return 1
    fi

    info="$(get_haproxy_service_info)"
    svc_name="$(printf '%s' "$info" | cut -d: -f1)"
    svc_ns="$(printf '%s' "$info" | cut -d: -f2)"
    svc_ns="${svc_ns:-haproxy-controller}"

    if [ -z "$svc_name" ]; then
        echo -e "${RED}❌ Could not find HAProxy Ingress service (expected under haproxy-controller).${NC}" >&2
        return 1
    fi

    kubectl patch svc -n "$svc_ns" "$svc_name" --type merge -p '{"spec":{"externalIPs":[]}}' >/dev/null 2>&1 || true

    export IP_ADDRESS="$worker_ip"
    if patch_haproxy_service; then
        return 0
    fi
    echo -e "${RED}❌ HAProxy externalIP patch failed during network check${NC}" >&2
    if [ "${AUTOMATIC_VERBOSE_HAPROXY:-false}" = true ]; then
        automatic_dump_haproxy_service_debug "$svc_ns" "$svc_name"
    fi
    return 1
}

automatic_ensure_haproxy() {
    local worker_ip="$1"
    local dns_name="$2"

    echo -e "\n${BLUE}▶ HAProxy Ingress${NC}"

    if automatic_haproxy_ingress_present; then
        echo -e "${GREEN}HAProxy Ingress already present — patching externalIPs only.${NC}"
        if ! automatic_run_sub_installer --install-only --patch-haproxy --use-haproxy --ip "$worker_ip"; then
            echo -e "${RED}❌ HAProxy externalIP patch failed${NC}" >&2
            return 1
        fi
    else
        echo -e "${YELLOW}HAProxy Ingress not found — installing (Helm) and setting externalIPs…${NC}"
        if ! automatic_run_sub_installer --install-only --haproxy --use-haproxy --ip "$worker_ip"; then
            echo -e "${RED}❌ HAProxy install failed${NC}" >&2
            return 1
        fi
    fi

    if ! automatic_verify_haproxy_external_ip "$worker_ip"; then
        return 1
    fi

    automatic_print_haproxy_gui_hint "$worker_ip" "$dns_name"
}

# Same cleanup as sanity-check.sh --clean (removes sanity-test namespaces / leftover check resources).
automatic_sanity_cleanup_check_traces() {
    if [ ! -f "$REPO_ROOT/sanity-check/sanity-check.sh" ]; then
        return 0
    fi
    ( cd "$REPO_ROOT/sanity-check" && SANITY_SKIP_LATEST_LINK=1 bash ./sanity-check.sh --clean >/dev/null 2>&1 ) || true
}

automatic_probe_stack() {
    # Prometheus: must match modules/prerequisites.sh (release "prometheus" → svc name below).
    # Do not use "helm list | grep prometheus" — that false-positives on namespace "prometheus",
    # runai-prometheus, chart names, etc. and skips the real install.
    HAVE_PROMETHEUS=false
    if kubectl get ns monitoring &>/dev/null \
        && kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus &>/dev/null; then
        HAVE_PROMETHEUS=true
    fi

    HAVE_NGINX=true

    local HELM_RELEASES
    HELM_RELEASES=$(helm list -A 2>/dev/null || true)

    HAVE_GPU=false
    # Namespace-only checks produce false positives after uninstall; require a release or live GPU operator workloads.
    echo "$HELM_RELEASES" | grep -qE 'gpu-operator|nvidia-gpu-operator' && HAVE_GPU=true
    if [ "$HAVE_GPU" = false ]; then
        kubectl get deployment -n gpu-operator --no-headers 2>/dev/null | grep -q . && HAVE_GPU=true
    fi
    if [ "$HAVE_GPU" = false ]; then
        kubectl get pods -n gpu-operator --no-headers 2>/dev/null | grep -qE 'gpu-operator|nvidia-device-plugin|operator-validator|nfd-' && HAVE_GPU=true
    fi

    HAVE_KNATIVE=false
    echo "$HELM_RELEASES" | grep -qE 'knative|knative-serving' && HAVE_KNATIVE=true
    kubectl get namespaces 2>/dev/null | grep -q 'knative-serving' && HAVE_KNATIVE=true

    HAVE_LWS=false
    echo "$HELM_RELEASES" | grep -qE 'lws|local-workload-service' && HAVE_LWS=true
    kubectl get pods -A 2>/dev/null | grep -qi 'lws' && HAVE_LWS=true

    HAVE_TRAINING=false
    echo "$HELM_RELEASES" | grep -qE 'training-operator|kubeflow-training' && HAVE_TRAINING=true
    kubectl get namespaces 2>/dev/null | grep -qE 'training-operator|kubeflow' && HAVE_TRAINING=true

    if ! echo "$HELM_RELEASES" | grep -qE 'nginx|ingress-nginx' && ! kubectl get pods -A 2>/dev/null | grep -q 'ingress-nginx'; then
        HAVE_NGINX=false
    fi
}

# Shown in the pre-confirm plan (same signals as automatic_probe_stack / automatic_haproxy_ingress_present).
# Fixed-width label column (longest: "HAProxy Ingress") so status text aligns.
automatic_print_component_status_brief() {
    local w=20 helm_note lbl
    local fmt
    fmt="%-${w}s"

    echo -e "  ${YELLOW}NVIDIA Run.ai prerequisites${NC}"

    if command -v helm &>/dev/null; then
        helm_note="$(helm version --short 2>/dev/null || echo "?")"
        printf -v lbl "$fmt" "Helm CLI"
        echo -e "  ${BLUE}${lbl}${NC} ${GREEN}present${NC} (${helm_note})"
    else
        printf -v lbl "$fmt" "Helm CLI"
        echo -e "  ${BLUE}${lbl}${NC} ${YELLOW}missing${NC} (install/refresh in this run)"
    fi

    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        :
    else
        echo -e "  ${BLUE}Optional prerequisites:${NC} missing components are auto-detected and installed as needed."
    fi
}

automatic_print_openshift_preconfirm_preview() {
    if declare -F runai_openshift_nfd_status >/dev/null 2>&1 \
        && declare -F runai_openshift_gpu_operator_status >/dev/null 2>&1 \
        && declare -F runai_openshift_knative_serverless_status >/dev/null 2>&1; then
        local nfd gpu kn
        nfd="$(runai_openshift_nfd_status)"
        gpu="$(runai_openshift_gpu_operator_status)"
        kn="$(runai_openshift_knative_serverless_status)"
        echo -e "  NFD (Node Feature Discovery)      →  $(runai_openshift__cstatus "$nfd")  ${YELLOW}(prerequisite for GPU Operator)${NC}"
        echo -e "  NVIDIA GPU Operator               →  $(runai_openshift__cstatus "$gpu")  ${YELLOW}(Run:ai GPU)${NC}"
        if [ "$kn" = "present" ]; then
            echo -e "  Knative (OpenShift Serverless)    →  $(runai_openshift__cstatus "$kn")"
        else
            echo -e "  Knative (OpenShift Serverless)    →  ${YELLOW}not detected${NC}  - Inference will not work"
        fi
    elif declare -F runai_openshift_print_recommended_prereq_operators >/dev/null 2>&1; then
        runai_openshift_print_recommended_prereq_operators
    else
        echo "  (openshift.sh not loaded; cannot list operators)"
    fi
}

# OpenShift: do not install any operators — report only (production; recommend OperatorHub alignment).
automatic_install_missing_optional_openshift_components() {
    return 0
}

automatic_install_missing_optional_components() {
    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        automatic_install_missing_optional_openshift_components
        return $?
    fi
    automatic_probe_stack

    local -a part1_flags=(--install-only)
    [ "$HAVE_PROMETHEUS" = false ] && part1_flags+=(--prometheus)
    [ "$HAVE_GPU" = false ] && part1_flags+=(--gpu-operator)
    [ "$HAVE_KNATIVE" = false ] && part1_flags+=(--knative)
    [ "$HAVE_LWS" = false ] && part1_flags+=(--lws)
    [ "$HAVE_TRAINING" = false ] && part1_flags+=(--training)

    if [ "${#part1_flags[@]}" -gt 1 ]; then
        echo -e "\n${BLUE}Installing optional prerequisites...${NC}"
        if ! automatic_run_sub_installer "${part1_flags[@]}"; then
            echo -e "${RED}❌ install-only prerequisites step failed${NC}" >&2
            return 1
        fi
    else
        echo -e "\n${GREEN}Optional prerequisites already present${NC}."
    fi
    return 0
}

automatic_run_sub_installer() {
    # Run from repo root; clear automatic flags so nested runs are normal install-only.
    ( cd "$REPO_ROOT" && AUTOMATIC_MODE=false AUTO_YES=false AUTOMATIC_CHAIN=false \
        RUNAI_SUBINSTALLER=true \
        RUNAI_ARTIFACT_SOURCE="${RUNAI_ARTIFACT_SOURCE:-jfrog}" \
        NGC_API_KEY="${NGC_API_KEY:-}" \
        RUNAI_K8S_DISTRIBUTION="${RUNAI_K8S_DISTRIBUTION:-}" \
        NO_CERT="${NO_CERT:-false}" \
        bash ./runai-installer.sh "$@" )
}

# Preflight infra summary (minimal output): storage class + internal storage capacity.
automatic_emit_storage_ingress_summary() {
    local logf="$1"
    local sc_probe="${2:-}"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/runai-automatic-strip.XXXXXX")"
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$logf" >"$tmp" 2>/dev/null || cp "$logf" "$tmp"

    _automatic_sanitize_infra_reason() {
        local raw="$1"
        printf '%s' "$raw" | sed \
            -e 's/[├└│─]//g' \
            | tr -s ' ' \
            | sed -e 's/^[[:space:]]*//' \
                  -e 's/^Storage:[[:space:]]*warning[[:space:]]*//i' \
                  -e 's/^Storage:[[:space:]]*//i' \
                  -e 's/^warning[[:space:]]*//i'
    }

    _automatic_line_passed() {
        printf '%s\n' "$1" | tail -1 | grep -qE 'PASSED|✅'
    }

    local hw_ok=true disk_ok=true storage_ok=true
    local have_hw=false have_disk=false have_storage=false

    if grep -q "Hardware Check:" "$tmp"; then
        have_hw=true
        _automatic_line_passed "$(grep "Hardware Check:" "$tmp")" || hw_ok=false
    fi
    if grep -q "Disk Check:" "$tmp"; then
        have_disk=true
        _automatic_line_passed "$(grep "Disk Check:" "$tmp")" || disk_ok=false
    fi
    if grep -q "Storage Tests:" "$tmp"; then
        have_storage=true
        _automatic_line_passed "$(grep "Storage Tests:" "$tmp")" || storage_ok=false
    fi

    local internal_ok=true
    [ "$have_hw" = true ] && [ "$hw_ok" = false ] && internal_ok=false
    [ "$have_disk" = true ] && [ "$disk_ok" = false ] && internal_ok=false

    local reason_int=""
    if [ "$internal_ok" != true ]; then
        if [ "$have_hw" = true ] && [ "$hw_ok" = false ]; then
            reason_int="hardware check failed"
        elif [ "$have_disk" = true ] && [ "$disk_ok" = false ]; then
            reason_int="disk / ephemeral storage check failed"
        fi
        local d1 d2
        d1="$(grep -m1 "Insufficient storage" "$tmp" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        d2="$(grep -m1 "Some nodes have storage issues" "$tmp" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$d1" ] && reason_int="$d1"
        [ -z "$reason_int" ] && [ -n "$d2" ] && reason_int="$d2"
        [ -z "$reason_int" ] && reason_int="see ${LOG_FILE:-${REPO_ROOT}/sanity-check/logs/latest.log}"
        reason_int="$(_automatic_sanitize_infra_reason "$reason_int")"
    fi

    # Storage class: cluster has a StorageClass + optional PVC test (when preflight ran --storage).
    if [ -z "$sc_probe" ]; then
        echo -e "${YELLOW}Checking StorageClass ->> Pending — no StorageClass in cluster (local-path install runs later in --automatic)${NC}"
    elif [ "$have_storage" = true ] && [ "$storage_ok" = false ]; then
        echo -e "${RED}Checking StorageClass ->> Failed (class: ${sc_probe})${NC}"
        echo -e "${RED}Failed because: PVC / provisioning test failed (see ${LOG_FILE:-${REPO_ROOT}/sanity-check/logs/latest.log})${NC}"
    else
        echo -e "${GREEN}Checking StorageClass ->> OK - Passed${NC}"
        if [ -n "$sc_probe" ] && [ "$have_storage" != true ]; then
            echo -e "${BLUE}  (StorageClass ${sc_probe} present — PVC test not in this preflight run.)${NC}"
        fi
    fi

    if [ "$internal_ok" = true ]; then
        echo -e "${GREEN}Checking servers internal storage -- OK - Passed${NC}"
    else
        local measured_gb=""
        measured_gb="$(printf '%s' "$reason_int" | sed -n 's/.*Insufficient storage:[[:space:]]*\([0-9]\+\)GB.*/\1/p')"
        if [ -n "$measured_gb" ] && [ "$measured_gb" -ge 50 ]; then
            echo -e "${YELLOW}Checking servers internal storage -- Warning: Recommended 110GB min (minimum 50GB)${NC}"
        elif [ -n "$measured_gb" ] && [ "$measured_gb" -lt 50 ]; then
            echo -e "${RED}Checking servers internal storage -- Failed because: below hard minimum 50GB (detected ${measured_gb}GB)${NC}"
        else
            echo -e "${RED}Checking servers internal storage -- Failed because: ${reason_int}${NC}"
        fi
    fi

    rm -f "$tmp" 2>/dev/null || true
}

# True when the only hard failure is disk below 110GB recommendation but still ≥50GB (UI shows warning, continue flow).
automatic_preflight_is_soft_storage_warning_only() {
    local logf="$1"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/runai-soft.XXXXXX")"
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$logf" >"$tmp" 2>/dev/null || cp "$logf" "$tmp"

    if grep -q "Hardware Check:" "$tmp" && ! grep "Hardware Check:" "$tmp" | tail -1 | grep -qE 'PASSED|✅'; then
        rm -f "$tmp"
        return 1
    fi
    if grep -q "Storage Tests:" "$tmp" && ! grep "Storage Tests:" "$tmp" | tail -1 | grep -qE 'PASSED|✅'; then
        rm -f "$tmp"
        return 1
    fi
    if ! grep -q "Disk Check:" "$tmp" || grep "Disk Check:" "$tmp" | tail -1 | grep -qE 'PASSED|✅'; then
        rm -f "$tmp"
        return 1
    fi

    local gb
    gb="$(grep -oE 'Insufficient storage:[[:space:]]*[0-9]+GB' "$tmp" | head -1 | grep -oE '[0-9]+' || true)"
    rm -f "$tmp"
    [ -z "$gb" ] && return 1
    [ "$gb" -ge 50 ] && [ "$gb" -lt 110 ]
}

# Run sanity-check with args, then always clean sanity-test resources.
automatic_run_sanity_check() {
    local -a sargs=("$@")
    local rc=0
    local out_file=""
    local preflight_summary=false
    # With LOG_FILE, sanity appends the full trace to the main install log (unified)
    local _sc_detail
    if [ -n "${LOG_FILE:-}" ]; then
        _sc_detail="${LOG_FILE} (unified: tail -f ${REPO_ROOT:-.}/logs/latest.log)"
    else
        _sc_detail="${REPO_ROOT}/sanity-check/logs/latest.log"
    fi
    [ "${AUTOMATIC_PREFLIGHT_SUMMARY:-false}" = true ] && preflight_summary=true

    # Keep automatic mode output compact while still logging details under sanity-check/logs.
    sargs+=(--silent)

    out_file="$(mktemp "${TMPDIR:-/tmp}/runai-automatic-sanity.XXXXXX")"
    (
        cd "$REPO_ROOT/sanity-check" || exit 1
        if [ -n "${LOG_FILE:-}" ]; then
            export RUNAI_SANITY_UNIFIED_LOG_FILE="${LOG_FILE}"
        fi
        bash ./sanity-check.sh "${sargs[@]}"
    ) >"$out_file" 2>&1
    rc=$?

    if [ -n "${LOG_FILE:-}" ] && [ -f "$out_file" ]; then
        {
            echo ""
            echo "==== Automatic sanity-check output (${sargs[*]}) ===="
            awk '{print}' "$out_file"
        } >> "$LOG_FILE"
    fi

    if [ -f "$out_file" ]; then
        if [ "$preflight_summary" = true ]; then
            automatic_emit_storage_ingress_summary "$out_file" "${AUTOMATIC_PREFLIGHT_SC_PROBE:-}"
            if [ "$rc" -ne 0 ] && automatic_preflight_is_soft_storage_warning_only "$out_file"; then
                rc=0
            elif [ "$rc" -ne 0 ]; then
                echo -e "${YELLOW}Full details: ${_sc_detail}${NC}"
            fi
        else
            local cluster_summary
            cluster_summary="$(awk '
                /^Cluster Resources Summary:/ {in_block=1; sep=0}
                in_block {
                    print
                    if ($0 ~ /^----------------------------------------$/) {
                        sep++
                        if (sep >= 2) exit
                    }
                }
            ' "$out_file")"

            if [ -n "$cluster_summary" ]; then
                echo "$cluster_summary"
            fi
        fi
    fi

    if [ "$preflight_summary" != true ] && [ "$rc" -ne 0 ] && [ -f "$out_file" ]; then
        local failed_tests
        failed_tests="$(awk '
            /^Test Summary:/ {in_summary=1; next}
            in_summary && /^----------------------------------------$/ {next}
            in_summary && /FAILED/ {print}
        ' "$out_file")"

        if [ -n "$failed_tests" ]; then
            echo -e "${YELLOW}Warnings:${NC}"
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                echo "  - $line"
            done <<< "$failed_tests"
        fi

        if grep -q "Some nodes have storage issues" "$out_file"; then
            echo -e "${YELLOW}Warning:${NC} Some nodes have storage issues."
        fi

        echo -e "${YELLOW}Details: ${_sc_detail}${NC}"
        if [ -n "${LOG_FILE:-}" ]; then
            {
                echo ""
                echo "==== $(date '+%Y-%m-%d %H:%M:%S') Automatic sanity-check FAILED (exit ${rc}) args: ${sargs[*]} ===="
                echo "sanity-check: ${_sc_detail} (TLS: search for 'TLS step:')."
                echo "--- Tail of captured stdout/stderr from this sanity-check.sh run (${out_file}): ---"
                tail -n 150 "$out_file" 2>/dev/null || true
            } >>"$LOG_FILE"
        fi
    fi

    rm -f "$out_file" 2>/dev/null || true

    if [ -n "${LOG_FILE:-}" ]; then
        if ( cd "$REPO_ROOT/sanity-check" && SANITY_SKIP_LATEST_LINK=1 bash ./sanity-check.sh --clean >>"$LOG_FILE" 2>&1 ); then
            echo -e "${GREEN}Deleted test environment.${NC}"
        else
            echo -e "${YELLOW}Deleted test environment (cleanup reported warnings; see log).${NC}"
        fi
    else
        if ( cd "$REPO_ROOT/sanity-check" && SANITY_SKIP_LATEST_LINK=1 bash ./sanity-check.sh --clean >/dev/null 2>&1 ); then
            echo -e "${GREEN}Deleted test environment.${NC}"
        else
            echo -e "${YELLOW}Deleted test environment (cleanup reported warnings).${NC}"
        fi
    fi

    return "$rc"
}

# Upgrade Helm client (official get_helm.sh) before any helm install (HAProxy, NGC repos).
# NGC: charts from helm.ngc.nvidia.com — keep Helm 3 current; fail if get_helm breaks and helm is missing.
automatic_ensure_helm_cli() {
    local want_ngc=false
    if [ "${RUNAI_ARTIFACT_SOURCE:-jfrog}" = "ngc" ] || [ -n "${NGC_API_KEY:-}" ]; then
        want_ngc=true
    fi

    if [ "$want_ngc" = true ]; then
        echo -e "${BLUE}  NGC:${NC} charts at helm.ngc.nvidia.com need a current Helm 3 client."
    fi

    if [ ! -f "$REPO_ROOT/tools/get_helm.sh" ]; then
        echo -e "${RED}❌ Missing $REPO_ROOT/tools/get_helm.sh${NC}" >&2
        if [ "$want_ngc" = true ]; then
            return 1
        fi
        echo -e "${YELLOW}⚠️ Continuing only if helm is already installed.${NC}"
    else
        if ! bash "$REPO_ROOT/tools/get_helm.sh"; then
            echo -e "${YELLOW}⚠️ get_helm.sh exited non-zero.${NC}"
            if [ "$want_ngc" = true ]; then
                echo -e "${RED}❌ NGC flow requires a working Helm 3 binary.${NC}" >&2
                if ! command -v helm &>/dev/null; then
                    return 1
                fi
                echo -e "${YELLOW}⚠️ helm found on PATH; continuing.${NC}"
            else
                echo -e "${YELLOW}⚠️ Continuing if helm is already usable.${NC}"
            fi
        fi
    fi

    if ! command -v helm &>/dev/null; then
        echo -e "${RED}❌ helm not found on PATH after get_helm.sh${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}✅ Helm client:${NC} $(helm version --short 2>/dev/null || helm version 2>/dev/null | head -1)"

    if [ "${AUTOMATIC_QUIET_HELM_REPO_UPDATE:-false}" = true ]; then
        echo -e "${BLUE}Updating Helm repositories (details → ${LOG_FILE:-log})…${NC}"
        if helm repo update >>"${LOG_FILE:-/tmp/runai-installer-helm-repo.log}" 2>&1; then
            echo -e "${GREEN}✅ helm repo update completed${NC}"
        else
            echo -e "${YELLOW}⚠️ helm repo update reported issues (check log). Continuing.${NC}"
        fi
    else
        echo -e "${BLUE}Refreshing Helm repositories (helm repo update)…${NC}"
        if [ -n "${LOG_FILE:-}" ]; then
            helm repo update 2>&1 | tee -a "$LOG_FILE" || echo -e "${YELLOW}⚠️ helm repo update had warnings (ok if no repos yet).${NC}"
        else
            helm repo update || echo -e "${YELLOW}⚠️ helm repo update had warnings (ok if no repos yet).${NC}"
        fi
    fi
}

# Run sanity-check infra: NGC key (if NGC) + hardware / disk / storage (if StorageClass exists).
# OpenShift: NGC (if NGC) + storage (PVC) only — no hardware/disk; routes are platform; no HAProxy/NGINX preflight.
# Call after pre-requisite Helm installs. Sets PREINSTALL_STORAGE_RAN=true when a storage test runs.
automatic_run_preflight_sanity_checks() {
    local auto_dns="$1"
    PREINSTALL_STORAGE_RAN=false

    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        if automatic_is_ngc_mode; then
            NGC_KEY_CHECK_QUIET_OK=1
            if ! automatic_verify_ngc_api_key; then
                unset NGC_KEY_CHECK_QUIET_OK
                echo -e "${RED}Checking NGC Key ->> Failed${NC}" >&2
                return 1
            fi
            unset NGC_KEY_CHECK_QUIET_OK
        fi
        local sc_osp=""
        sc_osp=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
        if [ -z "$sc_osp" ]; then
            sc_osp=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        fi
        if [ -z "$sc_osp" ]; then
            echo -e "${YELLOW}  No StorageClass yet — PVC test runs later when a default class is set.${NC}"
            echo -e "\n${GREEN}✅ OpenShift preflight: NGC step done (or skipped); storage test deferred (wait for StorageClass)${NC}"
            return 0
        fi
        PREINSTALL_STORAGE_RAN=true
        if ! AUTOMATIC_PREFLIGHT_SC_PROBE="$sc_osp" AUTOMATIC_PREFLIGHT_SUMMARY=true automatic_run_sanity_check --storage --class "$sc_osp"; then
            return 1
        fi
        echo -e "\n${GREEN}✅ OpenShift preflight: NGC (as applicable) + storage check passed${NC}"
        return 0
    fi

    if automatic_is_ngc_mode; then
        NGC_KEY_CHECK_QUIET_OK=1
        if ! automatic_verify_ngc_api_key; then
            unset NGC_KEY_CHECK_QUIET_OK
            echo -e "${RED}Checking NGC Key ->> Failed${NC}" >&2
            return 1
        fi
        unset NGC_KEY_CHECK_QUIET_OK
        echo -e "${GREEN}Checking NGC Key >> OK - Passed${NC}"
    else
        echo -e "${YELLOW}Checking NGC Key ->> Skipped (not in NGC mode)${NC}"
    fi

    local sc_probe=""
    sc_probe=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
    if [ -z "$sc_probe" ]; then
        sc_probe=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi

    local -a sargs=(--hardware --disk)
    if [ -n "$sc_probe" ]; then
        sargs+=(--storage --class "$sc_probe")
        PREINSTALL_STORAGE_RAN=true
        echo -e "${BLUE}  Running: hardware, disk, storage (class ${sc_probe})${NC}"
    else
        echo -e "${BLUE}  Running: hardware & disk${NC}"
        echo -e "${YELLOW}  (No StorageClass yet — full storage-class + PVC test runs later.)${NC}"
    fi

    if ! AUTOMATIC_PREFLIGHT_SC_PROBE="$sc_probe" AUTOMATIC_PREFLIGHT_SUMMARY=true automatic_run_sanity_check "${sargs[@]}"; then
        return 1
    fi

    echo -e "\n${GREEN}✅ Infrastructure sanity checks passed${NC}"
    return 0
}

run_automatic_mode() {
    # shellcheck source=/dev/null
    source "$REPO_ROOT/modules/log.sh" 2>/dev/null || true

    PREINSTALL_STORAGE_RAN=false

    export AUTOMATIC_QUIET_HELM_REPO_UPDATE=true
    # Minimal console output for HAProxy patch steps (full patch logic still in modules/haproxy.sh).
    export HAPROXY_PATCH_QUIET=true

    if ! command -v kubectl &>/dev/null; then
        echo -e "${RED}❌ kubectl not found in PATH${NC}" >&2
        return 1
    fi
    if ! kubectl cluster-info &>/dev/null; then
        echo -e "${RED}❌ kubectl cannot reach a cluster${NC}" >&2
        return 1
    fi
    if [ -n "${CERT_FILE:-}" ] && [ -z "${KEY_FILE:-}" ]; then
        echo -e "${RED}❌ --automatic: --key is required when using --cert${NC}" >&2
        return 1
    fi
    if [ -z "${CERT_FILE:-}" ] && [ -n "${KEY_FILE:-}" ]; then
        echo -e "${RED}❌ --automatic: --cert is required when using --key${NC}" >&2
        return 1
    fi

    # shellcheck source=/dev/null
    if [ ! -f "$REPO_ROOT/modules/openshift.sh" ]; then
        echo -e "${RED}❌ Missing $REPO_ROOT/modules/openshift.sh${NC}" >&2
        return 1
    fi
    source "$REPO_ROOT/modules/openshift.sh"
    if runai_cluster_is_openshift; then
        export RUNAI_K8S_DISTRIBUTION=openshift
        export RUNAI_AUTOMATIC_ON_OPENSHIFT=true
    else
        export RUNAI_AUTOMATIC_ON_OPENSHIFT=false
    fi

    automatic_print_plan_summary

    if ! automatic_confirm_msg "Agree to run this preparation now? [y/N]: "; then
        echo -e "${YELLOW}Aborted before starting (no changes made).${NC}"
        return 1
    fi

    echo ""
    echo -e "${BLUE}▶ Starting — Helm CLI${NC}"

    if ! automatic_ensure_helm_cli; then
        return 1
    fi

    if automatic_stop_maybe helm; then return 0; fi

    local nodes_out
    local AUTO_IP="" AUTO_DNS=""
    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        echo -e "\n${BLUE}▶ OpenShift: Run:ai FQDN (control plane)${NC}"
        if [ -n "${DNS_NAME:-}" ]; then
            AUTO_DNS="${DNS_NAME}"
            echo -e "${BLUE}Using user-provided DNS for Run:ai:${NC} ${GREEN}${AUTO_DNS}${NC}"
        else
            if ! AUTO_DNS="$(runai_openshift_default_runai_domain)"; then
                echo -e "${RED}❌ OpenShift: could not read cluster base domain. Try: ${BLUE}kubectl get dns.config cluster -o jsonpath='{.spec.baseDomain}'${NC}" >&2
                echo -e "  Or pass ${BLUE}--dns runai.apps.<cluster-domain>${NC} (NVIDIA: control plane on OpenShift).${NC}" >&2
                return 1
            fi
            echo -e "${GREEN}Using Run:ai FQDN:${NC} ${GREEN}${AUTO_DNS}${NC}"
        fi
        AUTO_IP="$(automatic_pick_worker_ip || true)"
        if [ -n "${LOG_FILE:-}" ] && [ -n "$AUTO_IP" ]; then
            echo "OpenShift automatic: reference worker IP ${AUTO_IP}" >>"$LOG_FILE"
        fi
    else
        nodes_out=$(automatic_list_nodes_and_resolve_ip) || return 1
        AUTO_IP=$(printf '%s\n' "$nodes_out" | sed -n '1p' | tr -d '\r')
        AUTO_DNS=$(printf '%s\n' "$nodes_out" | sed -n '2p' | tr -d '\r')
        if [ -z "$AUTO_IP" ] || [ -z "$AUTO_DNS" ]; then
            echo -e "${RED}❌ Could not parse worker IP / FQDN from Step 1 (stdout must be two lines).${NC}" >&2
            return 1
        fi
        if [ -n "${DNS_NAME:-}" ]; then
            AUTO_DNS="${DNS_NAME}"
            echo -e "${BLUE}Using user-provided DNS for TLS / ingress checks:${NC} ${GREEN}${AUTO_DNS}${NC}"
        fi
    fi

    if automatic_stop_maybe nodes; then return 0; fi

    if ! automatic_install_missing_optional_components; then
        return 1
    fi
    if automatic_stop_maybe prereqs; then return 0; fi

    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" != true ]; then
        echo -e "\n${BLUE}2) Sanity check — NGC key and infrastructure${NC}"
    fi
    if ! automatic_run_preflight_sanity_checks "$AUTO_DNS"; then
        if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
            echo -e "${RED}❌ OpenShift preflight failed — fix NGC key and/or StorageClass / PVC (details above).${NC}" >&2
        else
            echo -e "${RED}❌ Infrastructure sanity checks failed — fix issues before continuing.${NC}" >&2
            echo -e "${YELLOW}Reason:${NC} NGC key and/or hardware/disk/storage checks failed (details above)." >&2
        fi
        if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
            if ! automatic_confirm_msg "Continue installation despite failed OpenShift preflight? [y/N]: "; then
                echo -e "${YELLOW}Stopped after failed OpenShift preflight.${NC}" >&2
                return 1
            fi
            echo -e "${YELLOW}⚠️ Continuing by user request despite failed OpenShift preflight.${NC}" >&2
        else
            if ! automatic_confirm_msg "Continue installation despite failed infrastructure checks? [y/N]: "; then
                echo -e "${YELLOW}Stopped after failed infrastructure checks.${NC}" >&2
                return 1
            fi
            echo -e "${YELLOW}⚠️ Continuing by user request despite failed infrastructure checks.${NC}" >&2
        fi
    fi

    if automatic_stop_maybe tests; then return 0; fi

    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        if [ -n "${LOG_FILE:-}" ]; then
            echo "OpenShift automatic: skipping HAProxy install/probe (platform Routes)." >>"$LOG_FILE"
        fi
        kubectl create namespace runai 2>/dev/null || true
        kubectl create namespace runai-backend 2>/dev/null || true
        runai_openshift_label_runai_namespace_psa
    else
        echo -e "\n${BLUE}▶ Ingress (HAProxy)${NC}"
        if ! automatic_ensure_haproxy "$AUTO_IP" "$AUTO_DNS"; then
            echo -e "${YELLOW}HAProxy setup/patch failed — skipping TLS and remaining steps.${NC}" >&2
            return 1
        fi

        kubectl create namespace runai 2>/dev/null || true
        kubectl create namespace runai-backend 2>/dev/null || true

        echo -e "\n${BLUE}▶ Checking Ingress and network connectivity${NC}"
        if ! automatic_repatch_haproxy_external_ip_for_network_check "$AUTO_IP"; then
            return 1
        fi
    fi
    if automatic_stop_maybe haproxy; then return 0; fi

    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" != true ]; then
        echo -e "\n${BLUE}▶ TLS certificates (${AUTO_DNS})${NC}"
    fi
    export DNS_NAME="$AUTO_DNS"
    local cert_path key_path ca_path tls_cert_source
    # OpenShift: do not create ./certificates or customCA for the router (NVIDIA/Red Hat); optional --cert/--key for special cases
    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ] && [ -z "${CERT_FILE:-}" ] && [ -z "${KEY_FILE:-}" ]; then
        export NO_CERT=true
        tls_cert_source="OpenShift — not created here (use platform/ingress router TLS; full install uses --no-cert)"
        if [ -n "${LOG_FILE:-}" ]; then
            echo "OpenShift automatic: skipping installer certificate generation (--no-cert)." >>"$LOG_FILE"
        fi
        cert_path=""; key_path=""; ca_path=""
    else
    export NO_CERT=false
    if [ -n "${CERT_FILE:-}" ] && [ -n "${KEY_FILE:-}" ]; then
        cert_path="${CERT_FILE}"
        key_path="${KEY_FILE}"
        if [ -n "${CA_CERT_FILE:-}" ]; then
            ca_path="${CA_CERT_FILE}"
            tls_cert_source="user-provided (--cert/--key + --cacert)"
        else
            ca_path="${CERT_FILE}"
            tls_cert_source="user-provided (--cert/--key; --cacert not provided)"
        fi
        echo -e "${BLUE}Using user-provided TLS files for automatic mode:${NC}"
        echo -e "  cert: ${cert_path}"
        echo -e "  key:  ${key_path}"
        echo -e "  cacert (if needed for checks): ${ca_path}"
    else
        unset CERT_FILE KEY_FILE CA_CERT_FILE
    fi

    # shellcheck source=/dev/null
    source "$REPO_ROOT/modules/certificates.sh"
    if [ "${NO_CERT:-false}" != true ]; then
    if ! setup_certificates; then
        echo -e "${RED}❌ Certificate generation/setup failed${NC}" >&2
        return 1
    fi
    fi

    if [ "${NO_CERT:-false}" = true ] && [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        : # no files to resolve
    elif [ -z "${cert_path:-}" ] || [ -z "${key_path:-}" ] || [ -z "${ca_path:-}" ]; then
        cert_path="$REPO_ROOT/certificates/runai.crt"
        key_path="$REPO_ROOT/certificates/runai.key"
        ca_path="$REPO_ROOT/certificates/rootCA.pem"
        tls_cert_source="automatic self-signed (generated by installer)"
    fi
    if [ "${NO_CERT:-false}" != true ]; then
    cert_path="$(automatic_abs_path "$cert_path")"
    key_path="$(automatic_abs_path "$key_path")"
    ca_path="$(automatic_abs_path "$ca_path")"
    if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ] || [ ! -f "$ca_path" ]; then
        echo -e "${RED}❌ TLS files missing for sanity-check (--cert/--key/--cacert).${NC}" >&2
        echo -e "${YELLOW}Resolved paths:${NC} cert=${cert_path} key=${key_path} cacert=${ca_path}" >&2
        return 1
    fi
    fi
    fi

    if automatic_stop_maybe certs; then return 0; fi

    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        if [ -n "${LOG_FILE:-}" ]; then
            {
                echo "OpenShift automatic: route/ingress/TLS preflight skipped by design."
                echo "OpenShift DNS: ${AUTO_DNS}"
            } >>"$LOG_FILE"
        fi
    else
        echo -e "\n${BLUE}▶ TLS / ingress check (sanity-check.sh --use-haproxy)${NC}"
        # SANITY_TLS_FAST: use minimal external TLS check path + faster teardown (see sanity-check run_tls_tests).
        if ! SANITY_TLS_FAST=1 automatic_run_sanity_check \
            --dns "$AUTO_DNS" \
            --cert "$cert_path" \
            --key "$key_path" \
            --cacert "$ca_path" \
            --use-haproxy; then
            echo -e "Checking servers HAProxy + TLS ingress ${RED}->> Failed${NC}" >&2
            echo -e "  ${YELLOW}Log: ${LOG_FILE:-${REPO_ROOT}/sanity-check/logs/latest.log}  (search: ${BLUE}TLS step:${NC})" >&2
            echo -e "${RED}❌ sanity-check.sh (TLS/ingress) failed${NC}" >&2
            automatic_sanity_cleanup_check_traces
            return 1
        fi
        echo -e "Checking servers HAProxy + TLS ingress ${GREEN}->> OK - Passed${NC}"
    fi

    if automatic_stop_maybe tls; then return 0; fi

    echo -e "\n${BLUE}▶ StorageClass & storage test${NC}"
    if [ -z "$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" ]; then
        if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
            echo -e "${RED}❌ No StorageClass in this OpenShift cluster.${NC} Add a default ${BLUE}StorageClass${NC} (storage operator / admin) — this installer does not install local-path on OpenShift." >&2
            return 1
        fi
        echo -e "${YELLOW}No StorageClass resources — installing local-path provisioner (default for automatic).${NC}"
        if ! automatic_run_sub_installer --install-only --install-sc; then
            echo -e "${RED}❌ Local Path Provisioner install failed${NC}" >&2
            return 1
        fi
    fi

    local default_sc
    default_sc=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
    if [ -z "$default_sc" ]; then
        echo -e "${YELLOW}No default StorageClass is set.${NC}"
        kubectl get storageclass
        if [ "${AUTO_YES:-false}" = true ]; then
            default_sc=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [ -z "$default_sc" ]; then
                echo -e "${RED}❌ No StorageClass resources found${NC}" >&2
                return 1
            fi
            echo -e "${BLUE}--yes: selecting first StorageClass: ${default_sc}${NC}"
        else
            read -r -p "Enter StorageClass name to set as default: " default_sc
            if [ -z "$default_sc" ] || ! kubectl get storageclass "$default_sc" &>/dev/null; then
                echo -e "${RED}❌ Invalid or empty StorageClass${NC}" >&2
                return 1
            fi
        fi

        local sc
        for sc in $(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            kubectl patch storageclass "$sc" -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
        done
        kubectl patch storageclass "$default_sc" -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    else
        echo -e "${GREEN}Default StorageClass: ${default_sc}${NC}"
    fi

    default_sc=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
    if [ -z "$default_sc" ]; then
        echo -e "${RED}❌ Could not resolve default StorageClass after patch${NC}" >&2
        return 1
    fi

    if [ "${PREINSTALL_STORAGE_RAN:-false}" = true ]; then
        echo -e "${GREEN}Storage preflight already ran — skipping duplicate storage sanity test.${NC}"
    else
        if ! automatic_run_sanity_check --storage --class "$default_sc"; then
            echo -e "${RED}❌ Storage sanity check failed${NC}" >&2
            return 1
        fi
    fi

    if automatic_stop_maybe storage; then return 0; fi

    if automatic_has_install_credentials; then
        if ! automatic_resolve_runai_version_for_automatic; then
            return 1
        fi
    fi

    local env_file="$REPO_ROOT/logs/automatic-last.env"
    mkdir -p "$REPO_ROOT/logs"
    {
        echo "# Written by --automatic on $(date -Iseconds)"
        echo "export AUTO_IP=${AUTO_IP}"
        echo "export AUTO_DNS=${AUTO_DNS}"
        echo "export RUNAI_DEFAULT_STORAGE_CLASS=${default_sc}"
        if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
            echo "export RUNAI_K8S_DISTRIBUTION=openshift"
            echo "export NO_CERT=${NO_CERT:-false}"
            if [ -n "${RUNAI_OCP_INGRESS_CACERT_FILE:-}" ] && [ -f "${RUNAI_OCP_INGRESS_CACERT_FILE}" ]; then
                echo "export RUNAI_OCP_INGRESS_CACERT_FILE=${RUNAI_OCP_INGRESS_CACERT_FILE}"
            fi
            echo "# (OpenShift) auto-fetches router/Route trust PEM (configmap router-ca, or TLS to AUTO_DNS Route) for runai customCA unless RUNAI_OCP_NO_AUTO_INGRESS_CA=1"
            echo "# (OpenShift) if that fails, export RUNAI_OCP_INGRESS_CACERT_FILE=... and re-run, or: runai_openshift_print_ingress_cacert_hint (see modules/openshift.sh)"
            echo "# (OpenShift) no HAProxy, no route preflight, NO_CERT true = --no-cert on install"
        else
            echo "export RUNAI_INGRESS_CLASS=haproxy"
        fi
        echo "export RUNAI_ARTIFACT_SOURCE=${RUNAI_ARTIFACT_SOURCE:-jfrog}"
        if [ -n "${RUNAI_VERSION:-}" ]; then
            echo "export RUNAI_VERSION=${RUNAI_VERSION}"
        fi
        echo "# Replay full install:"
        if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
            case "${RUNAI_ARTIFACT_SOURCE:-jfrog}" in
                ngc)
                    if [ "${NO_CERT:-false}" = true ]; then
                    echo "# ./runai-installer.sh --dns ${AUTO_DNS} --runai-version \${RUNAI_VERSION:-latest} --openshift --no-cert --ngc-api-key \"\$NGC_API_KEY\""
                    else
                    echo "# ./runai-installer.sh --dns ${AUTO_DNS} --runai-version \${RUNAI_VERSION:-latest} --openshift --ngc-api-key \"\$NGC_API_KEY\""
                    fi
                    ;;
                *)
                    if [ "${NO_CERT:-false}" = true ]; then
                    echo "# ./runai-installer.sh --dns ${AUTO_DNS} --runai-version \${RUNAI_VERSION:-latest} --openshift --no-cert --jfrog --repo-secret ${REPO_SECRET:-./secret.yaml}"
                    else
                    echo "# ./runai-installer.sh --dns ${AUTO_DNS} --runai-version \${RUNAI_VERSION:-latest} --openshift --jfrog --repo-secret ${REPO_SECRET:-./secret.yaml}"
                    fi
                    ;;
            esac
        else
        case "${RUNAI_ARTIFACT_SOURCE:-jfrog}" in
            ngc)
                echo "# ./runai-installer.sh --dns ${AUTO_DNS} --runai-version \${RUNAI_VERSION:-latest} --use-haproxy --patch-haproxy --ip ${AUTO_IP} --haproxy --ngc-api-key \"\$NGC_API_KEY\""
                ;;
            *)
                echo "# ./runai-installer.sh --dns ${AUTO_DNS} --runai-version \${RUNAI_VERSION:-latest} --use-haproxy --patch-haproxy --ip ${AUTO_IP} --haproxy --jfrog --repo-secret ${REPO_SECRET:-./secret.yaml}"
                ;;
        esac
        fi
        echo "# Optional clean slate first: ./runai-installer.sh --uninstall"
    } >"$env_file"
    echo -e "\n${BLUE}Saved: ${env_file}${NC} (source before a manual full install if useful)"

    echo -e "\n${GREEN}✅ Automatic preparation completed.${NC}"
    echo -e "  Default StorageClass: ${default_sc}"

    # Full Run.ai install after prep when credentials are provided (version = latest from Helm unless --runai-version set).
    if [ "${AUTOMATIC_CHAIN:-false}" = true ] && ! automatic_has_install_credentials; then
        echo -e "${RED}❌ --automatic-chain requires ${BLUE}--ngc-api-key${NC} / ${BLUE}NGC_API_KEY${NC} or ${BLUE}--repo-secret FILE${NC}.${NC}" >&2
        return 1
    fi

    if automatic_has_install_credentials; then
        echo -e "\n${BLUE}▶ Full Run.ai install${NC}"
        local -a chain
        if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
            # OpenShift: control plane uses global.config.kubernetesDistribution=openshift; no HAProxy; no installer certs by default
            chain=(--dns "$AUTO_DNS" --runai-version "$RUNAI_VERSION" --openshift)
            [ "${NO_CERT:-false}" = true ] && chain+=(--no-cert)
            if [ -n "${RUNAI_OCP_INGRESS_CACERT_FILE:-}" ] && [ -f "${RUNAI_OCP_INGRESS_CACERT_FILE}" ]; then
                chain+=(--openshift-ingress-cacert "$RUNAI_OCP_INGRESS_CACERT_FILE")
            fi
        else
            chain=(--dns "$AUTO_DNS" --runai-version "$RUNAI_VERSION" --use-haproxy --patch-haproxy --ip "$AUTO_IP" --haproxy)
        fi
        case "${RUNAI_ARTIFACT_SOURCE:-jfrog}" in
            ngc)
                chain+=(--ngc --ngc-api-key "$NGC_API_KEY")
                ;;
            *)
                chain+=(--jfrog --repo-secret "$REPO_SECRET")
                ;;
        esac
        [ "${CLUSTER_ONLY:-false}" = true ] && chain+=(--cluster-only)
        [ -n "${LABEL_NODES:-}" ] && chain+=(--label "$LABEL_NODES")
        if [ -n "${LOG_FILE:-}" ]; then
            echo "Running: ./runai-installer.sh ${chain[*]}" >>"$LOG_FILE"
        fi
        echo -e "${YELLOW}Replay:${NC} same command is saved in ${BLUE}logs/automatic-last.env${NC} (comment at bottom)."
        if ! automatic_run_sub_installer "${chain[@]}"; then
            echo -e "${RED}❌ Full Run.ai install failed${NC}" >&2
            return 1
        fi
        echo -e "\n${GREEN}✅ Automatic mode + full Run.ai install completed.${NC}"
    else
        echo -e "\n${YELLOW}Next (manual full install):${NC}"
        if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
            if [ "${NO_CERT:-false}" = true ]; then
            echo -e "  NGC:   ./runai-installer.sh --dns ${AUTO_DNS} --runai-version latest --openshift --no-cert --ngc-api-key \"\$NGC_API_KEY\""
            echo -e "  JFrog: ./runai-installer.sh --dns ${AUTO_DNS} --runai-version latest --openshift --no-cert --jfrog --repo-secret ./secret.yaml"
            else
            echo -e "  NGC:   ./runai-installer.sh --dns ${AUTO_DNS} --runai-version latest --openshift --ngc-api-key \"\$NGC_API_KEY\""
            echo -e "  JFrog: ./runai-installer.sh --dns ${AUTO_DNS} --runai-version latest --openshift --jfrog --repo-secret ./secret.yaml"
            fi
        else
            echo -e "  NGC:  ./runai-installer.sh --dns ${AUTO_DNS} --runai-version latest --use-haproxy --patch-haproxy --ip ${AUTO_IP} --haproxy --ngc-api-key \"\$NGC_API_KEY\""
            echo -e "  JFrog: ./runai-installer.sh --dns ${AUTO_DNS} --runai-version latest --use-haproxy --patch-haproxy --ip ${AUTO_IP} --haproxy --jfrog --repo-secret ./secret.yaml"
        fi
    fi

    return 0
}

