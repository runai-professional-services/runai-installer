# shellcheck shell=bash
# Pod readiness + Helm health for Run.ai installer wait loops (runai.sh, air-gapped.sh).
#
# Prints: "<total> <ready>" for namespace $1. Total = pod list lines; ready = pods that
# are actually available (READY X/X with X>0, or terminal batch success Completed/Succeeded).

# Return Helm release status string (e.g. deployed, failed, pending-install), or
# "missing" if not found. Tolerates Helm 3/4 list JSON, Run:ai using a name like
# "runai-cluster" instead of "runai", and avoids relying on "helm list -f" + "[0]".
runai_helm__list_json_releases() {
  printf '%s' "$1" | jq -c 'if type == "array" then . elif (type == "object" and (."releases" | type) == "array") then ."releases" elif (type == "object" and (.Releases | type) == "array") then .Releases else [] end' 2>/dev/null
}

# Pick one row from a helm list "releases" array: exact $rel, else sole release, else *runai*, else [0]
runai_helm__list_pick_row_jq='
  if (length) < 1 then empty
  else
    (map(select(.name == $rel)) | .[0]) as $ex
    | (if $ex != null then $ex
       elif (length) == 1 then .[0]
       else
         (map(select(.name | startswith("runai"))) | .[0]) as $pfx
         | if $pfx != null then $pfx else .[0] end
      end)
  end'

# Pick the release status from array JSON
runai_helm__list_pick_status() {
  local rel=$1
  local arr
  arr=$(printf '%s' "$2" | jq -c --arg rel "$rel" "$runai_helm__list_pick_row_jq" 2>/dev/null)
  if [ -z "$arr" ] || [ "$arr" = "null" ]; then
    echo "missing"
    return 1
  fi
  printf '%s' "$arr" | jq -r '(.status // "missing")' 2>/dev/null
}

# Resolve release name the same way as _list_pick
runai_helm__resolve_release_name() {
  local rel=$1
  local buf=$2
  local list_arr
  list_arr=$(runai_helm__list_json_releases "$buf")
  if [ -z "$list_arr" ] || [ "$list_arr" = "[]" ]; then
    return
  fi
  local row
  row=$(printf '%s' "$list_arr" | jq -c --arg rel "$rel" "$runai_helm__list_pick_row_jq" 2>/dev/null)
  if [ -n "$row" ] && [ "$row" != "null" ]; then
    printf '%s' "$row" | jq -r '.name // empty' 2>/dev/null
  fi
}

runai_helm_info_status() {
  local rel=$1
  local ns=$2
  local st json list_arr pick_name
  st=""
  json=$(helm list -n "$ns" -o json 2>/dev/null) || json=""
  if [ -n "$json" ]; then
    list_arr=$(runai_helm__list_json_releases "$json")
    if [ -n "$list_arr" ]; then
      st=$(runai_helm__list_pick_status "$rel" "$list_arr")
    fi
  fi
  st=${st%%$'\r'}
  st=$(printf '%s' "$st" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$st" ] && [ "$st" != "null" ] && [ "$st" != "missing" ] && [ "$st" != "unknown" ]; then
    echo "$st"
    return 0
  fi

  pick_name="$(runai_helm__resolve_release_name "$rel" "$json")"
  st=""
  for tryn in "$pick_name" "$rel"; do
    [ -n "$tryn" ] || continue
    st=$(helm status -n "$ns" "$tryn" 2>/dev/null | awk -F: '/^[[:space:]]*STATUS:/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
    if [ -n "$st" ]; then
      break
    fi
  done
  st=${st%%$'\r'}
  st=$(printf '%s' "$st" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$st" ] && [ "$st" != "null" ] && [ "$st" != "missing" ]; then
    echo "$st"
    return 0
  fi

  if [ -n "$pick_name" ]; then
    st=$(helm status -n "$ns" "$pick_name" -o json 2>/dev/null | jq -r 'if .info? and (.info.status | type == "string") then .info.status elif .info? and (.info.status | type) == "object" and (.info.status|has("name")) then .info.status.name else "missing" end' 2>/dev/null)
  else
    st="missing"
  fi
  if [ -z "$st" ] || [ "$st" = "null" ] || [ "$st" = "missing" ]; then
    st=$(helm status -n "$ns" "$rel" -o json 2>/dev/null | jq -r 'if .info? and (.info.status | type == "string") then .info.status elif .info? and (.info.status | type) == "object" and (.info.status|has("name")) then .info.status.name else "missing" end' 2>/dev/null)
  fi
  st=${st%%$'\r'}
  st=$(printf '%s' "$st" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$st" ] && [ "$st" != "null" ] && [ "$st" != "missing" ]; then
    echo "$st"
    return 0
  fi
  echo "missing"
}

runai_pod_readiness_counts() {
  local ns=$1
  local out
  if ! out=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null); then
    echo "0 0"
    return
  fi
  if [ -z "$out" ]; then
    echo "0 0"
    return
  fi
  local tot ready
  tot=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  ready=$(printf '%s\n' "$out" | awk '
  {
    n = $2
    st = $3
    if (st == "Completed" || st == "Succeeded") { c++; next }
    if (n ~ /^[0-9]+\/[0-9]+$/) {
      split(n, a, "/")
      if (a[1] == a[2] && a[1] != 0) c++
    }
  }
  END { print c+0 }')
  echo "$tot $ready"
}

# Return 0 iff the release in namespace is in a "deployed" (healthy) state.
runai_helm_release_is_deployed() {
  local rel=$1
  local ns=$2
  local s
  s=$(runai_helm_info_status "$rel" "$ns")
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  [ "$s" = "deployed" ]
}

# --- Slow cluster / slow image pulls (optional env overrides) ---
# RUNAI_INSTALL_WAIT_MAX_ATTEMPTS — retries for auth probe, token, and (air-gapped) install-info API.
#   Each attempt sleeps RUNAI_INSTALL_WAIT_SLEEP_SEC. Default 600 (~50 min at 5s sleep).
# RUNAI_INSTALL_WAIT_SLEEP_SEC — seconds between those attempts (default 5).
# RUNAI_POD_READY_POLL_SLEEP_SEC — sleep between pod-readiness / Helm status polls (default 10).
# RUNAI_CLUSTER_INSTALL_MAX_RETRIES — air-gapped only: how many times to re-run cluster install.sh (default 10).
runai_install_wait_max_attempts() {
  local v="${RUNAI_INSTALL_WAIT_MAX_ATTEMPTS:-600}"
  if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$v"
  else
    printf '600'
  fi
}

runai_install_wait_sleep_sec() {
  local v="${RUNAI_INSTALL_WAIT_SLEEP_SEC:-5}"
  if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$v"
  else
    printf '5'
  fi
}

runai_pod_ready_poll_sleep_sec() {
  local v="${RUNAI_POD_READY_POLL_SLEEP_SEC:-10}"
  if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$v"
  else
    printf '10'
  fi
}

runai_cluster_install_max_retries() {
  local v="${RUNAI_CLUSTER_INSTALL_MAX_RETRIES:-10}"
  if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$v"
  else
    printf '10'
  fi
}
