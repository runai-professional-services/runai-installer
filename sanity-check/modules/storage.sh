#!/bin/bash

# Storage Module for Sanity Check
# This module handles storage testing functionality

# Function to run storage tests
run_storage_tests() {
    local TESTS_FAILED=false

    # Get storage class
    if [ -n "$STORAGE_CLASS" ]; then
        if ! kubectl get storageclass "$STORAGE_CLASS" &>/dev/null; then
            echo -e "❌ Storage test failed"
            return 1
        fi
        SC_TO_USE="$STORAGE_CLASS"
    else
        SC_TO_USE=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
        if [ -z "$SC_TO_USE" ]; then
            echo -e "❌ Storage test failed"
            return 1
        fi
    fi

    # Create PVC first
    cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sanity-pvc
  namespace: $TEST_NS
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: $SC_TO_USE
EOF

    # Create pod to test storage
    cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
  namespace: $TEST_NS
spec:
  securityContext:
    fsGroup: 1001
  containers:
  - name: storage-test
    image: ubuntu:latest
    command: 
    - sleep
    - "3600"
    securityContext:
      runAsUser: 1001
      runAsGroup: 1001
    volumeMounts:
    - name: storage-volume
      mountPath: /data
  volumes:
  - name: storage-volume
    persistentVolumeClaim:
      claimName: sanity-pvc
EOF

    # Wait for PVC to be bound
    for i in {1..30}; do
        if kubectl get pvc -n "$TEST_NS" sanity-pvc &>/dev/null; then
            break
        fi
        sleep 2
    done
    PVC_STATUS=$(kubectl get pvc -n "$TEST_NS" sanity-pvc -o jsonpath='{.status.phase}')
    if [ "$PVC_STATUS" = "Bound" ]; then
        echo -e "✅ PVC successfully bound"
    else
        sleep 10
        PVC_STATUS=$(kubectl get pvc -n "$TEST_NS" sanity-pvc -o jsonpath='{.status.phase}')
        if [ "$PVC_STATUS" = "Bound" ]; then
            echo -e "✅ PVC successfully bound"
        else
            echo -e "❌ Storage test failed"
            return 1
        fi
    fi

    # Wait for storage test pod
    if ! kubectl wait --for=condition=ready pod/storage-test -n $TEST_NS --timeout=60s > /dev/null 2>&1; then
        echo -e "❌ Storage test failed"
        return 1
    fi

    # Test file operations
    if ! kubectl exec -n $TEST_NS storage-test -- /bin/bash -c 'echo "Test content" > /data/test.txt' > /dev/null 2>&1; then
        echo -e "❌ Storage test failed"
        return 1
    fi

    # Verify permissions
    FILE_OWNER=$(kubectl exec -n $TEST_NS storage-test -- ls -ln /data/test.txt | awk '{print $3":"$4}')
    if [ "$FILE_OWNER" = "1001:1001" ]; then
        echo -e "✅ File ownership verified: 1001:1001"
    else
        echo -e "❌ Storage test failed"
        return 1
    fi

    # Test 1: Create file as user 1001:1001 (already implemented)
    echo -e "✅ Test 1 completed (file created with correct ownership)"

    # Test 2: Create file as root and change ownership
    # Create root pod
    cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: root-test
  namespace: $TEST_NS
spec:
  containers:
  - name: root-test
    image: ubuntu:latest
    command: 
    - sleep
    - "3600"
    securityContext:
      runAsUser: 0
      runAsGroup: 0
    volumeMounts:
    - name: storage-volume
      mountPath: /data
  volumes:
  - name: storage-volume
    persistentVolumeClaim:
      claimName: sanity-pvc
EOF

    # Wait for root pod to be ready
    if ! kubectl wait --for=condition=ready pod/root-test -n $TEST_NS --timeout=60s > /dev/null 2>&1; then
        echo -e "❌ Storage test failed"
        return 1
    fi

    # Create file as root
    if ! kubectl exec -n $TEST_NS root-test -- touch /data/root_test.txt > /dev/null 2>&1; then
        echo -e "❌ Storage test failed"
        return 1
    fi

    # Verify initial ownership (should be 0:0)
    ROOT_FILE_OWNER=$(kubectl exec -n $TEST_NS root-test -- ls -ln /data/root_test.txt | awk '{print $3":"$4}')
    if [ "$ROOT_FILE_OWNER" = "0:0" ]; then
        echo -e "✅ Initial file ownership verified: 0:0"
    else
        echo -e "❌ Storage test failed"
        return 1
    fi

    # Change ownership to 1001:1001
    if ! kubectl exec -n $TEST_NS root-test -- chown 1001:1001 /data/root_test.txt > /dev/null 2>&1; then
        echo -e "❌ Storage test failed"
        return 1
    fi

    # Verify new ownership
    NEW_OWNER=$(kubectl exec -n $TEST_NS root-test -- ls -ln /data/root_test.txt | awk '{print $3":"$4}')
    if [ "$NEW_OWNER" = "1001:1001" ]; then
        echo -e "✅ File ownership successfully changed to: 1001:1001"
    else
        echo -e "❌ Storage test failed"
        return 1
    fi

    echo -e "✅ Storage test completed"
    return 0
} 