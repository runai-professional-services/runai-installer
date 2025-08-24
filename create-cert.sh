#!/usr/bin/env bash

set -euo pipefail

# Colors
NC="\033[0m"; RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
    -d, --dns <name>[,<name>...]   One or more DNS names for the certificate (can be comma-separated or repeated)
                                    Examples: --dns runai.local --dns "*.runai.local,api.runai.local"
    -o, --out-dir <path>            Output directory (default: ./certificates)
        --days <num>                Validity in days (default: 730)
        --password <pass>           Passphrase for CA private key (default: securely generated)
        --test                      After generation, verify certificate against hostnames
        --test-hosts <h[,h,...]>    Comma-separated hostnames to verify (defaults derived from --dns)
    -h, --help                      Show this help

Outputs in the chosen directory:
    rootCA.key      (encrypted with provided/generated passphrase)
    rootCA.pem      (self-signed Root CA certificate)
    runai.key       (service private key)
    runai.csr       (certificate signing request)
    runai.crt       (service certificate signed by Root CA)
    full-chain.pem  (service certificate + Root CA chain)

Examples:
    $(basename "$0") --dns "*.runai.local,runai.local" --out-dir ./certs
    $(basename "$0") --dns "*.kirson.lab,runai.kirson.lab" --test --test-hosts "runai.kirson.lab,runai.apps.sno1.kirson.lab"
EOF
}

ensure_dependencies() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}❌ openssl not found. Please install openssl and retry.${NC}" >&2
        exit 1
    fi
}

join_by_comma() {
    local IFS=","; echo "$*"
}

write_openssl_cnf() {
    local cfg_path="$1"; shift
    local names=("$@")

    echo "basicConstraints = CA:FALSE" >"$cfg_path"
    echo "authorityKeyIdentifier = keyid,issuer" >>"$cfg_path"
    echo "keyUsage = digitalSignature, keyEncipherment" >>"$cfg_path"
    echo "subjectAltName = @alt_names" >>"$cfg_path"
    echo "" >>"$cfg_path"
    echo "[alt_names]" >>"$cfg_path"

    local i=1
    for name in "${names[@]}"; do
        echo "DNS.${i} = ${name}" >>"$cfg_path"
        i=$((i+1))
    done
}

