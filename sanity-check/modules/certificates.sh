#!/bin/bash

# Certificates Module for Sanity Check
# This module handles TLS certificate validation functionality

# Function to validate TLS certificates using OpenSSL
validate_certificates() {
    local cert_file="$1"
    local key_file="$2"
    local ca_file="$3"
    local dns="$4"
    
    echo -e "${BLUE}🔐 Validating certificates with OpenSSL for DNS: $dns${NC}"
    
    # Check if files exist
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ] || [ ! -f "$ca_file" ]; then
        echo -e "${RED}❌ One or more certificate files not found${NC}"
        return 1
    fi
    
    # Test 1: Verify certificate format
    echo -e "${BLUE}📋 Testing certificate format...${NC}"
    if openssl x509 -in "$cert_file" -text -noout >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Certificate format is valid${NC}"
    else
        echo -e "${RED}❌ Invalid certificate format${NC}"
        return 1
    fi
    
    # Test 2: Verify private key format
    echo -e "${BLUE}🔑 Testing private key format...${NC}"
    if openssl rsa -in "$key_file" -check -noout >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Private key format is valid${NC}"
    else
        echo -e "${RED}❌ Invalid private key format${NC}"
        return 1
    fi
    
    # Test 3: Verify CA certificate format
    echo -e "${BLUE}🏛️  Testing CA certificate format...${NC}"
    if openssl x509 -in "$ca_file" -text -noout >/dev/null 2>&1; then
        echo -e "${GREEN}✅ CA certificate format is valid${NC}"
    else
        echo -e "${RED}❌ Invalid CA certificate format${NC}"
        return 1
    fi
    
    # Test 4: Verify certificate matches private key
    echo -e "${BLUE}🔗 Testing certificate and key match...${NC}"
    local cert_md5=$(openssl x509 -noout -modulus -in "$cert_file" | openssl md5)
    local key_md5=$(openssl rsa -noout -modulus -in "$key_file" | openssl md5)
    
    if [ "$cert_md5" = "$key_md5" ]; then
        echo -e "${GREEN}✅ Certificate and private key match${NC}"
    else
        echo -e "${RED}❌ Certificate and private key do not match${NC}"
        return 1
    fi
    
    # Test 5: Verify certificate against CA
    echo -e "${BLUE}🔍 Verifying certificate against CA...${NC}"
    if openssl verify -CAfile "$ca_file" "$cert_file" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Certificate verified against CA${NC}"
    else
        echo -e "${RED}❌ Certificate verification against CA failed${NC}"
        return 1
    fi
    
    # Test 6: Check certificate expiration
    echo -e "${BLUE}⏰ Checking certificate expiration...${NC}"
    local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
    local current_date=$(date)
    
    if openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Certificate is not expired (expires: $expiry_date)${NC}"
    else
        echo -e "${RED}❌ Certificate has expired (expired: $expiry_date)${NC}"
        return 1
    fi
    
    # Test 7: Check DNS names in certificate
    echo -e "${BLUE}🌐 Checking DNS names in certificate...${NC}"
    local dns_names=$(openssl x509 -in "$cert_file" -noout -text | grep -A1 "DNS:" | tail -1 | sed 's/^[[:space:]]*//')
    echo -e "${BLUE}   Certificate DNS names: $dns_names${NC}"
    
    if echo "$dns_names" | grep -q "$dns"; then
        echo -e "${GREEN}✅ DNS '$dns' found in certificate${NC}"
    else
        echo -e "${YELLOW}⚠️  DNS '$dns' not found in certificate DNS names${NC}"
    fi
    
    # Test 8: Test HTTPS connectivity with OpenSSL s_client
    echo -e "${BLUE}🌐 Testing HTTPS connectivity with OpenSSL...${NC}"
    local https_test=$(echo "Q" | timeout 10 openssl s_client -connect "$dns:443" -CAfile "$ca_file" -cert "$cert_file" -key "$key_file" -servername "$dns" 2>/dev/null | grep -E "(Verify return code|subject=|issuer=)" | head -3)
    
    if echo "$https_test" | grep -q "Verify return code: 0"; then
        echo -e "${GREEN}✅ HTTPS connectivity test successful${NC}"
        echo -e "${BLUE}   Connection details:${NC}"
        echo "$https_test" | while read -r line; do
            echo -e "${BLUE}   $line${NC}"
        done
    else
        echo -e "${YELLOW}⚠️  HTTPS connectivity test failed (this is normal if Run.ai is not yet installed)${NC}"
    fi
    
    echo -e "\n${GREEN}✅ All certificate validation tests passed!${NC}"
    return 0
} 