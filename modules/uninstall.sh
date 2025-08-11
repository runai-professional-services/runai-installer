#!/bin/bash

# Run.ai Uninstall Module
# This module handles complete removal of Run.ai from the cluster

uninstall_runai() {
    echo -e "${RED}WARNING: This will delete all Run.ai resources from your cluster.${NC}"
    echo -e "${RED}This action cannot be undone.${NC}"
    echo -e "${YELLOW}Note: Other components (Nginx, Prometheus, GPU Operator, etc.) will NOT be affected.${NC}"

    # First confirmation
    echo -e "${RED}Are you sure you want to proceed? (Y/N)${NC}"
    read -r response
    if [[ "$response" != "Y" ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return 1
    fi

    # Second confirmation
    echo -e "${RED}Are you absolutely sure? This will delete ALL Run.ai resources. (Y/N)${NC}"
    read -r response
    if [[ "$response" != "Y" ]]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return 1
    fi

    echo -e "${BLUE}Starting Run.ai cleanup...${NC}"

    # Clean up runaiconfig first
    echo -e "${BLUE}Cleaning up runaiconfig...${NC}"
    if kubectl patch runaiconfigs.run.ai/runai -n runai -p '{"metadata":{"finalizers":[]}}' --type=merge; then
        echo -e "${GREEN}✅ Successfully removed finalizers from runaiconfig${NC}"
    else
        echo -e "${YELLOW}⚠️ No runaiconfig found or already cleaned up${NC}"
    fi

    if kubectl -n runai delete runaiconfig runai --force; then
        echo -e "${GREEN}✅ Successfully deleted runaiconfig${NC}"
    else
        echo -e "${YELLOW}⚠️ No runaiconfig found or already deleted${NC}"
    fi

    # Function to delete Helm releases
    delete_helm_releases() {
        echo -e "${BLUE}Deleting Helm releases...${NC}"
        
        # Check for runai-backend release
        if helm list -n runai-backend | grep -q "runai-backend"; then
            echo -e "${BLUE}Deleting runai-backend Helm release...${NC}"
            if helm delete runai-backend -n runai-backend; then
                echo -e "${GREEN}✅ Successfully deleted runai-backend Helm release${NC}"
            else
                echo -e "${RED}❌ Failed to delete runai-backend Helm release${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️ No runai-backend Helm release found${NC}"
        fi
        
        # Check for runai release
        if helm list -n runai | grep -q "runai"; then
            echo -e "${BLUE}Deleting runai Helm release...${NC}"
            if helm delete runai-cluster -n runai; then
                echo -e "${GREEN}✅ Successfully deleted runai Helm release${NC}"
            else
                echo -e "${RED}❌ Failed to delete runai Helm release${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️ No runai Helm release found${NC}"
        fi
    }

    # Execute Helm cleanup
    delete_helm_releases

    echo -e "${GREEN}✅ Helm cleanup completed${NC}"
    echo -e "${YELLOW}Would you like to continue with full cleanup? [y/N] ${NC}"
    read -r response

    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Continuing with full cleanup...${NC}"
        # Function to delete resources with timeout and force if needed
        delete_resource() {
            local resource_type=$1
            local namespace=$2
            local timeout=${3:-30s}

            echo -e "${BLUE}Deleting $resource_type in namespace $namespace...${NC}"
            
            # Get all resources of the specified type
            resources=$(kubectl get $resource_type -n $namespace -o name 2>/dev/null)
            if [ -z "$resources" ]; then
                echo -e "${YELLOW}No $resource_type found in namespace $namespace${NC}"
                return 0
            fi

            # First try normal deletion with timeout
            if ! kubectl delete $resource_type -n $namespace --all --timeout=$timeout 2>/dev/null; then
                echo -e "${YELLOW}⚠️ Some $resource_type in $namespace couldn't be deleted normally, trying force deletion...${NC}"
                
                # Get remaining resources
                remaining=$(kubectl get $resource_type -n $namespace -o name 2>/dev/null)
                for resource in $remaining; do
                    echo -e "${YELLOW}Force deleting $resource...${NC}"
                    kubectl patch $resource -n $namespace -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
                    kubectl delete $resource -n $namespace --force --grace-period=0 2>/dev/null
                done
            fi

            echo -e "${GREEN}✅ $resource_type cleanup in $namespace completed${NC}"
        }

        # Function to delete CRDs and their finalizers
        delete_crds() {
            echo -e "${BLUE}Deleting Run.ai CRDs...${NC}"
            
            # Get all Run.ai related CRDs
            crds=$(kubectl get crd -o name | grep -E "run\.ai|runai\.run\.ai" 2>/dev/null)
            if [ -z "$crds" ]; then
                echo -e "${YELLOW}No Run.ai CRDs found${NC}"
                return 0
            fi

            for crd in $crds; do
                echo -e "${BLUE}Processing $crd...${NC}"
                
                # Remove finalizers from all resources of this CRD type
                crd_name=$(echo $crd | cut -d/ -f2)
                if kubectl get $crd_name &>/dev/null; then
                    echo -e "${BLUE}Removing finalizers from $crd_name resources...${NC}"
                    resources=$(kubectl get $crd_name -o name 2>/dev/null)
                    for resource in $resources; do
                        kubectl patch $resource -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
                    done
                fi

                # Delete the CRD
                echo -e "${BLUE}Deleting $crd...${NC}"
                if ! kubectl delete $crd --timeout=30s 2>/dev/null; then
                    echo -e "${YELLOW}⚠️ Forcing deletion of $crd...${NC}"
                    kubectl patch $crd -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
                    kubectl delete $crd --force --grace-period=0 2>/dev/null
                fi
            done

            echo -e "${GREEN}✅ CRD cleanup completed${NC}"
        }

        # Function to force delete namespace using direct API method
        force_delete_namespace() {
            local namespace=$1
            
            echo -e "${BLUE}Force deleting namespace $namespace...${NC}"
            
            if ! kubectl get namespace $namespace &>/dev/null; then
                echo -e "${YELLOW}Namespace $namespace not found${NC}"
                return 0
            fi
            
            # First try normal deletion (non-blocking)
            echo -e "${BLUE}Attempting normal deletion of namespace $namespace...${NC}"
            kubectl delete namespace $namespace --force --grace-period=0 &
            local delete_pid=$!
            
            # Wait up to 10 seconds for normal deletion
            for i in {1..10}; do
                if ! kill -0 $delete_pid 2>/dev/null; then
                    # Process finished, check if namespace is gone
                    if ! kubectl get namespace $namespace &>/dev/null; then
                        echo -e "${GREEN}✅ Namespace $namespace deleted successfully${NC}"
                        return 0
                    fi
                    break
                fi
                sleep 1
            done
            
            # Kill the deletion process if it's still running
            if kill -0 $delete_pid 2>/dev/null; then
                kill $delete_pid 2>/dev/null || true
            fi
            if kubectl get namespace $namespace &>/dev/null; then
                echo -e "${YELLOW}Namespace $namespace is stuck, using direct API cleanup...${NC}"
                
                # Use direct API method to remove finalizers
                kubectl proxy --port=8001 &
                local proxy_pid=$!
                sleep 2
                
                # Create the JSON payload to remove finalizers
                kubectl get namespace $namespace -o json | jq '.spec = {"finalizers":[]}' > temp.json
                
                # Call the API to finalize the namespace
                curl -k -H "Content-Type: application/json" -X PUT --data-binary @temp.json "127.0.0.1:8001/api/v1/namespaces/$namespace/finalize" &>/dev/null
                
                # Cleanup temp file and proxy
                rm -f temp.json
                if [ -n "$proxy_pid" ]; then
                    kill $proxy_pid 2>/dev/null || true
                fi
                
                # Wait for deletion to complete
                for i in {1..30}; do
                    if ! kubectl get namespace $namespace &>/dev/null; then
                        echo -e "${GREEN}✅ Namespace $namespace deleted successfully via API cleanup${NC}"
                        return 0
                    fi
                    sleep 1
                done
                
                echo -e "${RED}❌ Failed to delete namespace $namespace even with API cleanup${NC}"
                return 1
            else
                echo -e "${GREEN}✅ Namespace $namespace deleted successfully${NC}"
                return 0
            fi
        }

        # Main cleanup process
        echo -e "${BLUE}Starting cleanup in runai namespace...${NC}"
        for resource in pods secrets jobs statefulsets persistentvolumeclaims deployments replicasets services; do
            delete_resource $resource runai
        done

        echo -e "${BLUE}Starting cleanup in runai-backend namespace...${NC}"
        for resource in pods secrets jobs statefulsets persistentvolumeclaims deployments replicasets services; do
            delete_resource $resource runai-backend
        done

        # Delete CRDs and their finalizers
        delete_crds

        # Force delete namespaces
        echo -e "${BLUE}Cleaning up namespaces...${NC}"
        force_delete_namespace runai
        force_delete_namespace runai-backend
        force_delete_namespace runai-cluster

        echo -e "${GREEN}✅ Run.ai cleanup completed!${NC}"
    else
        echo -e "${BLUE}Cleanup stopped after Helm deletions${NC}"
        return 0
    fi
} 