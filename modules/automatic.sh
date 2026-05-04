#!/bin/bash
# Opinionated automatic cluster preparation (--automatic in runai-installer.sh).
#
# Phases (see --automatic-stop-after): helm → nodes → prereqs → tests → haproxy → certs → tls/ingress (sanity-check) → storage → (full Run:ai @ latest if creds)
#   On OpenShift: no Helm prereq stack; no local-path; no HAProxy/Nginx; no route/ingress/TLS preflight; no auto certs; DNS = runai.apps.<base>.
#   helm       — Helm CLI (get_helm.sh)
#   nodes      — worker IP + <IP>.sslip.io (or OpenShift: runai.apps.<baseDomain>)
#   prereqs    — optional Prometheus / GPU Operator / Knative / LWS / Training / NIM (Helm --install-only); Dynamo is manual --dynamo
#   tests      — preflight: (non-OCP) NGC (if NGC) + hardware / disk / storage; (OpenShift) NGC (if NGC) + StorageClass / PVC; no hardware/disk
#   haproxy    — HAProxy Ingress install/patch + externalIP verify
#   certs      — TLS files + secrets (modules/certificates.sh)
#   tls        — sanity-check.sh --dns … --use-haproxy (ingress + HTTPS)
#   storage    — default StorageClass + storage test if not already run in preflight
#
# Expects GREEN/YELLOW/BLUE/CYAN/RED/NC from runai-installer.sh (CYAN section headers; plan bullets use default terminal fg like node rows).
# Env: AUTOMATIC_STOP_AFTER=phase — exit successfully after that phase (debugging).
# Env: NGC_API_KEY + RUNAI_ARTIFACT_SOURCE=ngc from --ngc-key (for chained --ngc install).

REPO_ROOT="${REPO_ROOT:-$(pwd)}"

for _auto_platform_mod in "$REPO_ROOT/modules/automatic-ocp.sh" "$REPO_ROOT/modules/automatic-vanilla.sh"; do
    if [ ! -f "$_auto_platform_mod" ]; then
        echo "❌ Missing ${_auto_platform_mod}" >&2
        return 1 2>/dev/null || exit 1
    fi
    # shellcheck source=/dev/null
    source "$_auto_platform_mod"
done
unset _auto_platform_mod

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
        case "${RUNAI_ARTIFACT_SOURCE:-jfrog}" in
            ngc)
                echo -e "${RED}❌ Could not resolve Run:ai version (NGC Helm repo + API key, or pin file ${REPO_ROOT:-.}/runai_version).${NC}" >&2
                ;;
            *)
                echo -e "${RED}❌ Could not resolve Run:ai version (JFrog: \`helm search repo runai-backend/control-plane\` after adding the runai-backend repo).${NC}" >&2
                ;;
        esac
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

# Reject rpm/dpkg noise and other non-version strings for the plan banner.
automatic_bcm_version_string_is_valid() {
    local s="$1"
    [ -z "$s" ] && return 1
    if echo "$s" | grep -qiE 'not installed|is not installed|no package|no packages|\(none\)|unable to find|error:|^usage|usage:'; then
        return 1
    fi
    if echo "$s" | grep -qiF 'cluster manager'; then
        echo "$s" | grep -qE '[0-9]+\.[0-9]+' || return 1
    fi
    return 0
}

# Bright VCM / cmsh: official version table — main mode → versioninfo (full Cluster Manager row).
# Example line:  Cluster Manager          11.0
automatic_detect_bcm_version_from_cmsh() {
    local out line ver
    if ! command -v cmsh &>/dev/null; then
        return 1
    fi
    out=$(cmsh -c "main; versioninfo" 2>/dev/null || true)
    if ! echo "$out" | grep -qF 'Cluster Manager'; then
        return 1
    fi
    line=$(printf '%s\n' "$out" | grep -F 'Cluster Manager' | head -1)
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ver=$(printf '%s' "$line" | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9][0-9]*(\.[0-9]+)*(-[[:alnum:].]+)?$/) { print $i; exit }
      }
    }')
    if [ -z "$ver" ]; then
        ver=$(printf '%s' "$line" | awk '{ print $NF }')
    fi
    ver=$(printf '%s' "$ver" | tr -d '\r\n\t ')
    if [ -z "$ver" ] || ! automatic_bcm_version_string_is_valid "$line"; then
        return 1
    fi
    printf '%s' "$line"
    return 0
}

# Best-effort Bright Cluster Manager (BCM) product version on the host running the installer.
# Primary: cmsh -c "main; versioninfo" (full "Cluster Manager …" row). Override: RUNAI_BCM_VERSION="11.0" or full row.
automatic_detect_bcm_version() {
    local v=""
    v=$(automatic_detect_bcm_version_from_cmsh 2>/dev/null) || true
    if automatic_bcm_version_string_is_valid "$v"; then
        printf '%s' "$v"
        return 0
    fi

    if [ -r /cm/local/apps/cm-setup/version ]; then
        v=$(tr -d ' \t\r\n' </cm/local/apps/cm-setup/version)
        if automatic_bcm_version_string_is_valid "$v"; then
            printf '%s' "$v"
            return 0
        fi
    fi
    if [ -r /etc/bright-release ]; then
        v=$(grep -E '^(VERSION|BCM_VERSION)=' /etc/bright-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' \t\r\n')
        if automatic_bcm_version_string_is_valid "$v"; then
            printf '%s' "$v"
            return 0
        fi
    fi
    if command -v rpm &>/dev/null; then
        if rpm -q cm-setup &>/dev/null; then
            v=$(rpm -q cm-setup --queryformat '%{VERSION}-%{RELEASE}' 2>/dev/null || true)
            if automatic_bcm_version_string_is_valid "$v"; then
                printf '%s' "$v"
                return 0
            fi
        fi
        if rpm -q bright-cluster-manager &>/dev/null; then
            v=$(rpm -q bright-cluster-manager --queryformat '%{VERSION}-%{RELEASE}' 2>/dev/null || true)
            if automatic_bcm_version_string_is_valid "$v"; then
                printf '%s' "$v"
                return 0
            fi
        fi
    fi
    if command -v dpkg-query &>/dev/null; then
        if dpkg-query -s cm-setup 2>/dev/null | grep -q '^Status: install ok installed'; then
            v=$(dpkg-query -W -f '${Version}' cm-setup 2>/dev/null || true)
            if automatic_bcm_version_string_is_valid "$v"; then
                printf '%s' "$v"
                return 0
            fi
        fi
    fi
    return 1
}

