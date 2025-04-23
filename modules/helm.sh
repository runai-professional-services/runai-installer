#!/bin/bash

# Function to check Helm version
check_helm_version() {
    echo -e "${BLUE}Checking Helm version...${NC}"

    # Check if Helm is installed
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}❌ Helm is not installed. Please install Helm first.${NC}"
        exit 1
    fi

    # Get Helm version
    HELM_VERSION=$(helm version --short | cut -d'v' -f2 | cut -d'.' -f1,2)
    REQUIRED_VERSION="3.14"

    # Compare versions
    if [ $(echo "$HELM_VERSION < $REQUIRED_VERSION" | bc -l) -eq 1 ]; then
        echo -e "${RED}❌ Helm version $HELM_VERSION is too old. Required version is at least $REQUIRED_VERSION${NC}"
        echo -e "${YELLOW}Please upgrade Helm using: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ Helm version $HELM_VERSION meets the minimum requirement of $REQUIRED_VERSION${NC}"
    fi
} 