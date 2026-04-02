#!/bin/bash
# NGC API key validation for Run:ai (Helm index + nvcr.io image pulls).
# Sourced by sanity-check.sh. Expects NGC_API_KEY to be set (from --ngc-key or environment).
# Reference: same auth as modules/ngc.sh (installer).

# Normalize key like runai-installer load_env / modules/ngc.sh
ngc_check_normalize_key() {
    printf '%s' "${NGC_API_KEY:-}" | tr -d '\r\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^"//; s/"$//'
}

# GET url with NGC basic auth; prints HTTP status code only.
ngc_check_http_status() {
    local url="$1"
    curl -sS -L -o /dev/null -w "%{http_code}" -u "\$oauthtoken:${NGC_API_KEY}" "$url" 2>/dev/null || echo "000"
}

# How we test (same idea as installer modules/ngc.sh):
# 1) Helm: GET Run:ai index with Basic auth user $oauthtoken — must be HTTP 200 for a good key + chart access.
# 2) nvcr: GET /v2/ is informational only. Many registries (including nvcr) answer 401 to a bare /v2/ and
#    expect a token exchange; that is NOT the same as a bad API key. Do not fail the check on nvcr alone.

run_ngc_key_check() {
    NGC_API_KEY="$(ngc_check_normalize_key)"
    if [ -z "$NGC_API_KEY" ]; then
        echo -e "${RED}❌ NGC API key is empty (use --ngc-key or set NGC_API_KEY).${NC}" >&2
        return 1
    fi
    export NGC_API_KEY

    echo -e "${BLUE}NGC API key checks (key not logged)${NC}"
    echo -e "${BLUE}  • Helm index = authoritative (matches installer preflight).${NC}"
    echo -e "${BLUE}  • nvcr /v2/ = optional probe (401 is common even with a valid key).${NC}"

    local helm_code nvcr_code
    helm_code="$(ngc_check_http_status "https://helm.ngc.nvidia.com/nvidia/runai/index.yaml")"
    nvcr_code="$(ngc_check_http_status "https://nvcr.io/v2/")"

    if [ -n "${LOG_FILE:-}" ]; then
        {
            echo ""
            echo "==== NGC key sanity check ===="
            echo "Helm index HTTP: $helm_code (must be 200 to pass)"
            echo "nvcr.io /v2/ HTTP: $nvcr_code (informational)"
            echo "Executing at: $(date)"
        } >>"$LOG_FILE"
    fi

    if [ "$helm_code" = "200" ]; then
        echo -e "  Helm (runai index.yaml): ${GREEN}HTTP $helm_code OK${NC}"
    else
        echo -e "  Helm (runai index.yaml): ${RED}HTTP $helm_code (need 200)${NC}"
    fi

    case "$nvcr_code" in
        200)
            echo -e "  nvcr.io GET /v2/: ${GREEN}HTTP $nvcr_code OK${NC}"
            ;;
        401)
            echo -e "  nvcr.io GET /v2/: ${YELLOW}HTTP $nvcr_code (normal for token-based registry; not a failure by itself)${NC}"
            ;;
        *)
            echo -e "  nvcr.io GET /v2/: ${YELLOW}HTTP $nvcr_code (see note above)${NC}"
            ;;
    esac

    if [ "$helm_code" = "200" ]; then
        echo -e "${GREEN}✅ NGC key validation passed (Helm index reachable).${NC}"
        echo -e "${YELLOW}Confirm image pulls on the cluster with runai-reg-creds / docker login nvcr.io if needed.${NC}"
        return 0
    fi

    echo -e "${YELLOW}Helm: 400 often means wrong \$oauthtoken quoting; 401/403 = bad key or missing Run:ai Helm entitlement.${NC}" >&2
    return 1
}