automatic_print_plan_summary() {
    local ctx server_line bcm_ver plan_lbl_fmt lbl
    plan_lbl_fmt="%-26s"
    ctx=$(kubectl config current-context 2>/dev/null || echo "unknown")
    server_line=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)

    bcm_ver="${RUNAI_BCM_VERSION:-}"
    if [ -z "$bcm_ver" ]; then
        bcm_ver=$(automatic_detect_bcm_version 2>/dev/null || true)
    fi
    if [ -n "$bcm_ver" ] && ! automatic_bcm_version_string_is_valid "$bcm_ver"; then
        bcm_ver=""
    fi

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Run:ai automatic preparation — planned actions${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    printf -v lbl "$plan_lbl_fmt" "Kubernetes context:"
    echo -e "  ${YELLOW}${lbl}${NC}${ctx}"
    if [ -n "$server_line" ]; then
        printf -v lbl "$plan_lbl_fmt" "API server:"
        echo -e "  ${YELLOW}${lbl}${NC}${server_line}"
    fi
    if [ -n "$bcm_ver" ]; then
        local bcm_num bcm_lbl
        bcm_num="$bcm_ver"
        if echo "$bcm_ver" | grep -qF 'Cluster Manager'; then
            bcm_num=$(printf '%s' "$bcm_ver" | awk '{
              for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9][0-9]*(\.[0-9]+)*(-[[:alnum:].]+)?$/) { print $i; exit }
              }
            }')
            [ -z "$bcm_num" ] && bcm_num=$(printf '%s' "$bcm_ver" | awk '{ print $NF }')
        fi
        bcm_num=$(printf '%s' "$bcm_num" | tr -d '\r\n\t ')
        printf -v bcm_lbl "$plan_lbl_fmt" "BCM version:"
        echo -e "  ${YELLOW}${bcm_lbl}${NC}${GREEN}${bcm_num}${NC}"
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
    automatic_probe_stack
    automatic_print_component_status_brief
    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        automatic_print_openshift_preconfirm_preview
    fi
    echo ""
    echo -e "  ${CYAN}Installation plan:${NC}"
    automatic_print_installation_plan_will_do
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
        echo -e "${CYAN}Default storage class -->${NC} ${YELLOW}not found${NC}" >&2
    else
        echo -e "${CYAN}Default storage class -->${NC} ${GREEN}${sc}${NC}" >&2
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

    local nodes_json workers_json capacity_json cpu_w mem_w_gib gpu_w
    local min_cpu=24 min_mem_gib=24 hw_status hw_color
    local cap_lbl worker_n total_n
    nodes_json="$(kubectl get nodes -o json 2>/dev/null || true)"
    if [ -z "$nodes_json" ]; then
        return 0
    fi

    workers_json="$(printf '%s' "$nodes_json" | jq '[.items[] | select(
        .metadata.labels["node-role.kubernetes.io/control-plane"] == null and
        .metadata.labels["node-role.kubernetes.io/master"] == null
    )]' 2>/dev/null || echo "[]")"

    worker_n="$(printf '%s' "$workers_json" | jq 'length' 2>/dev/null || echo 0)"
    total_n="$(printf '%s' "$nodes_json" | jq '.items | length' 2>/dev/null || echo 0)"
    case "$worker_n" in ''|*[!0-9]*) worker_n=0 ;; esac
    case "$total_n" in ''|*[!0-9]*) total_n=0 ;; esac

    # Single-node (or all-in-one) clusters often label every node as control-plane — then "workers" is 0
    # but capacity exists. Sum all nodes for the min-CPU/RAM hint in that case.
    if [ "$worker_n" -eq 0 ] && [ "$total_n" -ge 1 ]; then
        capacity_json="$(printf '%s' "$nodes_json" | jq '[.items[]]' 2>/dev/null || echo "[]")"
        cap_lbl="Workload capacity (all ${total_n} node(s); no dedicated worker role)"
    else
        capacity_json="$workers_json"
        cap_lbl="Total Workers"
    fi

    cpu_w="$(printf '%s' "$capacity_json" | jq -r '[.[].status.capacity.cpu | tonumber] | add // 0' 2>/dev/null || echo "0")"
    mem_w_gib="$(printf '%s' "$capacity_json" | jq -r '[.[].status.capacity.memory | sub("Ki$";"") | tonumber] | add // 0' 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')"
    gpu_w="$(printf '%s' "$capacity_json" | jq -r '[.[].status.capacity["nvidia.com/gpu"] | (tonumber? // 0)] | add // 0' 2>/dev/null || echo "0")"

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

    echo -e "${CYAN}${cap_lbl}:${NC} ${cpu_w} CPU, ~${mem_w_gib} GiB RAM, ${gpu_w} GPU — ${hw_color}${hw_status}${NC} ${YELLOW}(min ${min_cpu} CPU / ${min_mem_gib} GiB RAM)${NC}" >&2
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
    HAVE_NGINX=true

    local HELM_RELEASES
    HELM_RELEASES=$(helm list -A 2>/dev/null || true)
    AUTOMATIC_HELM_LIST_JSON=$(helm list -A -o json 2>/dev/null || echo '[]')

    # Prometheus: (1) this installer's path — release "prometheus" in ns monitoring + default svc name.
    # (2) common alternate — chart kube-prometheus-stack (any release name), often namespace "prometheus"
    #     (e.g. helm install kube-prometheus-stack -n prometheus). Do not grep bare "prometheus" on helm text.
    HAVE_PROMETHEUS=false
    if kubectl get ns monitoring &>/dev/null \
        && kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus &>/dev/null; then
        HAVE_PROMETHEUS=true
    fi
    if [ "$HAVE_PROMETHEUS" = false ]; then
        if command -v jq &>/dev/null && printf '%s' "$AUTOMATIC_HELM_LIST_JSON" | jq -e '.[] | select(.chart | test("kube-prometheus-stack"))' >/dev/null 2>&1; then
            HAVE_PROMETHEUS=true
        elif echo "$HELM_RELEASES" | grep -qF 'kube-prometheus-stack'; then
            HAVE_PROMETHEUS=true
        fi
    fi

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

    HAVE_MPI=false
    kubectl get crd mpijobs.kubeflow.org &>/dev/null && HAVE_MPI=true
    if [ "$HAVE_MPI" = false ]; then
        echo "$HELM_RELEASES" | grep -qE 'mpi-operator|cm-kubernetes-mpi-operator' && HAVE_MPI=true
    fi

    HAVE_TRAINING=false
    kubectl get crd pytorchjobs.kubeflow.org &>/dev/null && HAVE_TRAINING=true
    if [ "$HAVE_TRAINING" = false ]; then
        echo "$HELM_RELEASES" | grep -qE 'training-operator|kubeflow-training' && HAVE_TRAINING=true
    fi
    if [ "$HAVE_TRAINING" = false ]; then
        kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -qE '^(training-operator|kubeflow)$' && HAVE_TRAINING=true
    fi

    HAVE_NIM=false
    if helm status k8s-nim-operator -n nim-operator &>/dev/null \
        || helm status nim-operator -n nim-operator &>/dev/null; then
        HAVE_NIM=true
    fi
    if [ "$HAVE_NIM" = false ] && kubectl get ns nim-operator &>/dev/null; then
        kubectl get pods -n nim-operator --no-headers 2>/dev/null | grep -qiE 'nim-operator|k8s-nim' && HAVE_NIM=true
    fi

    HAVE_DYNAMO=false
    if helm status dynamo-platform -n dynamo-system &>/dev/null; then
        HAVE_DYNAMO=true
    fi
    if [ "$HAVE_DYNAMO" = false ] && kubectl get ns dynamo-system &>/dev/null; then
        kubectl get pods -n dynamo-system --no-headers 2>/dev/null | grep -qiE 'dynamo|grove' && HAVE_DYNAMO=true
    fi

    if ! echo "$HELM_RELEASES" | grep -qE 'nginx|ingress-nginx' && ! kubectl get pods -A 2>/dev/null | grep -q 'ingress-nginx'; then
        HAVE_NGINX=false
    fi

    HAVE_HAPROXY=false
    if automatic_haproxy_ingress_present; then
        HAVE_HAPROXY=true
    fi

    HAVE_ANY_STORAGECLASS=false
    if kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q .; then
        HAVE_ANY_STORAGECLASS=true
    fi

    # Optional Helm chart labels for the pre-confirm banner (jq is a runai-installer prerequisite).
    AUTOMATIC_CHART_KNATIVE_OPERATOR=""
    AUTOMATIC_CHART_GPU_OPERATOR=""
    AUTOMATIC_CHART_PROMETHEUS=""
    AUTOMATIC_KNATIVE_SERVING_SPEC_VERSION=""
    if command -v jq &>/dev/null && [ -n "$AUTOMATIC_HELM_LIST_JSON" ]; then
        AUTOMATIC_CHART_KNATIVE_OPERATOR=$(printf '%s' "$AUTOMATIC_HELM_LIST_JSON" | jq -r '.[] | select(.name == "knative-operator") | .chart' 2>/dev/null | head -1)
        AUTOMATIC_CHART_GPU_OPERATOR=$(printf '%s' "$AUTOMATIC_HELM_LIST_JSON" | jq -r '.[] | select(.name == "gpu-operator" or .name == "nvidia-gpu-operator") | .chart' 2>/dev/null | head -1)
        AUTOMATIC_CHART_PROMETHEUS=$(printf '%s' "$AUTOMATIC_HELM_LIST_JSON" | jq -r '.[] | select(.chart | test("kube-prometheus-stack")) | .chart' 2>/dev/null | head -1)
        AUTOMATIC_CHART_MPI=$(printf '%s' "$AUTOMATIC_HELM_LIST_JSON" | jq -r '.[] | select(.chart | test("mpi-operator")) | .chart' 2>/dev/null | head -1)
        AUTOMATIC_CHART_TRAINING=$(printf '%s' "$AUTOMATIC_HELM_LIST_JSON" | jq -r '.[] | select((.name == "training-operator" or .name == "kubeflow-training") or (.chart | test("training-operator"))) | .chart' 2>/dev/null | head -1)
        AUTOMATIC_CHART_NIM=$(printf '%s' "$AUTOMATIC_HELM_LIST_JSON" | jq -r '.[] | select((.name == "k8s-nim-operator" or .name == "nim-operator") or (.chart | test("k8s-nim-operator"))) | .chart' 2>/dev/null | head -1)
        AUTOMATIC_CHART_DYNAMO=$(printf '%s' "$AUTOMATIC_HELM_LIST_JSON" | jq -r '.[] | select(.name == "dynamo-platform" or (.chart | test("dynamo-platform"))) | .chart' 2>/dev/null | head -1)
    fi
    AUTOMATIC_KNATIVE_SERVING_SPEC_VERSION=$(kubectl get knativeserving knative-serving -n knative-serving -o jsonpath='{.spec.version}' 2>/dev/null || true)
}

