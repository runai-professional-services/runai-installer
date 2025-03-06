# 🚀 AI Factory Appliance Installer

![AI Factory](https://img.shields.io/badge/AI%20Factory-Appliance%20Installer-blue)

## 📋 Overview

This repository contains a one-click installation script for setting up an AI Factory Appliance. The installer automates the deployment of a complete AI infrastructure stack on servers with GPUs, including Kubernetes, Run.ai, and all necessary components.

## ✨ Features

The installation includes:

🔄 Full Kubernetes cluster setup  
🧠 Run.ai Resource Management Platform  
🔒 Self-signed certificates configuration  
💾 Storage system initialization  
🌐 NGINX Ingress Controller  
📊 Monitoring and observability tools  
🖥️ GPU Operator for NVIDIA  
🚢 Optional Knative serving  

## 🛠️ Prerequisites

- Any Server with one GPU
- Ubuntu 20.04 or later
- Internet connectivity
- Sudo privileges

## 🚀 Quick Start

## 📝 Usage Options


Usage: ./one-click-install.sh [-p PART] [--dns DNS_NAME] [--runai-version VERSION] [--repo-secret FILE] [--knative] [--internal-dns] [--ip IP_ADDRESS] [--runai-only] [--cert CERT_FILE] [--key KEY_FILE]


Options:
--dns DNS_NAME Specify DNS name for Run.ai certificates

--runai-version  Specify Run.ai version to install

--repo-secret FILE Optional: Specify repository secret file location

--knative Optional: Install Knative serving

--internal-dns Optional: Configure internal DNS

--ip IP_ADDRESS Required if --internal-dns is set: Specify IP address for internal DNS

--runai-only Optional: Skip prerequisites and directly install Run.ai

--cert CERT_FILE Optional: Use provided certificate file instead of generating self-signed

--key KEY_FILE Optional: Use provided key file instead of generating self-signed




## 🔍 Installation Phases

The installer is divided into four main parts:

1. **Kubespray Installation**: Sets up the Kubernetes environment
2. **Storage Setup**: Configures persistent storage
3. **Kubernetes Installation**: Deploys the Kubernetes cluster
4. **Run.ai Installation**: Installs and configures the Run.ai platform

## 🔐 Certificate Management

The installer can either:
- Generate self-signed certificates automatically
- Use your provided certificates with the `--cert` and `--key` options

## 🌐 Internal DNS Configuration

For environments without external DNS, use the `--internal-dns` option with an IP address to configure CoreDNS for internal name resolution.

