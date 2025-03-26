 Kubernetes Cluster Sanity Check Script

A comprehensive testing script for validating Kubernetes cluster configurations, hardware requirements, and functionality.

## Features

- Hardware Requirements Validation
  - CPU cores across worker nodes (minimum 24 cores)
  - RAM across worker nodes (minimum 32GB)
  - GPU detection and information
- Storage Testing
  - PVC creation and binding
  - Storage permissions
  - Read/Write operations
- TLS/Ingress Testing
  - Certificate validation
  - Ingress configuration
  - Internal/External access

## Prerequisites

- Kubernetes cluster with admin access
- `kubectl` configured with appropriate cluster access
- Required tools:
  - `kubectl`
  - `curl`
  - `bash`

## Usage

### Basic Command Structure

```bash
./sanity-check.sh [OPTIONS]
```

### Available Options

| Option | Description |
|--------|-------------|
| `--cert CERT_FILE` | Certificate file for TLS |
| `--key KEY_FILE` | Key file for TLS |
| `--dns DNS_NAME` | DNS name to test |
| `--cacert CA_FILE` | CA certificate file for SSL verification (optional) |
| `--storage` | Run only storage tests |
| `--class STORAGE_CLASS` | Specify StorageClass for storage tests (optional) |
| `--hardware` | Validate minimum hardware requirements |

### Example Commands

1. Hardware check only:
```bash
./sanity-check.sh --hardware
```

2. Storage test with default StorageClass:
```bash
./sanity-check.sh --storage
```

3. Storage test with specific StorageClass:
```bash
./sanity-check.sh --storage --class local-path
```

4. Full test with TLS:
```bash
./sanity-check.sh --cert runai.crt --key runai.key --dns runai.example.com
```

5. Full test with custom CA:
```bash
./sanity-check.sh --cert runai.crt --key runai.key --dns runai.example.com --cacert ca.pem
```

## Output

The script provides detailed output including:

### Hardware Check

### Storage Check

## 📝 Prerequisites

- Kubernetes cluster with admin access
- `kubectl` CLI tool installed and configured
- `curl` for HTTP/HTTPS testing
- Minimum cluster requirements:
  - 24 CPU cores total
  - 32GB RAM total
  - Working StorageClass
  - Ingress controller (for TLS tests)

## 📦 Installation

1. Download the script:
```bash
curl -O https://raw.githubusercontent.com/[your-repo]/sanity-check.sh
```

2. Make it executable:
```bash
chmod +x sanity-check.sh
```

## 📄 Logging

- All operations are logged to: `./logs/sanity_check_YYYYMMDD_HHMMSS.log`
- Detailed command outputs
- Error messages and debugging information
- Resource creation/deletion tracking

## ⚠️ Troubleshooting

### SSL Verification Failures
- Expected with self-signed certificates
- Use `--cacert` for proper SSL verification

### Storage Class Issues
- Ensure StorageClass exists
- Check StorageClass provisioner status
- Verify storage backend availability

### Hardware Check Failures
- Confirm worker node resources
- Check GPU driver installation
- Verify node labels and taints

## 🧹 Cleanup

The script automatically:
- Removes test namespace
- Deletes test PVCs and pods
- Cleans up ingress configurations
- Removes temporary resources

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.

## ✉️ Contact

Script maintained by Erez Kirson - ekirson@nvidia.com