# What automatic mode will do after confirmation (vanilla vs OpenShift).
# Lists only missing prerequisite installs (no Run:ai upgrade line). Plain echo = same fg as node rows.
automatic_print_installation_plan_will_do() {
    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        echo "  • Run OpenShift-oriented checks (NGC key if applicable, StorageClass / PVC, etc.)."
        echo "  • Does not install Helm-based HAProxy, Nginx, kube-prometheus-stack, or upstream Knative — align those via OperatorHub if required."
        return 0
    fi

    local any=false
    if [ "$HAVE_PROMETHEUS" = false ]; then
        echo "  • Install Prometheus Stack (kube-prometheus-stack, namespace monitoring)."
        any=true
    fi
    if [ "$HAVE_GPU" = false ]; then
        echo "  • Install NVIDIA GPU Operator."
        any=true
    fi
    if [ "$HAVE_KNATIVE" = false ]; then
        echo "  • Install Knative Serving via Knative Operator Helm chart (knative-operator/knative-operator, same recipe as one-click) + KnativeServing CR with Kourier."
        any=true
    fi
    if [ "$HAVE_LWS" = false ]; then
        echo "  • Install LWS (Local Workload Service)."
        any=true
    fi
    if [ "$HAVE_MPI" = false ]; then
        echo "  • Install Kubeflow MPI Operator (MPIJob)."
        any=true
    fi
    if [ "$HAVE_TRAINING" = false ]; then
        echo "  • Install Kubeflow Training Operator."
        any=true
    fi
    if [ "$HAVE_NIM" = false ]; then
        echo "  • Install NVIDIA NIM Operator (Helm chart nvidia/k8s-nim-operator; GPU Operator should already be present)."
        any=true
    fi
    if [ "$HAVE_HAPROXY" = false ]; then
        echo "  • Install HAProxy Kubernetes Ingress."
        echo "  • HAProxy networking will become default (using externalIPs)."
        any=true
    fi
    if [ "$HAVE_ANY_STORAGECLASS" = false ]; then
        echo "  • Install local-path provisioner and a default StorageClass if the cluster has none."
        any=true
    fi
    if [ "$any" = false ]; then
        echo "  (Nothing from this list is missing — automatic flow continues with Run:ai and remaining steps.)"
    fi
}

