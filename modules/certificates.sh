#!/bin/bash

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
        # Generate self-signed certificates
        echo -e "${BLUE}Creating certificates in: $CERT_DIR${NC}"
        mkdir -p "$CERT_DIR"
        cd "$CERT_DIR"

        # Set the password environment variable
        export OPENSSL_PASSWORD='kirson'

        echo -e "${BLUE}Generating certificates...${NC}"
        # Generate the root key with the provided passphrase
        if ! openssl genrsa -des3 -passout env:OPENSSL_PASSWORD -out rootCA.key 2048; then
            echo -e "${RED}❌ Failed to generate root key${NC}"
            exit 1
        fi

        # Generate root certificate
        if ! openssl req -x509 -new -nodes -key rootCA.key -passin env:OPENSSL_PASSWORD -sha256 -days 730 \
            -out rootCA.pem -subj "/C=US/ST=IL/L=TLV/O=Jupyter/CN=self-signed-nvidia"; then
            echo -e "${RED}❌ Failed to generate root certificate${NC}"
            exit 1
        fi

        # Generate a private key for your service
        if ! openssl genrsa -out runai.key 2048; then
            echo -e "${RED}❌ Failed to generate service key${NC}"
            exit 1
        fi

        # Generate a CSR for your service
        if ! openssl req -new -key runai.key -out runai.csr \
            -subj "/C=US/ST=IL/L=TLV/O=RUNAI/CN=$DNS_NAME"; then
            echo -e "${RED}❌ Failed to generate CSR${NC}"
            exit 1
        fi

        # Create the configuration file for the extensions
        cat << EOF > openssl.cnf
basicConstraints = CA:FALSE
authorityKeyIdentifier = keyid,issuer
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DNS_NAME
DNS.2 = *.runai.$DNS_NAME
DNS.3 = *.${DNS_NAME#*.}
EOF

        # Create the certificate
        if ! openssl x509 -req -in runai.csr -CA rootCA.pem -CAkey rootCA.key \
            -passin env:OPENSSL_PASSWORD -CAcreateserial -out runai.crt -days 730 \
            -sha256 -extfile openssl.cnf; then
            echo -e "${RED}❌ Failed to create certificate${NC}"
            exit 1
        fi

        # Combine the certificates into a chain
        cat runai.crt rootCA.pem > full-chain.pem

        # Verify the certificate
        if ! openssl verify -CAfile rootCA.pem runai.crt; then
            echo -e "${YELLOW}⚠️ Warning: Certificate verification failed, but continuing...${NC}"
        else
            echo -e "${GREEN}✅ Certificate verified successfully${NC}"
        fi

        # After successful generation, copy to backup directory
        mkdir -p "$CERTS_BACKUP_DIR"
        cp runai.crt "$CERTS_BACKUP_DIR/"
        cp runai.key "$CERTS_BACKUP_DIR/"
        cp full-chain.pem "$CERTS_BACKUP_DIR/"

        # Set certificate paths
        export CERT="$CERT_DIR/runai.crt"
        export KEY="$CERT_DIR/runai.key"
        export FULL="$CERT_DIR/full-chain.pem"

        cd "$CURRENT_DIR"
    fi

    # Create TLS secrets in Kubernetes
    echo -e "${BLUE}Creating TLS secrets in Kubernetes...${NC}"
    
    # Delete existing secrets first
    kubectl -n runai-backend delete secret runai-backend-tls 2>/dev/null || true
    kubectl -n runai-backend delete secret runai-ca-cert 2>/dev/null || true
    kubectl -n runai delete secret runai-ca-cert 2>/dev/null || true

    # Create new secrets
    if ! log_command "kubectl create secret tls runai-backend-tls -n runai-backend --cert=$CERT --key=$KEY" "Create TLS secret"; then
        echo -e "${RED}❌ Failed to create TLS secret${NC}"
        exit 1
    fi

    if ! log_command "kubectl create secret generic runai-ca-cert -n runai-backend --from-file=runai-ca.pem=$FULL" "Create CA cert secret in runai-backend namespace"; then
        echo -e "${RED}❌ Failed to create CA cert secret in runai-backend namespace${NC}"
        exit 1
    fi

    if ! log_command "kubectl create secret generic runai-ca-cert -n runai --from-file=runai-ca.pem=$FULL" "Create CA cert secret in runai namespace"; then
        echo -e "${RED}❌ Failed to create CA cert secret in runai namespace${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ Certificate setup completed successfully${NC}"
} 