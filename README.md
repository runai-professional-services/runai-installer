# 🚀 AI Factory One-Click Installer

![AI Factory](https://img.shields.io/badge/AI%20Factory-Installation%20Wizard-blue)
![Run.ai](https://img.shields.io/badge/Run.ai-Automation-green)
![Kubernetes](https://img.shields.io/badge/Kubernetes-Ready-brightgreen)

## 🌟 Overview

The AI Factory One-Click Installer is a powerful bash script that automates the deployment of Run.ai on Kubernetes clusters. This tool simplifies what would otherwise be a complex, multi-step installation process into a single command with customizable options.

## ✨ Features

- 🔄 **Complete Run.ai Installation**: Automates the entire Run.ai deployment process
- 🛠️ **Prerequisite Management**: Installs and configures all necessary components
- 🔐 **Certificate Management**: Generates self-signed certificates or uses your own
- 🌐 **DNS Configuration**: Sets up internal DNS or patches your hosts file
- 🚦 **Ingress Control**: Installs and configures Nginx Ingress Controller
- 📊 **Monitoring**: Optional Prometheus Stack installation
- 🖥️ **GPU Support**: Optional NVIDIA GPU Operator installation
- 🚀 **Serverless**: Optional Knative serving installation
- 🔧 **BCM Integration**: Optional Bright Cluster Manager configuration

## 🚀 Quick Start


### Installation with internal DNS configuration

one-click-installer.sh --dns runai.example.com --internal-dns --ip 172.21.140.20 --runai-version 2.20.22

### Installation with custom certificates

one-click-installer.sh --dns runai.example.com --runai-version 2.20.22 --cert /path/to/cert.pem --key /path/to/key.pem

### Full installation with all optional components

one-click-installer.sh --dns runai.example.com --runai-version 2.20.22 --nginx --prometheus --gpu-operator --knative --internal-dns

### Full installation with all optional components - use case without any DNS - using sslip.io - example

one-click-installer.sh --dns www.192.168.0.1.sslip.io  --runai-version 2.20.22 --nginx --prometheus --gpu-operator --knative --internal-dns



## 📋 Options

| Option | Description |
|--------|-------------|
| `--dns DNS_NAME` | Specify DNS name for Run.ai certificates |
| `--runai-version VER` | Specify Run.ai version to install |
| `--runai-only` | Skip prerequisites and directly install Run.ai |
| `--internal-dns` | Configure internal DNS |
| `--ip IP_ADDRESS` | Specify IP address (required with --internal-dns) |
| `--cert CERT_FILE` | Use provided certificate file |
| `--key KEY_FILE` | Use provided key file |
| `--knative` | Install Knative serving |
| `--nginx` | Install Nginx Ingress Controller |
| `--patch-nginx` | Patch existing Nginx with external IP |
| `--prometheus` | Install Prometheus Stack |
| `--gpu-operator` | Install NVIDIA GPU Operator |
| `--repo-secret FILE` | Specify repository secret file location |
| `--bcm` | Configure Bright Cluster Manager for Run.ai access |

## 🔍 Prerequisites

- Kubernetes cluster (unless using `--runai-only` with an existing cluster)
- `kubectl` configured to access your cluster
- `helm` installed
- `jq` installed for JSON processing
- `openssl` for certificate generation

## 🛠️ What It Does

1. **Validates** your environment and parameters
2. **Installs** prerequisites (Nginx, Prometheus, GPU Operator) if needed
3. **Configures** DNS settings (internal or hosts file)
4. **Generates** or uses provided certificates
5. **Deploys** Run.ai backend services
6. **Configures** the Run.ai cluster
7. **Verifies** the installation

## 🔒 Default Access

After installation, you can access Run.ai at:
- URL: `https://YOUR_DNS_NAME`
- Default credentials: `test@run.ai` / `XXX'

## 🤝 Contributing

Contributions are welcome! Feel free to submit issues or pull requests.

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgements

- Script is maintained by Erez Kirson - ekirson@nvidia.com
