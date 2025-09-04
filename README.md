# 🚀 Run.ai Installer

![Run.ai](https://img.shields.io/badge/AI%20Factory-Installation%20Wizard-blue)
![Run.ai](https://img.shields.io/badge/Run.ai-Automation-green)
![Kubernetes](https://img.shields.io/badge/Kubernetes-Ready-brightgreen)

## 📋 Table of Contents

- [Overview](#-overview)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [Configuration Options](#-configuration-options)
- [Examples](#-examples)
- [What It Does](#-what-it-does)
- [Default Access](#-default-access)
- [Kubernetes Installation](#-kubernetes-installation)
- [Contributing](#-contributing)

## 🌟 Overview

The Run.ai Installer is a comprehensive solution that automates the deployment of Run.ai on Kubernetes clusters. This tool provides two main installation paths:

1. **Run.ai Platform Installation** - Deploy Run.ai on an existing Kubernetes cluster (primary focus)
2. **Kubernetes Cluster Installation** - Deploy a complete Kubernetes cluster using Kubespray (optional)

This simplifies what would otherwise be a complex, multi-step installation process into simple commands with customizable options.

## ✨ Features

- 🔄 **Complete Run.ai Installation**: Automates the entire Run.ai deployment process
- 🔐 **Certificate Management**: Generates self-signed certificates or uses your own
- 🌐 **DNS Configuration**: Sets up internal DNS and patches CoreDNS
- 🚦 **Ingress Control**: Installs and configures Nginx Ingress Controller
- 📊 **Monitoring**: Optional Prometheus Stack installation
- 🖥️ **GPU Support**: Optional NVIDIA GPU Operator installation
- 🚀 **Serverless**: Optional Knative serving installation
- 🔧 **BCM Integration**: Optional Bright Cluster Manager configuration
- 🏭 **Air-gapped Support**: Complete offline installation capabilities
- 🛠️ **Kubernetes Cluster Setup**: Full Kubernetes installation using Kubespray (optional)

## 🔍 Prerequisites

### For Run.ai Installation
- Kubernetes cluster (or use our Kubernetes installer)
- `kubectl` configured to access your cluster
- `helm` installed
- `jq` installed for JSON processing
- `openssl` for certificate generation

## 🚀 Quick Start

### Step 1: Install Run.ai
```sh
./runai-installer.sh --dns 192.168.1.100.sslip.io --runai-version 2.22.47 --repo-secret ./license.yaml
```

### Required Parameters
- `--dns`: DNS name for Run.ai access
- `--runai-version`: Run.ai version to install
- `--repo-secret`: Path to your Run.ai license file

### Option Dependencies
- `--internal-dns` requires `--ip`
- `--cert` requires `--key` (and vice versa)
- `--patch-nginx` requires `--ip`

## ⚙️ Configuration Options

### Run.ai Installer Options

| Option | Description | Required |
|--------|-------------|----------|
| `--dns DNS_NAME` | DNS name for Run.ai certificates | ✅ |
| `--runai-version VER` | Run.ai version to install | ✅ |
| `--repo-secret FILE` | Repository secret file location | ✅ |
| `--cluster-only` | Skip backend, install cluster only | ❌ |
| `--internal-dns` | Configure internal DNS | ❌ |
| `--ip IP_ADDRESS` | IP address (required with --internal-dns) | ❌ |
| `--cert CERT_FILE` | Use provided certificate file | ❌ |
| `--key KEY_FILE` | Use provided key file | ❌ |
| `--cacert CA_CERT_FILE` | Use provided CA certificate file | ❌ |
| `--no-cert` | Skip certificate setup | ❌ |
| `--knative` | Install Knative serving | ❌ |
| `--nginx` | Install Nginx Ingress Controller | ❌ |
| `--patch-nginx` | Patch existing Nginx with external IP | ❌ |
| `--prometheus` | Install Prometheus Stack | ❌ |
| `--gpu-operator` | Install NVIDIA GPU Operator | ❌ |
| `--training` | Install Kubeflow Training Operator | ❌ |
| `--lws` | Install Local Workload Service (LWS) | ❌ |
| `--install-sc` | Install Local Path Provisioner | ❌ |
| `--BCM` | Configure Bright Cluster Manager | ❌ |
| `--air-gapped` | Enable air-gapped installation | ❌ |
| `--file FILE` | Air-gapped tar.gz file | ❌ |
| `--registry URL` | Registry URL for air-gapped installation | ❌ |
| `--registry-secret FILE` | Registry secret YAML file | ❌ |
| `--skip-upload` | Skip image uploads (air-gapped mode) | ❌ |
| `--uninstall` | Uninstall Run.ai completely | ❌ |

## 📝 Examples

### Basic Installations

**Using sslip.io (automatic DNS resolution):**
```sh
./runai-installer.sh --dns 192.168.0.100.sslip.io --runai-version 2.22.47 --repo-secret ./license.yaml
```

**Using custom domain:**
```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 --repo-secret ./license.yaml
```

### Advanced Configurations

**Internal DNS setup:**
```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 \
  --internal-dns --ip 172.21.140.20 --repo-secret ./license.yaml
```

**Custom certificates:**
```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 \
  --cert /path/to/cert.pem --key /path/to/key.pem --repo-secret ./license.yaml
```

**Custom certificates with CA:**
```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 \
  --cert /path/to/cert.pem --key /path/to/key.pem \
  --cacert /path/to/rootCA.pem --repo-secret ./license.yaml
```

**Full installation with all components:**
```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 \
  --nginx --prometheus --gpu-operator --training --lws --install-sc \
  --internal-dns --ip 172.21.140.20 --repo-secret ./license.yaml
```

**BCM integration:**
```sh
./runai-installer.sh --dns 192.168.0.200.sslip.io --runai-version 2.22.47 \
  --nginx --prometheus --gpu-operator --knative --BCM \
  --ip 192.168.0.200 --repo-secret ./license.yaml
```

**Air-gapped installation:**
```sh
./runai-installer.sh --dns 192.168.0.100.sslip.io --air-gapped \
  --file /path/to/runai-air-gapped.tar.gz --registry registry.example.com \
  --repo-secret ./license.yaml
```

**Patch existing Nginx:**
```sh
./runai-installer.sh --dns runai.example.com --ip 192.168.0.200 \
  --patch-nginx --repo-secret ./license.yaml
```

**Uninstall Run.ai:**
```sh
./runai-installer.sh --uninstall
```

## 🛠️ What It Does

### Run.ai Installation Process
1. **Validates** your environment and parameters
2. **Installs** prerequisites (Nginx, Prometheus, GPU Operator) if requested
3. **Configures** DNS settings (internal or hosts file)
4. **Generates** or uses provided certificates
5. **Deploys** Run.ai backend services
6. **Configures** the Run.ai cluster
7. **Verifies** the installation
8. **Patches BCM** (if requested) to route traffic to Run.ai

## 🔒 Default Access

After installation, you can access Run.ai at:
- **URL**: `https://YOUR_DNS_NAME`
- **Default credentials**: `test@run.ai` / `XXX`

## 🖥️ Kubernetes Installation

If you don't have a Kubernetes cluster, you can install one using our `install-k8.sh` script:

### Prerequisites for Kubernetes Installation
- Ubuntu/Debian system
- Internet connectivity (for initial setup)
- SSH server running
- Sudo privileges

### Installation Options

```sh
# Full installation with all components
./install-k8.sh

# Core Kubernetes only (no add-ons)
./install-k8.sh --core

# Install add-ons on existing cluster
./install-k8.sh --addons --nginx --prometheus --gpu

# Reset existing cluster
./install-k8.sh --clean
```

**Kubernetes Installation Options:**
- `--full` - Complete installation with all add-ons (default)
- `--core` - Core Kubernetes only
- `--addons` - Install add-ons on existing cluster
- `--nginx` - Include Nginx Ingress Controller
- `--prometheus` - Include Prometheus monitoring stack
- `--gpu` - Include NVIDIA GPU Operator
- `--clean` - Reset existing cluster

### Kubernetes Installation Process
1. **Sets up** system prerequisites (Python, Helm, SSH keys)
2. **Configures** Kubespray inventory
3. **Installs** Kubernetes cluster using Ansible
4. **Deploys** optional add-ons (Nginx, Prometheus, GPU Operator)
5. **Configures** kubectl access

## 🤝 Contributing

Contributions are welcome! Feel free to submit issues or pull requests.

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgements

- Script is maintained by Erez Kirson - ekirson@nvidia.com
