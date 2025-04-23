#!/bin/bash

# Function to patch CoreDNS
patch_coredns() {
    echo -e "${BLUE}Patching CoreDNS to add $DNS_NAME -> $IP_ADDRESS${NC}"

    # First check if the DNS entry already exists
    if ! log_command "kubectl get cm coredns -n kube-system -o yaml" "Check CoreDNS ConfigMap"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to get CoreDNS ConfigMap${NC}"
        return 1
    fi

    # Get current Corefile
    CURRENT_COREFILE=$(kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}')

    # Check if our DNS entry already exists
    if echo "$CURRENT_COREFILE" | grep -q "$DNS_NAME"; then
        echo -e "${BLUE}DNS entry for $DNS_NAME already exists, updating IP address${NC}"
        # Replace the IP address for the existing entry
        NEW_COREFILE=$(echo "$CURRENT_COREFILE" | sed -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ $DNS_NAME/$IP_ADDRESS $DNS_NAME/g")

        # Create a temporary file with the new Corefile
        TEMP_COREFILE="${TEMP_DIR}/corefile.tmp"
        echo "$NEW_COREFILE" > "$TEMP_COREFILE"

        echo -e "${BLUE}New CoreDNS configuration:${NC}"
        if ! log_command "cat \"$TEMP_COREFILE\"" "New CoreDNS configuration"; then
            echo -e "${YELLOW}⚠️ Warning: Could not log new CoreDNS configuration${NC}"
        fi

        # Apply the updated ConfigMap
        if ! log_command "kubectl create configmap coredns -n kube-system --from-file=Corefile=\"$TEMP_COREFILE\" --dry-run=client -o yaml | kubectl apply -f -" "Update CoreDNS ConfigMap"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to update CoreDNS ConfigMap${NC}"
            return 1
        fi
    else
        echo -e "${BLUE}No DNS entry found, applying complete Corefile patch${NC}"

        # Apply the patch with the new DNS entry
        PATCH_DATA="
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf {
          prefer_udp
          max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
        hosts {
          $IP_ADDRESS $DNS_NAME
          fallthrough
        }
    }
"

        # Log the patch data
        echo -e "${BLUE}Applying CoreDNS patch:${NC}"
        echo "$PATCH_DATA" > "${TEMP_DIR}/coredns-patch.yaml"
        if ! log_command "cat \"${TEMP_DIR}/coredns-patch.yaml\"" "CoreDNS patch data"; then
            echo -e "${YELLOW}⚠️ Warning: Could not log CoreDNS patch data${NC}"
        fi

        # Apply the patch
        if ! log_command "kubectl patch cm coredns -n kube-system --type='merge' --patch=\"$PATCH_DATA\"" "Patch CoreDNS ConfigMap"; then
            echo -e "${YELLOW}⚠️ Warning: Failed to patch CoreDNS ConfigMap${NC}"
            return 1
        fi
    fi

    # Restart CoreDNS to apply the changes
    echo -e "${BLUE}Restarting CoreDNS...${NC}"
    if ! log_command "kubectl -n kube-system delete pod -l k8s-app=kube-dns" "Restart CoreDNS pods"; then
        echo -e "${YELLOW}⚠️ Warning: Failed to restart CoreDNS pods, continuing...${NC}"
        return 1
    fi

    # Wait for CoreDNS pods to be ready
    echo -e "${BLUE}Waiting for CoreDNS pods to be ready...${NC}"
    if ! log_command "kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=60s" "Wait for CoreDNS pods"; then
        echo -e "${YELLOW}⚠️ Warning: Timeout waiting for CoreDNS pods to be ready, continuing...${NC}"
    fi

    # Verify DNS resolution
    echo -e "${BLUE}Verifying DNS resolution...${NC}"

    # Create a temporary file to store nslookup output
    NSLOOKUP_OUTPUT="${TEMP_DIR}/nslookup_output.txt"

    echo "Running DNS test for $DNS_NAME..." >> "$LOG_FILE"

    # Run the test pod with nslookup and capture output
    kubectl run dns-test --rm -i --restart=Never --image=busybox -- nslookup $DNS_NAME > "$NSLOOKUP_OUTPUT" 2>&1

    # Log the complete nslookup output
    echo "DNS test output:" >> "$LOG_FILE"
    cat "$NSLOOKUP_OUTPUT" >> "$LOG_FILE"

    # Check if nslookup output contains any error messages
    if grep -q "can't resolve" "$NSLOOKUP_OUTPUT"; then
        echo -e "${RED}❌ DNS resolution failed - domain cannot be resolved${NC}"
        echo "DNS resolution failed - domain cannot be resolved" >> "$LOG_FILE"
        cat "$NSLOOKUP_OUTPUT"
    else
        # DNS resolution completed, check if we got an answer
        if grep -q "Address:" "$NSLOOKUP_OUTPUT"; then
            echo -e "${GREEN}✅ DNS resolution test successful${NC}"
            echo "DNS resolution test successful" >> "$LOG_FILE"

            # Log the resolved IP address
            RESOLVED_IP=$(grep "Address:" "$NSLOOKUP_OUTPUT" | tail -n1 | awk '{print $2}')
            echo "Resolved IP: $RESOLVED_IP" >> "$LOG_FILE"

            if [ -n "$IP_ADDRESS" ] && [ "$RESOLVED_IP" != "$IP_ADDRESS" ]; then
                echo "Warning: Resolved IP ($RESOLVED_IP) does not match configured IP ($IP_ADDRESS)" >> "$LOG_FILE"
            fi
        else
            echo -e "${YELLOW}⚠️ Warning: Unexpected nslookup output format${NC}"
            echo "Warning: Unexpected nslookup output format" >> "$LOG_FILE"
            cat "$NSLOOKUP_OUTPUT" >> "$LOG_FILE"
        fi
    fi

    # Cleanup temporary file
    rm -f "$NSLOOKUP_OUTPUT"

    echo -e "${GREEN}✅ CoreDNS updated with $DNS_NAME -> $IP_ADDRESS${NC}"
    echo "CoreDNS update completed for $DNS_NAME -> $IP_ADDRESS" >> "$LOG_FILE"
    return 0
}

# Function to update local /etc/hosts file
update_local_hosts() {
    echo -e "${BLUE}Updating local /etc/hosts file with $IP_ADDRESS $DNS_NAME...${NC}"

    # Check if we have sudo access
    if ! sudo -n true 2>/dev/null; then
        echo -e "${YELLOW}⚠️ Sudo access required to update /etc/hosts file${NC}"
        echo -e "${YELLOW}Please enter your password when prompted${NC}"
    fi

    # Check if the entry already exists
    if grep -q "$DNS_NAME" /etc/hosts; then
        # Update the existing entry
        if ! grep -q "$IP_ADDRESS $DNS_NAME" /etc/hosts; then
            echo -e "${BLUE}Updating existing entry in /etc/hosts...${NC}"
            sudo sed -i.bak "s/.*$DNS_NAME/$IP_ADDRESS $DNS_NAME/" /etc/hosts
        else
            echo -e "${GREEN}✅ /etc/hosts already contains the correct entry${NC}"
            return 0
        fi
    else
        # Add a new entry
        echo -e "${BLUE}Adding new entry to /etc/hosts...${NC}"
        echo "$IP_ADDRESS $DNS_NAME" | sudo tee -a /etc/hosts > /dev/null
    fi

    # Verify the entry was added
    if grep -q "$IP_ADDRESS $DNS_NAME" /etc/hosts; then
        echo -e "${GREEN}✅ Successfully updated /etc/hosts with $IP_ADDRESS $DNS_NAME${NC}"
    else
        echo -e "${YELLOW}⚠️ Failed to update /etc/hosts. Please manually add the following line:${NC}"
        echo -e "${YELLOW}$IP_ADDRESS $DNS_NAME${NC}"
    fi
} 