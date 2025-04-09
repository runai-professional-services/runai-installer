#!/bin/bash

# Set text colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to show usage
show_usage() {
    echo -e "${YELLOW}Usage: $0 [OPTIONS]${NC}"
    echo "Options:"
    echo "  -h, --help    Show this help message"
    exit 1
}

# Function to delete resources in a namespace
delete_resources() {
    local namespace=$1
    local resource_type=$2
    
    echo -e "${YELLOW}Deleting $resource_type in namespace $namespace...${NC}"
    if kubectl get $resource_type -n $namespace --no-headers 2>/dev/null | grep -q .; then
        kubectl delete $resource_type --all -n $namespace
        echo -e "${GREEN}✅ Deleted all $resource_type in $namespace${NC}"
    else
        echo -e "${YELLOW}No $resource_type found in $namespace${NC}"
    fi
}

# Function to delete Helm releases
delete_helm_releases() {
    echo -e "${YELLOW}Deleting Helm releases...${NC}"
    
    # Delete runai-backend release if it exists
    if helm list -n runai-backend | grep -q "runai-backend"; then
        helm delete runai-backend -n runai-backend
        echo -e "${GREEN}✅ Deleted runai-backend Helm release${NC}"
    else
        echo -e "${YELLOW}No runai-backend Helm release found${NC}"
    fi
    
    # Delete runai release if it exists
    if helm list -n runai | grep -q "runai"; then
        helm delete runai -n runai
        echo -e "${GREEN}✅ Deleted runai Helm release${NC}"
    else
        echo -e "${YELLOW}No runai Helm release found${NC}"
    fi
}

# Function to force delete namespace
force_delete_namespace() {
    local namespace=$1
    
    echo -e "${YELLOW}Force deleting namespace $namespace...${NC}"
    if kubectl get namespace $namespace &>/dev/null; then
        kubectl delete namespace $namespace --force --grace-period=0
        echo -e "${GREEN}✅ Force deleted namespace $namespace${NC}"
    else
        echo -e "${YELLOW}Namespace $namespace not found${NC}"
    fi
}

# Initial warning and confirmation
echo -e "${RED}WARNING: This script will delete all Run.ai resources from your cluster.${NC}"
echo -e "${RED}This action cannot be undone.${NC}"

# First confirmation
echo -e "${RED}Are you sure you want to proceed? (yes/no)${NC}"
read -r response
if [[ "$response" != "yes" ]]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    exit 1
fi

# Second confirmation
echo -e "${RED}Are you absolutely sure? This will delete ALL Run.ai resources. (yes/no)${NC}"
read -r response
if [[ "$response" != "yes" ]]; then
    echo -e "${YELLOW}Operation cancelled.${NC}"
    exit 1
fi

# Main cleanup process
echo -e "${RED}WARNING: This script will delete all Run.ai resources from your cluster.${NC}"
echo -e "${RED}This action cannot be undone.${NC}"
echo -e "${RED}Press ENTER to continue or Ctrl+C to abort...${NC}"
read

echo -e "${RED}WARNING: This will delete all Run.ai deployments, services, and configurations.${NC}"
echo -e "${RED}Make sure you have backed up any important data.${NC}"
echo -e "${RED}Press ENTER to continue or Ctrl+C to abort...${NC}"
read

echo -e "${RED}WARNING: This will force delete the runai and runai-backend namespaces.${NC}"
echo -e "${RED}All resources in these namespaces will be permanently removed.${NC}"
echo -e "${RED}Press ENTER to continue or Ctrl+C to abort...${NC}"
read

# Delete Helm releases first
delete_helm_releases

# Delete resources in runai-backend namespace
echo -e "${YELLOW}Cleaning up runai-backend namespace...${NC}"
delete_resources "runai-backend" "deployments"
delete_resources "runai-backend" "services"
delete_resources "runai-backend" "replicasets"
delete_resources "runai-backend" "pods"
delete_resources "runai-backend" "configmaps"
delete_resources "runai-backend" "secrets"
delete_resources "runai-backend" "persistentvolumeclaims"

# Delete resources in runai namespace
echo -e "${YELLOW}Cleaning up runai namespace...${NC}"
delete_resources "runai" "deployments"
delete_resources "runai" "services"
delete_resources "runai" "replicasets"
delete_resources "runai" "pods"
delete_resources "runai" "configmaps"
delete_resources "runai" "secrets"
delete_resources "runai" "persistentvolumeclaims"

# Delete CRDs
echo -e "${YELLOW}Deleting Run.ai CRDs...${NC}"
kubectl delete crd $(kubectl get crd | grep runai | awk '{print $1}')

# Force delete namespaces
force_delete_namespace "runai"
force_delete_namespace "runai-backend"

echo -e "${GREEN}✅ Cleanup completed successfully${NC}" 