# Shown in the pre-confirm plan (same signals as automatic_probe_stack / automatic_haproxy_ingress_present).
# Fixed-width label column so status text aligns.
automatic_print_component_status_brief() {
    local w=26 helm_note lbl fmt detail LBL
    fmt="%-${w}s"
    LBL="${CYAN:-\033[0;36m}"

    echo -e "  ${YELLOW}NVIDIA Run.ai prerequisites${NC}  ${LBL}(current cluster)${NC}"

    if command -v helm &>/dev/null; then
        helm_note="$(helm version --short 2>/dev/null || echo "?")"
        printf -v lbl "$fmt" "Helm CLI"
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}  (${helm_note})"
    else
        printf -v lbl "$fmt" "Helm CLI"
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}missing${NC}  (will be bootstrapped after you confirm)"
    fi

    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        printf -v lbl "$fmt" "Helm stack (vanilla)"
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}n/a on OpenShift${NC}  (see OpenShift operator hints below)"
        return 0
    fi

    printf -v lbl "$fmt" "Prometheus Stack"
    if [ "$HAVE_PROMETHEUS" = true ]; then
        detail=""
        [ -n "${AUTOMATIC_CHART_PROMETHEUS:-}" ] && detail="  (${AUTOMATIC_CHART_PROMETHEUS})"
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}${detail}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (will install kube-prometheus-stack → monitoring)"
    fi

    printf -v lbl "$fmt" "NVIDIA GPU Operator"
    if [ "$HAVE_GPU" = true ]; then
        detail=""
        [ -n "${AUTOMATIC_CHART_GPU_OPERATOR:-}" ] && detail="  (${AUTOMATIC_CHART_GPU_OPERATOR})"
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}${detail}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (will install if missing)"
    fi

    printf -v lbl "$fmt" "Knative Serving"
    if [ "$HAVE_KNATIVE" = true ]; then
        detail=""
        if [ -n "${AUTOMATIC_CHART_KNATIVE_OPERATOR:-}" ]; then
            detail="  (operator chart ${AUTOMATIC_CHART_KNATIVE_OPERATOR}"
            [ -n "${AUTOMATIC_KNATIVE_SERVING_SPEC_VERSION:-}" ] && detail="${detail}, Serving spec ${AUTOMATIC_KNATIVE_SERVING_SPEC_VERSION}"
            detail="${detail})"
        elif [ -n "${AUTOMATIC_KNATIVE_SERVING_SPEC_VERSION:-}" ]; then
            detail="  (KnativeServing spec ${AUTOMATIC_KNATIVE_SERVING_SPEC_VERSION})"
        else
            detail="  (knative-serving namespace or release detected)"
        fi
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}${detail}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (will install: Knative Operator Helm + Serving CR + Kourier)"
    fi

    printf -v lbl "$fmt" "HAProxy Ingress"
    if [ "$HAVE_HAPROXY" = true ]; then
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}  (haproxy-controller / HAProxyTech chart)"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (will install + patch externalIPs)"
    fi

    printf -v lbl "$fmt" "Nginx Ingress"
    if [ "$HAVE_NGINX" = true ]; then
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (optional; not required for this automatic flow)"
    fi

    printf -v lbl "$fmt" "LWS"
    if [ "$HAVE_LWS" = true ]; then
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (will install if missing)"
    fi

    printf -v lbl "$fmt" "MPI Operator"
    if [ "$HAVE_MPI" = true ]; then
        detail=""
        [ -n "${AUTOMATIC_CHART_MPI:-}" ] && detail="  (${AUTOMATIC_CHART_MPI})"
        [ -z "$detail" ] && kubectl get crd mpijobs.kubeflow.org &>/dev/null && detail="  (MPIJob CRD)"
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}${detail}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (will install if missing)"
    fi

    printf -v lbl "$fmt" "Training Operator"
    if [ "$HAVE_TRAINING" = true ]; then
        detail=""
        [ -n "${AUTOMATIC_CHART_TRAINING:-}" ] && detail="  (${AUTOMATIC_CHART_TRAINING})"
        [ -z "$detail" ] && kubectl get crd pytorchjobs.kubeflow.org &>/dev/null && detail="  (PyTorchJob CRD)"
        [ -z "$detail" ] && detail="  (namespace or Helm release detected)"
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}${detail}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (will install if missing)"
    fi

    printf -v lbl "$fmt" "NVIDIA NIM Operator"
    if [ "$HAVE_NIM" = true ]; then
        detail=""
        [ -n "${AUTOMATIC_CHART_NIM:-}" ] && detail="  (${AUTOMATIC_CHART_NIM})"
        [ -z "$detail" ] && detail="  (Helm release k8s-nim-operator / nim-operator or workloads in nim-operator)"
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}${detail}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not detected${NC}  (will install if missing; requires GPU Operator)"
    fi

    printf -v lbl "$fmt" "NVIDIA AI Dynamo"
    if [ "$HAVE_DYNAMO" = true ]; then
        detail=""
        [ -n "${AUTOMATIC_CHART_DYNAMO:-}" ] && detail="  (${AUTOMATIC_CHART_DYNAMO})"
        [ -z "$detail" ] && detail="  (Helm release dynamo-platform in dynamo-system)"
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}${detail}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}not auto-installed${NC}  (opt-in: ./runai-installer.sh ... --dynamo when NGC nvcr pull works)"
    fi

    printf -v lbl "$fmt" "StorageClass"
    if [ "$HAVE_ANY_STORAGECLASS" = true ]; then
        echo -e "  ${LBL}${lbl}${NC} ${GREEN}installed${NC}"
    else
        echo -e "  ${LBL}${lbl}${NC} ${YELLOW}none${NC}  (will install local-path + default class if still missing later)"
    fi
}

automatic_print_openshift_preconfirm_preview() {
    automatic_ocp_print_preconfirm_preview
}

# OpenShift: do not install any operators — report only (production; recommend OperatorHub alignment).
automatic_install_missing_optional_openshift_components() {
    automatic_ocp_install_missing_optional_components
    return $?
}

automatic_install_missing_optional_components() {
    if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
        automatic_install_missing_optional_openshift_components
        return $?
    fi
    automatic_vanilla_install_missing_optional_components
    return $?
}

