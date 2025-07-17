# Kubernetes Cluster Sanity Check Script

A comprehensive testing script for validating Kubernetes cluster configurations, hardware requirements, storage functionality, and Run.ai compatibility.

## 🌟 Features

### 🔧 Hardware Requirements Validation
- **CPU & Memory**: Validates minimum requirements (24 CPU cores, 24GB RAM total)
- **GPU Detection**: Identifies GPU nodes and counts total GPUs
- **Node Roles**: Detects master, worker, and combined master+worker nodes
- **Run.ai Compatibility**: Checks Kubernetes version compatibility with Run.ai versions 2.17-2.22
- **Component Validation**: Verifies required components (Helm, Prometheus, NGINX, GPU Operator)

### 💾 Storage Testing
- **PVC Creation & Binding**: Tests persistent volume claim functionality
- **Storage Permissions**: Validates file ownership and permission handling
- **Read/Write Operations**: Tests basic file operations on persistent storage
- **Storage Class Support**: Works with default or specified storage classes

### 🔐 TLS/Ingress Testing
- **Certificate Validation**: Tests custom certificate deployment
- **Ingress Configuration**: Validates ingress controller setup
- **Internal/External Access**: Tests both pod-to-pod and external HTTPS access
- **SSL Verification**: Supports CA certificate validation

### 🖥️ Disk/Ephemeral Storage Check
- **Node-by-Node Analysis**: Checks storage on all cluster nodes
- **Capacity Monitoring**: Validates minimum storage requirements (110GB/150GB for GPU nodes)
- **Usage Monitoring**: Warns about high disk usage and pressure conditions
- **Storage Pressure Detection**: Identifies nodes under disk pressure

### 🔍 Preinstall Diagnostics
- **Automated Diagnostics**: Runs Run.ai preinstall diagnostics tool
- **Domain Testing**: Supports custom domain testing for diagnostics
- **Comprehensive Results**: Parses and displays diagnostic results in readable format
- **Timeout Protection**: Includes 5-minute timeout for diagnostics execution

### 🧹 Cleanup Functionality
- **Namespace Cleanup**: Removes all `sanity-test-*` namespaces
- **Force Deletion**: Uses `--force` deletion for stuck namespaces
- **API Cleanup**: Implements finalizer removal for persistent namespaces
- **Orphaned Resource Handling**: Cleans up resources in non-existent namespaces

## 📋 Prerequisites

- Kubernetes cluster with admin access
- `kubectl` configured with appropriate cluster access
- Required tools:
  - `kubectl`
  - `curl`
  - `bash`
  - `jq` (for JSON processing)
  - `timeout` (for command timeouts)
  - `bc` (for mathematical operations)

## 🚀 Usage

### Basic Command Structure

```bash
./sanity-check.sh [OPTIONS]
```

### Available Options

| Option | Description | Required With |
|--------|-------------|---------------|
| `--cert CERT_FILE` | Certificate file for TLS | `--key`, `--dns` |
| `--key KEY_FILE` | Private key file for TLS | `--cert`, `--dns` |
| `--dns DNS_NAME` | DNS name for ingress testing | `--cert`, `--key` |
| `--cacert CA_FILE` | CA certificate file for SSL verification | Optional |
| `--storage` | Run storage tests only | None |
| `--class STORAGE_CLASS` | Specify storage class for tests | Optional |
| `--hardware` | Check hardware requirements only | None |
| `--disk` | Check disk/ephemeral storage only | None |
| `--diag` | Run preinstall diagnostics | None |
| `--diag-dns NAME` | DNS name for diagnostics | `--diag` |
| `--prereq` | Check prerequisite software | None |
| `--clean` | Clean up all sanity-test namespaces | None |
| `--silent` | Suppress output messages | None |
| `-h, --help` | Show help message | None |

### Example Commands

#### 1. Hardware Check Only
```bash
./sanity-check.sh --hardware
```
Validates cluster hardware requirements and Run.ai compatibility.

#### 2. Storage Test with Default StorageClass
```bash
./sanity-check.sh --storage
```
Tests storage functionality using the default storage class.

#### 3. Storage Test with Specific StorageClass
```bash
./sanity-check.sh --storage --class local-path
```
Tests storage functionality using a specific storage class.

#### 4. Disk/Ephemeral Storage Check
```bash
./sanity-check.sh --disk
```
Checks disk usage and storage requirements on all nodes.

#### 5. Preinstall Diagnostics
```bash
./sanity-check.sh --diag
```
Runs Run.ai preinstall diagnostics tool.

#### 6. Diagnostics with Custom Domain
```bash
./sanity-check.sh --diag --diag-dns runai.example.com
```
Runs diagnostics with a specific domain.

#### 7. Full TLS Test
```bash
./sanity-check.sh --cert runai.crt --key runai.key --dns runai.example.com
```
Performs complete TLS/ingress testing.

