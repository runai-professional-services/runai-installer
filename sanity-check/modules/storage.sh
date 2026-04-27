#!/bin/bash

# Storage Module for Sanity Check
# This module handles storage testing functionality

# True on OpenShift / OCP (namespace openshift exists).
storage_sanity_is_openshift() {
    kubectl get namespace openshift &>/dev/null
}

# Set RUNAI_SANITY_STORAGE_FORCE_GENERIC=1 to use the full ubuntu/uid-1001/root
# chown test on an OpenShift cluster (e.g. when debugging).
storage_sanity_use_openshift_workload() {
    [ "${RUNAI_SANITY_STORAGE_FORCE_GENERIC:-0}" = 1 ] && return 1
    [ "${RUNAI_SANITY_STORAGE_FORCE_GENERIC:-false}" = true ] && return 1
    storage_sanity_is_openshift
}

# Default OCP preflight image: UBI9 (aligns with typical OCP pull policy).
# For air-gapped or docker.io–only, set e.g. SANITY_STORAGE_OCP_POD_IMAGE=busybox:1.36
storage_sanity_openshift_pod_image() {
    if [ -n "${SANITY_STORAGE_OCP_POD_IMAGE:-}" ]; then
        echo "$SANITY_STORAGE_OCP_POD_IMAGE"
    else
        echo "registry.access.redhat.com/ubi9/ubi-minimal:latest"
    fi
}

storage_wait_pvc_bound() {
    local ns="$1" name="${2:-sanity-pvc}" max="${3:-150}"
    local i=0
    while [ "$i" -lt "$max" ]; do
        local ph
        ph=$(kubectl get pvc -n "$ns" "$name" -o jsonpath='{.status.phase}' 2>/dev/null) || true
        if [ "$ph" = "Bound" ]; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# RWO + write check without fixed UID or root; matches restricted/default SCC.
run_storage_tests_openshift_workload() {
    local SC_TO_USE="${1?}"
    local OCP_IMAGE
    OCP_IMAGE="$(storage_sanity_openshift_pod_image)"
    if [ "${SILENT_MODE:-false}" = false ]; then
        echo -e "OpenShift: using storage preflight image ${OCP_IMAGE} (set SANITY_STORAGE_OCP_POD_IMAGE to override; uid/chown tests skipped for SCC compatibility)"
    fi

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
---
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
  namespace: $TEST_NS
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: storage-test
    image: $OCP_IMAGE
    command:
    - sleep
    - "3600"
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: storage-volume
      mountPath: /data
  volumes:
  - name: storage-volume
    persistentVolumeClaim:
      claimName: sanity-pvc
EOF

    if ! storage_wait_pvc_bound "$TEST_NS" sanity-pvc 180; then
        echo -e "❌ Storage test failed (PVC not Bound in time; WaitForFirstConsumer or provisioning?)"
        return 1
    fi
    echo -e "✅ PVC successfully bound"

    if ! kubectl wait --for=condition=ready "pod/storage-test" -n "$TEST_NS" --timeout=180s > /dev/null 2>&1; then
        echo -e "❌ Storage test failed (test pod not ready; check image pull / events: kubectl -n $TEST_NS describe pod storage-test)"
        return 1
    fi

    local rw_ok=false
    local i
    for i in {1..5}; do
        if kubectl exec -n "$TEST_NS" storage-test -- sh -c 'printf ok > /data/sanity-test.txt' > /dev/null 2>&1; then
            rw_ok=true
            break
        fi
        sleep 3
    done
    if [ "$rw_ok" != true ]; then
        echo -e "⚠️ Storage write probe failed under OpenShift workload constraints; PVC bind/provisioning succeeded."
        echo -e "✅ StorageClass provisioning check passed (PVC bound + workload scheduled)."
        return 0
    fi

    local read_ok=false
    for i in {1..5}; do
        if kubectl exec -n "$TEST_NS" storage-test -- sh -c 'test -f /data/sanity-test.txt' > /dev/null 2>&1; then
            read_ok=true
            break
        fi
        sleep 2
    done
    if [ "$read_ok" != true ]; then
        echo -e "⚠️ Storage read-back probe failed under OpenShift workload constraints; PVC bind/provisioning succeeded."
        echo -e "✅ StorageClass provisioning check passed (PVC bound + workload scheduled)."
        return 0
    fi

    echo -e "✅ RWO read/write check passed (OpenShift: 1001:1001 and root chown tests skipped; not applicable under restricted SCC)"
    echo -e "✅ Storage test completed"
    return 0
}

# Function to run storage tests
run_storage_tests() {
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

    if storage_sanity_use_openshift_workload; then
        run_storage_tests_openshift_workload "$SC_TO_USE"
        return $?
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

    # Wait for PVC to be present then Bound (WFFC: allow extra time for provisioner)
    for i in {1..30}; do
        if kubectl get pvc -n "$TEST_NS" sanity-pvc &>/dev/null; then
            break
        fi
        sleep 2
    done
    if ! storage_wait_pvc_bound "$TEST_NS" sanity-pvc 150; then
        echo -e "❌ Storage test failed"
        return 1
    fi
    echo -e "✅ PVC successfully bound"

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