# Prefer oc on OpenShift so progress matches what users see from `oc get pods` (same kube context).
_automatic_kubectl() {
    if command -v oc >/dev/null 2>&1 \
        && { [ "${RUNAI_K8S_DISTRIBUTION:-}" = "openshift" ] || [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; }; then
        oc "$@"
    else
        kubectl "$@"
    fi
}

# Sums main container ready/total from API (used when the kubectl table READY column sums to 0/0 but pods exist).
automatic_pod_readiness_from_json() {
    local ns="$1"
    _automatic_kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '
    ([.items[]? | .status.containerStatuses? // [] | .[]?] // [])
    as $c
    | (if ($c|length) == 0
       then "0 0"
       else
         (($c | map(if .ready then 1 else 0 end) | add) as $r
            | ($c | length) as $t
            | "\($r) \($t)"
         )
       end
    )' 2>/dev/null
}

# Internal: gather state for one release. Echoes "state|ready|total|n_pods|ns_exists".
_automatic_release_state() {
    local ns="$1"
    local preferred_release="$2"
    local release="$preferred_release"
    local helm_state="not-installed"
    local ready="0" total="0" n_pods="0" pod_counts="" jq_line=""

    if [ -z "$release" ] || ! helm status "$release" -n "$ns" >/dev/null 2>&1; then
        release="$(helm list -n "$ns" --short 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$release" ]; then
        helm_state="$(helm status "$release" -n "$ns" -o json 2>/dev/null | jq -r '.info.status // "unknown"' 2>/dev/null || echo "unknown")"
    fi

    pod_counts="$(_automatic_kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '
        BEGIN { r=0; t=0 }
        { split($2, a, "/"); if (a[1] ~ /^[0-9]+$/) r += a[1]; if (a[2] ~ /^[0-9]+$/) t += a[2]; }
        END { printf "%d %d", r, t }')"
    if [ -n "$pod_counts" ]; then
        ready="$(printf '%s' "$pod_counts" | awk '{print $1}')"
        total="$(printf '%s' "$pod_counts" | awk '{print $2}')"
    fi
    [ -n "$ready" ] || ready="0"
    [ -n "$total" ] || total="0"

    n_pods="$(_automatic_kubectl get pods -n "$ns" -o json 2>/dev/null | jq '.items | length' 2>/dev/null | tr -d "[:space:]")"
    case "$n_pods" in ''|*[!0-9]*) n_pods=0 ;; esac
    # If jq is missing or JSON fetch fails, item count is still 0 while table listing shows pods — align with oc/kubectl -w.
    if [ "$n_pods" -eq 0 ] 2>/dev/null; then
        local plines
        plines="$(_automatic_kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
        case "$plines" in ''|*[!0-9]*) plines=0 ;; esac
        if [ "$plines" -gt 0 ] 2>/dev/null; then n_pods=$plines; fi
    fi
    if [ "$ready" = "0" ] && [ "$total" = "0" ] && [ "$n_pods" -gt 0 ] 2>/dev/null; then
        jq_line="$(automatic_pod_readiness_from_json "$ns" || true)"
        if [ -n "$jq_line" ]; then
            ready="$(printf '%s' "$jq_line" | awk '{print $1}')"
            total="$(printf '%s' "$jq_line" | awk '{print $2}')"
        fi
    fi
    [ -n "$ready" ] || ready="0"
    [ -n "$total" ] || total="0"

    local ns_exists=false
    if _automatic_kubectl get ns "$ns" >/dev/null 2>&1; then ns_exists=true; fi

    printf '%s|%s|%s|%s|%s\n' "$helm_state" "$ready" "$total" "$n_pods" "$ns_exists"
}

# Compute 0..100 percentage for a single release given the structured state.
_automatic_release_pct_from_state() {
    local helm_state="$1" ready="$2" total="$3" n_pods="$4" ns_exists="$5"
    local pct=0
    case "$helm_state" in
        deployed)
            if [ "$total" -gt 0 ] 2>/dev/null && [ "$ready" -ge "$total" ] 2>/dev/null; then
                pct=100
            else
                pct=30
            fi
            ;;
        pending-install|pending-upgrade|pending-rollback)
            pct=10
            ;;
        not-installed)
            if [ "$ns_exists" = true ]; then pct=2; else pct=0; fi
            ;;
        *)
            pct=15
            ;;
    esac
    if [ "$total" -gt 0 ] 2>/dev/null; then
        local ratio_pct=$(( ready * 85 / total ))
        local cand=$(( 10 + ratio_pct ))
        if [ "$pct" -lt "$cand" ]; then pct="$cand"; fi
    elif [ "$n_pods" -gt 0 ] 2>/dev/null; then
        if [ "$pct" -lt 10 ]; then pct=10; fi
    fi
    if [ "$pct" -lt 0 ]; then pct=0; fi
    if [ "$pct" -gt 100 ]; then pct=100; fi
    echo "$pct"
}

# Convert a status into the compact label used in display text.
_automatic_helm_state_compact() {
    case "$1" in
        pending-install) echo "pending" ;;
        pending-upgrade) echo "upgrading" ;;
        pending-rollback) echo "rollback" ;;
        uninstalling) echo "uninstall" ;;
        uninstalled) echo "removed" ;;
        superseded) echo "superseded" ;;
        not-installed) echo "starting" ;;
        *) echo "$1" ;;
    esac
}

# Public: returns 0..100 progress for a single release.
automatic_release_progress_pct() {
    local ns="$1" preferred_release="$2"
    local s helm_state ready total n_pods ns_exists
    s="$(_automatic_release_state "$ns" "$preferred_release")"
    IFS='|' read -r helm_state ready total n_pods ns_exists <<<"$s"
    _automatic_release_pct_from_state "$helm_state" "$ready" "$total" "$n_pods" "$ns_exists"
}

# Format one progress line from a single _automatic_release_state snapshot (pipe-separated).
# Use this with the same snapshot you pass to _automatic_release_pct_from_state so header/steps stay in sync.
_automatic_release_format_line_from_state() {
    local label="$1"
    local s="$2"
    local helm_state ready total n_pods ns_exists pct compact
    IFS='|' read -r helm_state ready total n_pods ns_exists <<<"$s"
    pct="$(_automatic_release_pct_from_state "$helm_state" "$ready" "$total" "$n_pods" "$ns_exists")"
    compact="$(_automatic_helm_state_compact "$helm_state")"

    if [ "$n_pods" -gt 0 ] 2>/dev/null && [ "$ready" = "0" ] && [ "$total" = "0" ]; then
        echo "${label} [${pct}%] ${n_pods} pods (readiness pending, helm: ${compact})"
        return 0
    fi
    # Do not claim "waiting for pods" if table/json already showed readiness work (fixes jq-less or flaky JSON paths).
    if [ "$helm_state" = "not-installed" ] && [ "$n_pods" -eq 0 ] 2>/dev/null \
        && [ "${total:-0}" -eq 0 ] 2>/dev/null && [ "${ready:-0}" -eq 0 ] 2>/dev/null; then
        if [ "$ns_exists" = false ]; then
            echo "${label} [${pct}%] waiting for namespace"
        else
            echo "${label} [${pct}%] waiting for pods"
        fi
        return 0
    fi

    echo "${label} [${pct}%] ${ready}/${total} ready (helm: ${compact})"
}

automatic_release_progress_line() {
    local ns="$1" preferred_release="$2" label="$3"
    local s
    s="$(_automatic_release_state "$ns" "$preferred_release")"
    _automatic_release_format_line_from_state "$label" "$s"
}

# True when Step 1 backend snapshot indicates Helm deployed and all readiness counters satisfied.
# Until then, Step 2 (runai namespace) must not surface stale helm failed/partial % from a prior run.
_automatic_backend_gate_ok_from_snap() {
    local s="$1"
    local helm_state ready total
    [ -n "$s" ] || return 1
    IFS='|' read -r helm_state ready total _rest <<<"$s"
    case "$(printf '%s' "$helm_state" | tr '[:upper:]' '[:lower:]')" in
        deployed) ;;
        *) return 1 ;;
    esac
    [ "${total:-0}" -gt 0 ] 2>/dev/null || return 1
    [ "${ready:-0}" -ge "${total:-0}" ] 2>/dev/null || return 1
    return 0
}