main() {
    ensure_dependencies

    local out_dir="./certificates"
    local days=730
    local passphrase=""
    local names=()
    local run_tests=false
    local user_test_hosts=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dns)
                if [[ $# -lt 2 ]]; then
                    echo -e "${RED}--dns requires a value${NC}" >&2; exit 1
                fi
                IFS=',' read -r -a tmp_names <<< "$2"
                for n in "${tmp_names[@]}"; do
                    [[ -n "$n" ]] && names+=("$n")
                done
                shift 2
                ;;
            -o|--out-dir)
                out_dir="${2:-}"; shift 2 ;;
            --days)
                days="${2:-}"; shift 2 ;;
            --password)
                passphrase="${2:-}"; shift 2 ;;
            --test)
                run_tests=true; shift ;;
            --test-hosts)
                if [[ $# -lt 2 ]]; then
                    echo -e "${RED}--test-hosts requires a value${NC}" >&2; exit 1
                fi
                IFS=',' read -r -a tmp_hosts <<< "$2"
                for h in "${tmp_hosts[@]}"; do
                    [[ -n "$h" ]] && user_test_hosts+=("$h")
                done
                shift 2 ;;
            -h|--help)
                print_usage; exit 0 ;;
            --)
                shift; break ;;
            *)
                echo -e "${YELLOW}Ignoring unknown option: $1${NC}" >&2; shift ;;
        esac
    done

    if [[ ${#names[@]} -eq 0 ]]; then
        names=("runai.local")
    fi

    mkdir -p "$out_dir"

    # Choose CN as the first provided DNS name
    local cn="${names[0]}"

    # Prepare passphrase
    if [[ -z "$passphrase" ]]; then
        # Generate a reasonably strong passphrase
        if command -v openssl >/dev/null 2>&1; then
            passphrase="$(openssl rand -base64 32)"
        else
            passphrase="$(date +%s%N | sha256sum | cut -c1-32)"
        fi
        echo -e "${BLUE}Generated CA passphrase (not shown). Save it securely if you need to reuse the CA key.${NC}"
    fi
    export OPENSSL_PASSWORD="$passphrase"

    echo -e "${BLUE}Creating certificates in: ${out_dir}${NC}"

    # Files
    local ca_key="$out_dir/rootCA.key"
    local ca_cert="$out_dir/rootCA.pem"
    local ca_srl="$out_dir/rootCA.srl"
    local svc_key="$out_dir/runai.key"
    local svc_csr="$out_dir/runai.csr"
    local svc_crt="$out_dir/runai.crt"
    local full_chain="$out_dir/full-chain.pem"
    local openssl_cnf="$out_dir/openssl.cnf"

    # Create OpenSSL config for SANs
    write_openssl_cnf "$openssl_cnf" "${names[@]}"

    # Generate Root CA key (encrypted with passphrase)
    echo -e "${BLUE}Generating Root CA key...${NC}"
    openssl genrsa -des3 -passout env:OPENSSL_PASSWORD -out "$ca_key" 2048 >/dev/null 2>&1

    # Generate Root CA certificate
    echo -e "${BLUE}Generating Root CA certificate...${NC}"
    openssl req -x509 -new -key "$ca_key" -passin env:OPENSSL_PASSWORD -sha256 -days "$days" -out "$ca_cert" -subj "/C=US/ST=NA/L=NA/O=Run:AI/CN=Local-RunAI-CA" >/dev/null 2>&1

    # Generate service key
    echo -e "${BLUE}Generating service key...${NC}"
    openssl genrsa -out "$svc_key" 2048 >/dev/null 2>&1

    # Generate CSR
    echo -e "${BLUE}Generating CSR for CN=${cn}...${NC}"
    openssl req -new -key "$svc_key" -out "$svc_csr" -subj "/C=US/ST=NA/L=NA/O=Run:AI/CN=${cn}" >/dev/null 2>&1

    # Sign certificate using Root CA
    echo -e "${BLUE}Signing certificate...${NC}"
    openssl x509 -req -in "$svc_csr" -CA "$ca_cert" -CAkey "$ca_key" -passin env:OPENSSL_PASSWORD -CAcreateserial -CAserial "$ca_srl" -out "$svc_crt" -days "$days" -sha256 -extfile "$openssl_cnf" >/dev/null 2>&1

    # Build full chain
    cat "$svc_crt" "$ca_cert" > "$full_chain"

    # Verify
    echo -e "${BLUE}Verifying certificate...${NC}"
    if openssl verify -CAfile "$ca_cert" "$svc_crt" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Certificate verified successfully${NC}"
    else
        echo -e "${YELLOW}⚠️ Verification failed, but artifacts were created. Check inputs and try again.${NC}"
    fi

    # Hostname verification tests (optional)
    if [[ "$run_tests" == true ]]; then
        echo -e "${BLUE}Running hostname verification tests...${NC}"
        local test_hosts=()
        if [[ ${#user_test_hosts[@]} -gt 0 ]]; then
            test_hosts=("${user_test_hosts[@]}")
        else
            # Derive test hosts from provided SANs. For wildcard entries, test with 'test.<base>'
            for name in "${names[@]}"; do
                if [[ "$name" == \*.* ]]; then
                    local base="${name#*.}"
                    test_hosts+=("test.${base}")
                else
                    test_hosts+=("$name")
                fi
            done
        fi

        local failures=0
        for host in "${test_hosts[@]}"; do
            echo -e "${BLUE} - verifying hostname: ${host}${NC}"
            if openssl verify -CAfile "$ca_cert" -verify_hostname "$host" "$svc_crt" >/dev/null 2>&1; then
                echo -e "${GREEN}   ✓ OK${NC}"
            else
                echo -e "${RED}   ✗ FAILED${NC}"
                failures=$((failures+1))
            fi
        done

        if [[ $failures -gt 0 ]]; then
            echo -e "${RED}❌ Hostname verification failed for ${failures} host(s).${NC}"
            exit 1
        else
            echo -e "${GREEN}✅ All hostname verifications passed.${NC}"
        fi
    fi

    echo
    echo -e "${GREEN}✅ Done. Generated files:${NC}"
    echo "  CA Key           : $ca_key"
    echo "  CA Certificate   : $ca_cert"
    echo "  Service Key      : $svc_key"
    echo "  CSR              : $svc_csr"
    echo "  Service Cert     : $svc_crt"
    echo "  Full Chain (PEM) : $full_chain"
    echo
    echo -e "${BLUE}Subject Alternative Names:${NC} $(join_by_comma "${names[@]}")"
}

main "$@"


