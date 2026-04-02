#!/bin/bash
# Validate an NVIDIA NGC API key for Run:ai Helm charts and nvcr.io image pulls.
# Usage:
#   ./check-ngc-key.sh --ngc-key "nvapi-..."
#   NGC_API_KEY="..." ./check-ngc-key.sh
# Does not print the key; only HTTP status and pass/fail.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo -e "${BLUE}Usage:${NC} $0 --ngc-key <KEY>"
    echo "       NGC_API_KEY=<KEY> $0"
    echo ""
    echo "Checks:"
    echo "  • Helm: GET Run:ai index (same as installer / modules/ngc.sh preflight)"
    echo "  • Registry: GET nvcr.io Docker Registry V2 /v2/ (image pull auth)"
    echo ""
    echo "Exit code 0 if both return HTTP 200, else 1."
    exit 1
}

NGC_KEY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ngc-key)
            NGC_KEY="$2"
            shift 2
            ;;
        --ngc-key=*)
            NGC_KEY="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

if [ -z "$NGC_KEY" ] && [ -n "${NGC_API_KEY:-}" ]; then
    NGC_KEY="$NGC_API_KEY"
fi

if [ -z "$NGC_KEY" ]; then
    echo -e "${RED}Missing key. Pass --ngc-key <KEY> or set NGC_API_KEY.${NC}"
    usage
fi

# Same normalization as modules/ngc.sh / runai-installer load_env
NGC_KEY="$(printf '%s' "$NGC_KEY" | tr -d '\r\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/^"//; s/"$//')"
if [ -z "$NGC_KEY" ]; then
    echo -e "${RED}Key is empty after normalization.${NC}"
    exit 1
fi

check_http() {
    local url="$1"
    local code
    code="$(curl -sS -L -o /dev/null -w "%{http_code}" -u "\$oauthtoken:${NGC_KEY}" "$url" || echo "000")"
    printf '%s' "$code"
}

echo -e "${BLUE}NGC API key validation (key not shown)${NC}"

helm_code="$(check_http "https://helm.ngc.nvidia.com/nvidia/runai/index.yaml")"
if [ "$helm_code" = "200" ]; then
    echo -e "  Helm (runai index.yaml): ${GREEN}HTTP $helm_code OK${NC}"
else
    echo -e "  Helm (runai index.yaml): ${RED}HTTP $helm_code (expected 200)${NC}"
fi

nvcr_code="$(check_http "https://nvcr.io/v2/")"
if [ "$nvcr_code" = "200" ]; then
    echo -e "  nvcr.io (registry /v2/): ${GREEN}HTTP $nvcr_code OK${NC}"
else
    echo -e "  nvcr.io (registry /v2/): ${RED}HTTP $nvcr_code (expected 200)${NC}"
fi

if [ "$helm_code" = "200" ] && [ "$nvcr_code" = "200" ]; then
    echo -e "${GREEN}All checks passed.${NC}"
    exit 0
fi

echo -e "${YELLOW}If you see 400, ensure curl uses username literally: \$oauthtoken (this script does).${NC}"
echo -e "${YELLOW}401/403: invalid key, expired key, or missing NGC entitlements for Run:ai / nvcr.${NC}"
exit 1
