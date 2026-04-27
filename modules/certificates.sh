#!/bin/bash

# Build SAN list and generate certs via the dedicated script in repo root.
generate_with_create_cert_script() {
    local cert_dir="$1"
    local cert_tool="./create-cert.sh"
    local dns_csv=""

    if [ -z "${DNS_NAME:-}" ]; then
        echo -e "${RED}❌ DNS_NAME is empty; cannot generate certificates${NC}" >&2
        return 1
    fi

    if [ ! -x "$cert_tool" ]; then
        # Fallback when executable bit is missing.
        if [ ! -f "$cert_tool" ]; then
            echo -e "${RED}❌ Missing $cert_tool${NC}" >&2
            return 1
        fi
    fi

    # Keep existing SAN behavior from this module.
    dns_csv="${DNS_NAME},*.runai.${DNS_NAME},*.${DNS_NAME}"
    echo -e "${BLUE}Generating certificates via create-cert.sh...${NC}"
    if ! log_command "bash \"$cert_tool\" --dns \"$dns_csv\" --out-dir \"$cert_dir\"" "Generate certificates with create-cert.sh"; then
        echo -e "${RED}❌ create-cert.sh failed (check log for openssl output)${NC}" >&2
        return 1
    fi

    if [ ! -f "$cert_dir/runai.crt" ] || [ ! -f "$cert_dir/runai.key" ] || [ ! -f "$cert_dir/full-chain.pem" ]; then
        echo -e "${RED}❌ create-cert.sh completed but expected files are missing in $cert_dir${NC}" >&2
        return 1
    fi

    return 0
}

backup_generated_certs() {
    local cert_dir="$1"
    local backup_dir="$2"
    mkdir -p "$backup_dir"
    cp "$cert_dir/runai.crt" "$backup_dir/"
    cp "$cert_dir/runai.key" "$backup_dir/"
    cp "$cert_dir/full-chain.pem" "$backup_dir/"
}

# Function to setup certificates
setup_certificates() {
    # If --no-cert is set, skip certificate setup
    if [ "$NO_CERT" = true ]; then
        echo -e "${YELLOW}⚠️ Certificate setup skipped (--no-cert flag set)${NC}"
        echo -e "${YELLOW}⚠️ Make sure you have valid certificates in the runai and runai-backend namespaces${NC}"
        return 0
    fi

    # Create certificates directory with timestamp
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CERT_DIR="./certificates"
    CERTS_BACKUP_DIR="$CERT_DIR/certs-$TIMESTAMP"
    CURRENT_DIR="$(pwd)"

    # Check if user provided certificates
    if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
        echo -e "${BLUE}Using provided certificate and key files...${NC}"

        # Create backup directory
        mkdir -p "$CERTS_BACKUP_DIR"

        # Set certificate paths to the original files
        export CERT="$CERT_FILE"
        export KEY="$KEY_FILE"
        
        # Use provided CA cert if available, otherwise use the certificate as the full chain
        if [ -n "$CA_CERT_FILE" ]; then
            echo -e "${BLUE}Using provided CA certificate...${NC}"
            export FULL="$CA_CERT_FILE"
        else
            export FULL="$CERT_FILE"  # Use the provided certificate as the full chain
        fi

        # Backup the certificates (don't create secrets here)
        echo -e "${BLUE}Backing up certificates to $CERTS_BACKUP_DIR...${NC}"
        cp "$CERT_FILE" "$CERTS_BACKUP_DIR/runai.crt"
        cp "$KEY_FILE" "$CERTS_BACKUP_DIR/runai.key"
        if [ -n "$CA_CERT_FILE" ]; then
            cp "$CA_CERT_FILE" "$CERTS_BACKUP_DIR/rootCA.pem"
        else
            cp "$CERT_FILE" "$CERTS_BACKUP_DIR/full-chain.pem"
        fi

        echo -e "${GREEN}✅ Using provided certificates and backed up to $CERTS_BACKUP_DIR${NC}"
    else
        # Generate self-signed certificates using the shared script.
        echo -e "${BLUE}Creating certificates in: $CERT_DIR${NC}"
        mkdir -p "$CERT_DIR"
        if ! generate_with_create_cert_script "$CERT_DIR"; then
            exit 1
        fi

        backup_generated_certs "$CERT_DIR" "$CERTS_BACKUP_DIR"

        # Set certificate paths
        export CERT="$CERT_DIR/runai.crt"
        export KEY="$CERT_DIR/runai.key"
        export FULL="$CERT_DIR/full-chain.pem"

        cd "$CURRENT_DIR"
    fi

    # Create/update TLS secrets in Kubernetes
    echo -e "${BLUE}Creating/updating TLS secrets in Kubernetes...${NC}"

    # Apply TLS secrets (idempotent - creates if not exists, updates if exists)
    if ! log_command "kubectl create secret tls runai-backend-tls -n runai-backend --cert=$CERT --key=$KEY --dry-run=client -o yaml | kubectl apply -f -" "Apply TLS secret"; then
        echo -e "${RED}❌ Failed to apply TLS secret${NC}"
        exit 1
    fi

    if ! log_command "kubectl create secret generic runai-ca-cert -n runai-backend --from-file=runai-ca.pem=$FULL --dry-run=client -o yaml | kubectl apply -f -" "Apply CA cert secret in runai-backend namespace"; then
        echo -e "${RED}❌ Failed to apply CA cert secret in runai-backend namespace${NC}"
        exit 1
    fi

    if ! log_command "kubectl create secret generic runai-ca-cert -n runai --from-file=runai-ca.pem=$FULL --dry-run=client -o yaml | kubectl apply -f -" "Apply CA cert secret in runai namespace"; then
        echo -e "${RED}❌ Failed to apply CA cert secret in runai namespace${NC}"
        exit 1
    fi

    if ! log_command "kubectl create secret tls runai-cluster-domain-star-tls-secret -n runai --cert=$CERT --key=$KEY --dry-run=client -o yaml | kubectl apply -f -" "Apply cluster domain star TLS secret in runai namespace"; then
        echo -e "${RED}❌ Failed to apply cluster domain star TLS secret in runai namespace${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ Certificate setup completed successfully${NC}"
}