#### 8. Full Test with CA Certificate
```bash
./sanity-check.sh --cert runai.crt --key runai.key --dns runai.example.com --cacert ca.pem
```
Performs TLS testing with SSL verification.

#### 9. Cleanup Test Namespaces
```bash
./sanity-check.sh --clean
```
Removes all `sanity-test-*` namespaces and resources.

#### 10. Combined Operations
```bash
./sanity-check.sh --hardware --storage --disk
```
Runs hardware check, storage tests, and disk checks in sequence.

## 📊 Output Examples

### Hardware Check Output
```
Checking hardware requirements...
Minimum Required: 24GB RAM, 24 CPU Cores

Checking Kubernetes version...
✅ Kubernetes version: v1.28.5

Checking Run.ai version compatibility...
✅ Supported Run.ai versions: 2.18, 2.19, 2.20

Checking node: worker-node-1
└─ Role: master+worker (control-plane + workload)
└─ OS: Ubuntu 22.04.3 LTS
└─ CPU Cores: 16
└─ RAM: 32GB
└─ GPU Count: 2

Cluster Resources Summary:
----------------------------------------
Total Nodes: 3
Total CPU Cores: 48 (minimum: 24)
Total RAM: 96GB (minimum: 24GB)
GPU Nodes: 2
Total GPUs: 4
Minimum Disk Space: 110GB per node
----------------------------------------
✅ Cluster meets minimum requirements
```

### Storage Check Output
```
Storage Check Summary:
----------------------------------------
Total Nodes Checked: 3
Minimum Required: 110GB per node (150GB for GPU nodes)
Nodes with Issues: 0
✅ All nodes have adequate storage
----------------------------------------
```

### Diagnostics Output
```
Node worker-node-1
  ✓ Kubernetes Version Check: PASS
  ✓ Docker Version Check: PASS
  ✓ GPU Driver Check: PASS
  ✓ Network Connectivity: PASS

Node worker-node-2
  ✓ Kubernetes Version Check: PASS
  ✓ Docker Version Check: PASS
  ✗ GPU Driver Check: FAIL
    Error: NVIDIA driver not found
```

## 📝 Logging

- **Log Directory**: `./logs/`
- **Log Files**: `sanity_check_YYYYMMDD_HHMMSS.log`
- **Latest Log**: `./logs/latest.log` (symlink to most recent)
- **Log Contents**:
  - All command executions
  - Command outputs (stdout/stderr)
  - Error messages and debugging information
  - Resource creation/deletion tracking
  - Timing information

## 🔧 Run.ai Version Compatibility

The script checks Kubernetes version compatibility with Run.ai versions:

| Run.ai Version | Supported Kubernetes Versions |
|----------------|-------------------------------|
| 2.17 | 1.27-1.29 |
| 2.18 | 1.28-1.30 |
| 2.19 | 1.28-1.31 |
| 2.20 | 1.29-1.32 |
| 2.21 | 1.30-1.32 |
| 2.22 | 1.31-1.33 |

## ⚠️ Troubleshooting

### SSL Verification Failures
- **Expected** with self-signed certificates
- Use `--cacert` for proper SSL verification
- Check certificate validity and DNS name matching

### Storage Class Issues
- Ensure StorageClass exists and is default
- Check StorageClass provisioner status
- Verify storage backend availability
- Use `--class` to specify alternative storage class

### Hardware Check Failures
- Confirm worker node resources meet minimums
- Check GPU driver installation for GPU nodes
- Verify node labels and taints
- Ensure kubectl can access cluster

### Namespace Cleanup Issues
- Use `--clean` for stuck namespaces
- Script implements force deletion and API cleanup
- Manual cleanup may be required for persistent issues
- Check for finalizers blocking deletion

### Diagnostics Failures
- Ensure `preinstall-diagnostics.zip` is in current directory
- Check network connectivity for domain tests
- Verify cluster access and permissions
- Review diagnostic output for specific issues

## 🧹 Cleanup

### Automatic Cleanup
The script automatically cleans up:
- Test namespaces (`sanity-test-*`)
- Test PVCs and pods
- Ingress configurations
- Temporary resources
- TLS secrets

### Manual Cleanup
Use the `--clean` option to remove all test namespaces:
```bash
./sanity-check.sh --clean
```

### Cleanup Process
1. **Force Deletion**: Uses `kubectl delete namespace --force`
2. **API Cleanup**: Removes finalizers via API calls
3. **Orphaned Resource Handling**: Cleans resources in non-existent namespaces
4. **Timeout Protection**: Includes timeouts to prevent hanging

## 🔍 Silent Mode

Use `--silent` to suppress output messages while still logging to files:
```bash
./sanity-check.sh --hardware --silent
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.

## ✉️ Contact

Script maintained by Erez Kirson - ekirson@nvidia.com