# Print up to N pods that are not Ready (READY column != "x/x" or status != Running/Completed).
automatic_blocking_pods_summary() {
    local ns="$1"
    local limit="${2:-3}"
    _automatic_kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk -v lim="$limit" '
        {
            name=$1; ready=$2; status=$3
            split(ready, a, "/")
            ok = (a[1] != "" && a[1] == a[2] && a[1] != 0) || (status == "Completed" || status == "Succeeded")
            if (!ok) {
                if (count < lim) {
                    if (count > 0) printf ", "
                    printf "%s(%s,%s)", name, ready, status
                    count++
                } else if (count == lim) {
                    extra++
                }
            }
        }
        END { if (extra > 0) printf " +%d more", extra }
    '
}

# Truncate monitor lines so the 4-line block does not wrap (wrap breaks \033[4A redraw).
_automatic_monitor_trunc_line() {
    local s="$1"
    local max="${2:-200}"
    local len=${#s}
    if [ "$len" -le "$max" ]; then
        printf '%s' "$s"
        return 0
    fi
    printf '%s…' "${s:0:$((max - 1))}"
}

# Writes 4 lines: backend_snap, runai_snap, backend_blocking, cluster_blocking (for async poll while spinner runs).
_automatic_monitor_collect_snapshots() {
    local out="$1"
    local bs rs bb cb
    bs="$(_automatic_release_state "runai-backend" "runai-backend" 2>/dev/null || true)"
    rs="$(_automatic_release_state "runai" "runai" 2>/dev/null || true)"
    bb="$(automatic_blocking_pods_summary runai-backend 3 2>/dev/null || true)"
    cb="$(automatic_blocking_pods_summary runai 3 2>/dev/null || true)"
    printf '%s\n%s\n%s\n%s\n' "$bs" "$rs" "$bb" "$cb" > "$out"
}

automatic_monitor_control_plane_install() {
    local child_pid="$1"
    local started_ts now_ts elapsed_s elapsed_h elapsed_m elapsed_disp=""
    local -a spinner_chars=($'\\' '|' '/' '-')
    local spinner_idx=0
    local first_render=true
    local use_inplace=true
    local term_cols=120
    local cached_line1 cached_line2 cached_line3 cached_bar cached_pct
    local snapf poll_pid
    local backend_snap runai_snap backend_blocking cluster_blocking
    local backend_line cluster_line backend_pct cluster_pct overall_pct
    local bar_width filled empty bar i
    local C_CYAN='' C_GREEN='' C_DIM='' C_RESET=''
    local spin header line1 line2 line3

    cached_line1="  Step 1 backend: [0%] starting"
    cached_line2="  Step 2 runai:   [0%] pending"
    cached_line3="  blocking — none"
    cached_bar=""
    i=0
    while [ "$i" -lt 20 ]; do cached_bar+='▱'; i=$((i+1)); done
    cached_pct=0

    started_ts="$(date +%s 2>/dev/null || echo 0)"
    if [ -t 1 ]; then
        term_cols="$(tput cols 2>/dev/null || echo "${COLUMNS:-120}")"
        case "$term_cols" in ''|*[!0-9]*) term_cols=120 ;; esac
        [ "$term_cols" -lt 40 ] 2>/dev/null && term_cols=120
    else
        use_inplace=false
    fi

    while kill -0 "$child_pid" >/dev/null 2>&1; do
        if [ "$use_inplace" = true ] && [ -t 1 ]; then
            term_cols="$(tput cols 2>/dev/null || echo "${COLUMNS:-120}")"
            case "$term_cols" in ''|*[!0-9]*) term_cols=120 ;; esac
            if [ "$term_cols" -lt 40 ] 2>/dev/null; then term_cols=120; fi
        fi

        snapf="$(mktemp "${TMPDIR:-/tmp}/runai-mon.XXXXXX")" || continue

        if [ "$use_inplace" != true ] || [ ! -t 1 ]; then
            _automatic_monitor_collect_snapshots "$snapf"
        else
            (_automatic_monitor_collect_snapshots "$snapf") &
            poll_pid=$!
            while kill -0 "$poll_pid" 2>/dev/null; do
                if ! kill -0 "$child_pid" 2>/dev/null; then
                    kill "$poll_pid" 2>/dev/null
                    wait "$poll_pid" 2>/dev/null
                    rm -f "$snapf"
                    break 2
                fi
                now_ts="$(date +%s 2>/dev/null || echo "$started_ts")"
                elapsed_s=$(( now_ts - started_ts ))
                [ "$elapsed_s" -lt 0 ] && elapsed_s=0
                elapsed_h=$(( elapsed_s / 3600 ))
                elapsed_m=$(( (elapsed_s % 3600) / 60 ))
                if [ "$elapsed_h" -gt 0 ]; then
                    elapsed_disp="$(printf '%02dh%02dm' "$elapsed_h" "$elapsed_m")"
                else
                    elapsed_disp="$(printf '%02dm' "$elapsed_m")"
                fi
                C_CYAN=$'\033[36m'
                C_GREEN=$'\033[32;1m'
                C_DIM=$'\033[2m'
                C_RESET=$'\033[0m'
                spin="${spinner_chars[$spinner_idx]}"
                spinner_idx=$(( (spinner_idx + 1) % ${#spinner_chars[@]} ))
                header="$(printf '  %s%s%s installing Run:ai control plane — %s %s%3d%%%s   %selapsed %s%s' \
                    "$C_CYAN" "$spin" "$C_RESET" \
                    "$cached_bar" \
                    "$C_GREEN" "$cached_pct" "$C_RESET" \
                    "$C_DIM" "$elapsed_disp" "$C_RESET")"
                line1="$cached_line1"
                line2="$cached_line2"
                line3="$cached_line3"
                if [ -n "$term_cols" ] && [ "$term_cols" -ge 40 ] 2>/dev/null; then
                    header="$(_automatic_monitor_trunc_line "$header" "$((term_cols - 1))")"
                    line1="$(_automatic_monitor_trunc_line "$line1" "$((term_cols - 1))")"
                    line2="$(_automatic_monitor_trunc_line "$line2" "$((term_cols - 1))")"
                    line3="$(_automatic_monitor_trunc_line "$line3" "$((term_cols - 1))")"
                fi
                if [ "$first_render" = true ]; then
                    printf '%s\n%s\n%s\n%s\n' "$header" "$line1" "$line2" "$line3"
                    first_render=false
                else
                    printf '\033[4A\r\033[2K%s\n\r\033[2K%s\n\r\033[2K%s\n\r\033[2K%s\n' \
                        "$header" "$line1" "$line2" "$line3"
                fi
                sleep 0.08
            done
            wait "$poll_pid" 2>/dev/null || true
        fi

        if ! mapfile -t lines < "$snapf" 2>/dev/null || [ "${#lines[@]}" -lt 4 ]; then
            rm -f "$snapf"
            continue
        fi
        rm -f "$snapf"

        backend_snap="${lines[0]-}"
        runai_snap="${lines[1]-}"
        backend_blocking="${lines[2]-}"
        cluster_blocking="${lines[3]-}"

        backend_line="$(_automatic_release_format_line_from_state "Step 1 backend:" "$backend_snap")"
        if _automatic_backend_gate_ok_from_snap "$backend_snap"; then
            cluster_line="$(_automatic_release_format_line_from_state "Step 2 runai:  " "$runai_snap")"
        else
            cluster_line="Step 2 runai:   [0%] 0/0 ready (helm: waiting for backend)"
        fi

        backend_pct=0
        cluster_pct=0
        if [ -n "$backend_snap" ]; then
            IFS='|' read -r _b_hs _b_r _b_t _b_np _b_nse <<<"$backend_snap"
            backend_pct="$(_automatic_release_pct_from_state "$_b_hs" "$_b_r" "$_b_t" "$_b_np" "$_b_nse" 2>/dev/null || echo 0)"
        fi
        if _automatic_backend_gate_ok_from_snap "$backend_snap" && [ -n "$runai_snap" ]; then
            IFS='|' read -r _r_hs _r_r _r_t _r_np _r_nse <<<"$runai_snap"
            cluster_pct="$(_automatic_release_pct_from_state "$_r_hs" "$_r_r" "$_r_t" "$_r_np" "$_r_nse" 2>/dev/null || echo 0)"
        fi
        case "$backend_pct" in ''|*[!0-9]*) backend_pct=0 ;; esac
        case "$cluster_pct" in ''|*[!0-9]*) cluster_pct=0 ;; esac
        overall_pct=$(( (backend_pct + cluster_pct) / 2 ))
        if [ "$overall_pct" -lt 0 ]; then overall_pct=0; fi
        if [ "$overall_pct" -gt 100 ]; then overall_pct=100; fi

        bar_width=20
        filled=$(( overall_pct * bar_width / 100 ))
        [ "$filled" -lt 0 ] && filled=0
        [ "$filled" -gt "$bar_width" ] && filled="$bar_width"
        empty=$(( bar_width - filled ))
        bar=""
        i=0
        while [ "$i" -lt "$filled" ]; do bar+='▰'; i=$((i+1)); done
        i=0
        while [ "$i" -lt "$empty" ]; do bar+='▱'; i=$((i+1)); done

        cached_pct=$overall_pct
        cached_bar="$bar"
        cached_line1="  ${backend_line:-Step 1 backend: [0%] starting}"
        cached_line2="  ${cluster_line:-Step 2 runai:   [0%] pending}"
        if [ -n "$backend_blocking" ] && [ -n "$cluster_blocking" ]; then
            cached_line3="  blocking — backend: ${backend_blocking}; runai: ${cluster_blocking}"
        elif [ -n "$backend_blocking" ]; then
            cached_line3="  blocking — backend: ${backend_blocking}"
        elif [ -n "$cluster_blocking" ]; then
            cached_line3="  blocking — runai: ${cluster_blocking}"
        else
            cached_line3="  blocking — none"
        fi

        if [ "$use_inplace" != true ] || [ ! -t 1 ]; then
            now_ts="$(date +%s 2>/dev/null || echo "$started_ts")"
            elapsed_s=$(( now_ts - started_ts ))
            [ "$elapsed_s" -lt 0 ] && elapsed_s=0
            elapsed_h=$(( elapsed_s / 3600 ))
            elapsed_m=$(( (elapsed_s % 3600) / 60 ))
            if [ "$elapsed_h" -gt 0 ]; then
                elapsed_disp="$(printf '%02dh%02dm' "$elapsed_h" "$elapsed_m")"
            else
                elapsed_disp="$(printf '%02dm' "$elapsed_m")"
            fi
            spin="${spinner_chars[$spinner_idx]}"
            spinner_idx=$(( (spinner_idx + 1) % ${#spinner_chars[@]} ))
            C_CYAN=$'\033[36m'
            C_GREEN=$'\033[32;1m'
            C_DIM=$'\033[2m'
            C_RESET=$'\033[0m'
            header="$(printf '  %s%s%s installing Run:ai control plane — %s %s%3d%%%s   %selapsed %s%s' \
                "$C_CYAN" "$spin" "$C_RESET" \
                "$cached_bar" \
                "$C_GREEN" "$cached_pct" "$C_RESET" \
                "$C_DIM" "$elapsed_disp" "$C_RESET")"
            line1="$cached_line1"
            line2="$cached_line2"
            line3="$cached_line3"
            if [ -n "$term_cols" ] && [ "$term_cols" -ge 40 ] 2>/dev/null; then
                header="$(_automatic_monitor_trunc_line "$header" "$((term_cols - 1))")"
                line1="$(_automatic_monitor_trunc_line "$line1" "$((term_cols - 1))")"
                line2="$(_automatic_monitor_trunc_line "$line2" "$((term_cols - 1))")"
                line3="$(_automatic_monitor_trunc_line "$line3" "$((term_cols - 1))")"
            fi
            if [ "$first_render" = true ]; then
                first_render=false
            else
                printf '\n'
            fi
            printf '%s\n%s\n%s\n%s\n' "$header" "$line1" "$line2" "$line3"
            sleep 1
        fi
    done
    echo ""
}

automatic_run_sub_installer() {
    local tmp rc
    tmp="$(mktemp "${TMPDIR:-/tmp}/runai-subinstaller.XXXXXX")" || return 1
    # Run from repo root; clear automatic flags so nested runs are normal install-only.
    (
        cd "$REPO_ROOT" && AUTOMATIC_MODE=false AUTO_YES=true AUTOMATIC_CHAIN=false \
            RUNAI_SUBINSTALLER=true \
            RUNAI_ARTIFACT_SOURCE="${RUNAI_ARTIFACT_SOURCE:-jfrog}" \
            NGC_API_KEY="${NGC_API_KEY:-}" \
            RUNAI_K8S_DISTRIBUTION="${RUNAI_K8S_DISTRIBUTION:-}" \
            NO_CERT="${NO_CERT:-false}" \
            bash ./runai-installer.sh "$@"
    ) >"$tmp" 2>&1 &
    local sub_pid=$!

    if [ "${RUNAI_AUTO_MONITOR_CONTROL_PLANE:-false}" = true ]; then
        automatic_monitor_control_plane_install "$sub_pid"
    fi

    wait "$sub_pid"
    rc=$?

    if [ -n "${LOG_FILE:-}" ] && [ -f "$tmp" ]; then
        {
            echo ""
            echo "==== Sub-installer output: ./runai-installer.sh $* ===="
            awk '{print}' "$tmp"
        } >>"$LOG_FILE"
    fi

    if [ "$rc" -ne 0 ]; then
        echo -e "${RED}❌ Sub-installer step failed.${NC} ${YELLOW}Details:${NC} ${LOG_FILE:-$tmp}" >&2
    fi
    rm -f "$tmp" 2>/dev/null || true
    return "$rc"
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
            echo -e "${GREEN}Checking NGC Key ->> OK - Passed${NC}"
        else
            echo -e "${YELLOW}Checking NGC Key ->> Skipped (not in NGC mode)${NC}"
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
        local first_try_out=""
        first_try_out="$(mktemp "${TMPDIR:-/tmp}/runai-storage-first.XXXXXX")" || return 1
        if AUTOMATIC_PREFLIGHT_SC_PROBE="$sc_osp" AUTOMATIC_PREFLIGHT_SUMMARY=true automatic_run_sanity_check --storage --class "$sc_osp" >"$first_try_out" 2>&1; then
            awk '{print}' "$first_try_out"
        else
            # Transient CSI/PVC races are common on busy clusters; retry once before failing preflight.
            echo -e "${YELLOW}Checking StorageClass ->> Retrying (transient PVC probe issue)...${NC}"
            sleep 5
            if ! AUTOMATIC_PREFLIGHT_SC_PROBE="$sc_osp" AUTOMATIC_PREFLIGHT_SUMMARY=true automatic_run_sanity_check --storage --class "$sc_osp"; then
                rm -f "$first_try_out" 2>/dev/null || true
                return 1
            fi
        fi
        rm -f "$first_try_out" 2>/dev/null || true
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
        echo -e "${GREEN}Checking NGC Key ->> OK - Passed${NC}"
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
        kubectl create namespace runai >/dev/null 2>&1 || true
        kubectl create namespace runai-backend >/dev/null 2>&1 || true
        runai_openshift_label_runai_namespace_psa
    else
        echo -e "\n${BLUE}▶ Ingress (HAProxy)${NC}"
        if ! automatic_ensure_haproxy "$AUTO_IP" "$AUTO_DNS"; then
            echo -e "${YELLOW}HAProxy setup/patch failed — skipping TLS and remaining steps.${NC}" >&2
            return 1
        fi

        kubectl create namespace runai >/dev/null 2>&1 || true
        kubectl create namespace runai-backend >/dev/null 2>&1 || true

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
        echo -e "\n${BLUE}▶ TLS / ingress check${NC}"
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

    local storage_phase_silent=false
    if [ "${PREINSTALL_STORAGE_RAN:-false}" = true ]; then
        storage_phase_silent=true
    fi
    if [ "$storage_phase_silent" != true ]; then
        echo -e "\n${BLUE}▶ StorageClass & storage test${NC}"
    fi
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
        [ "$storage_phase_silent" != true ] && echo -e "${GREEN}Default StorageClass: ${default_sc}${NC}"
    fi

    default_sc=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
    if [ -z "$default_sc" ]; then
        echo -e "${RED}❌ Could not resolve default StorageClass after patch${NC}" >&2
        return 1
    fi

    if [ "${PREINSTALL_STORAGE_RAN:-false}" != true ]; then
        if ! automatic_run_sanity_check --storage --class "$default_sc"; then
            echo -e "${RED}❌ Storage sanity check failed${NC}" >&2
            return 1
        fi
    fi

    if automatic_stop_maybe storage; then return 0; fi

    if automatic_has_install_credentials; then
        local version_resolve_out=""
        version_resolve_out="$(mktemp "${TMPDIR:-/tmp}/runai-version-resolve.XXXXXX")" || return 1
        if ! automatic_resolve_runai_version_for_automatic >"$version_resolve_out" 2>&1; then
            if [ -n "${LOG_FILE:-}" ] && [ -f "$version_resolve_out" ]; then
                {
                    echo ""
                    echo "==== Automatic version resolution output ===="
                    awk '{print}' "$version_resolve_out"
                } >>"$LOG_FILE"
            fi
            awk '{print}' "$version_resolve_out" >&2 || true
            rm -f "$version_resolve_out" 2>/dev/null || true
            return 1
        fi
        if [ -n "${LOG_FILE:-}" ] && [ -f "$version_resolve_out" ]; then
            {
                echo ""
                echo "==== Automatic version resolution output ===="
                awk '{print}' "$version_resolve_out"
            } >>"$LOG_FILE"
        fi
        rm -f "$version_resolve_out" 2>/dev/null || true
        if [ -n "${RUNAI_VERSION:-}" ]; then
            echo -e "Using Run:ai version: ${RUNAI_VERSION}"
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
        if [ "${RUNAI_ONLY:-false}" = true ]; then
            echo "# This run used --automatic --runai-only: final install omitted prereqs; append --runai-only to manual replay commands above (vanilla: use --use-haproxy only, not --haproxy/--patch-haproxy)."
        fi
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
        echo -e "\n${BLUE}▶ Installing Run:ai control plane${NC}"
        echo -e "  ${BLUE}Two-step install:${NC} ${GREEN}(1) runai-backend${NC} → ${GREEN}(2) runai${NC}. The block below shows ${GREEN}overall %${NC}, each step, and ${GREEN}blocking pods${NC} (refreshed in place)."
        local -a chain
        if [ "${RUNAI_AUTOMATIC_ON_OPENSHIFT:-false}" = true ]; then
            # OpenShift: control plane uses global.config.kubernetesDistribution=openshift; no HAProxy; no installer certs by default
            chain=(--dns "$AUTO_DNS" --runai-version "$RUNAI_VERSION" --openshift)
            [ "${NO_CERT:-false}" = true ] && chain+=(--no-cert)
            if [ -n "${RUNAI_OCP_INGRESS_CACERT_FILE:-}" ] && [ -f "${RUNAI_OCP_INGRESS_CACERT_FILE}" ]; then
                chain+=(--openshift-ingress-cacert "$RUNAI_OCP_INGRESS_CACERT_FILE")
            fi
        else
            # With --runai-only, automatic mode has already installed/patched HAProxy; only pass ingress class (not --haproxy/--patch-haproxy — validate_params rejects those with --runai-only).
            if [ "${RUNAI_ONLY:-false}" = true ]; then
                chain=(--dns "$AUTO_DNS" --runai-version "$RUNAI_VERSION" --use-haproxy)
            else
                chain=(--dns "$AUTO_DNS" --runai-version "$RUNAI_VERSION" --use-haproxy --patch-haproxy --ip "$AUTO_IP" --haproxy)
            fi
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
        [ "${RUNAI_ONLY:-false}" = true ] && chain+=(--runai-only)
        if [ -n "${LOG_FILE:-}" ]; then
            echo "Running: ./runai-installer.sh ${chain[*]}" >>"$LOG_FILE"
        fi
        echo -e "${YELLOW}Replay:${NC} same command is saved in ${BLUE}logs/automatic-last.env${NC}."
        if ! RUNAI_AUTO_MONITOR_CONTROL_PLANE=true automatic_run_sub_installer "${chain[@]}"; then
            echo -e "${RED}❌ Full Run.ai install failed${NC}" >&2
            return 1
        fi
        echo -e "\n${GREEN}✅ Run.ai installation completed successfully${NC}"
        echo -e "  Access URL: https://${AUTO_DNS}"
        if [ "${CLUSTER_ONLY:-false}" != true ]; then
            echo -e "  Credentials: test@run.ai / Abcd!234"
        fi
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