# Function to generate certificates only (without creating Kubernetes secrets)
generate_certificates_only() {
    # If --no-cert is set, skip certificate setup
    if [ "$NO_CERT" = true ]; then
        echo -e "${YELLOW}⚠️ Certificate setup skipped (--no-cert flag set)${NC}"
        return 0
    fi

    # Create certificates directory with timestamp
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CERT_DIR="./certificates"
    CERTS_BACKUP_DIR="$CERT_DIR/certs-$TIMESTAMP"
    CURRENT_DIR="$(pwd)"

    # Check if user provided certificates
    if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
        echo -e "${BLUE}Using provided certificate and key files...${NC}"

        # Create backup directory
        mkdir -p "$CERTS_BACKUP_DIR"

        # Set certificate paths to the original files
        export CERT="$CERT_FILE"
        export KEY="$KEY_FILE"
        
        # Use provided CA cert if available, otherwise use the certificate as the full chain
        if [ -n "$CA_CERT_FILE" ]; then
            echo -e "${BLUE}Using provided CA certificate...${NC}"
            export FULL="$CA_CERT_FILE"
        else
            export FULL="$CERT_FILE"  # Use the provided certificate as the full chain
        fi

        # Backup the certificates (don't create secrets here)
        echo -e "${BLUE}Backing up certificates to $CERTS_BACKUP_DIR...${NC}"
        cp "$CERT_FILE" "$CERTS_BACKUP_DIR/runai.crt"
        cp "$KEY_FILE" "$CERTS_BACKUP_DIR/runai.key"
        if [ -n "$CA_CERT_FILE" ]; then
            cp "$CA_CERT_FILE" "$CERTS_BACKUP_DIR/rootCA.pem"
        else
            cp "$CERT_FILE" "$CERTS_BACKUP_DIR/full-chain.pem"
        fi

        echo -e "${GREEN}✅ Using provided certificates and backed up to $CERTS_BACKUP_DIR${NC}"
    else
        # Generate self-signed certificates using the shared script.
        echo -e "${BLUE}Creating certificates in: $CERT_DIR${NC}"
        mkdir -p "$CERT_DIR"
        if ! generate_with_create_cert_script "$CERT_DIR"; then
            exit 1
        fi

        backup_generated_certs "$CERT_DIR" "$CERTS_BACKUP_DIR"

        # Set certificate paths
        export CERT="$CERT_DIR/runai.crt"
        export KEY="$CERT_DIR/runai.key"
        export FULL="$CERT_DIR/full-chain.pem"

        cd "$CURRENT_DIR"
    fi

    echo -e "${GREEN}✅ Certificate generation completed successfully${NC}"
}
