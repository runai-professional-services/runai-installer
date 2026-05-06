# Run.ai Installer

![Run.ai](https://img.shields.io/badge/Run.ai-Installer-blue)
![Kubernetes](https://img.shields.io/badge/Kubernetes-Ready-green)

Automates Run:ai on an existing Kubernetes cluster. Optional: install a cluster with Kubespray (`install-k8.sh`).

---

## Contents

- [Prerequisites](#prerequisites)
- [1. Recommended: `--automatic`](#1-recommended---automatic)
- [2. Manual install](#2-manual-install)
- [3. Advanced examples](#3-advanced-examples)
- [OpenShift (OCP)](#openshift-ocp)
- [Standalone helper scripts](#standalone-helper-scripts)
- [What the installer does](#what-the-installer-does)
- [Default access](#default-access)
- [Reference: all options](#reference-all-options)
- [Kubernetes cluster install](#kubernetes-cluster-install-kubespray)
- [Contributing & license](#contributing)

---

## Prerequisites

- NVIDIA Run:ai license / repo credentials
- A Kubernetes cluster and working `kubectl`
- `helm`, `jq`, and `openssl` (for typical installs)

---

## 1. Recommended: `--automatic`

Use **`--automatic`** when you want the installer to **prepare the cluster and install Run:ai** in one flow.

| You provide | Notes |
|-------------|--------|
| **`--ngc-key`** or **`NGC_API_KEY`** | NGC path (`--ngc-key` implies `--ngc`) |
| **or** **`--repo-secret`** | JFrog path — do **not** mix NGC + JFrog flags on the same command |
| Optional **`--dns`** | Overrides the default sslip-style name |
| Optional **`--cert`** / **`--key`** / **`--cacert`** | Custom TLS ( **`--cert`** and **`--key`** together) |
| Optional **`-y`** | Skip confirmation prompts |

**Vanilla Kubernetes (automatic):** the installer **chooses one worker node** and uses **that worker’s IP address** for HAProxy: the ingress Service **`spec.externalIPs`** is set to that IP, and the default DNS name is usually derived from the same IP (e.g. **sslip.io**). Override the hostname anytime with **`--dns`**.

**OpenShift:** `--automatic` detects OCP and does **not** use the HAProxy + ExternalIP pattern below—see [OpenShift (OCP)](#openshift-ocp).

### Vanilla Kubernetes: HAProxy and External IP

On vanilla Kubernetes, **`--automatic`** deploys **HAProxy Ingress** and binds it to the **selected worker IP** as above. Clients reach Run:ai via a **DNS name** that resolves to that IP (unless you set **`--dns`** to something else).

**Traffic flow (request path, top to bottom):**

```
                    ┌────────────────────────┐
                    │ Client (browser, CLI)  │
                    └───────────┬────────────┘
                                │  HTTPS
                                ▼
                    ┌────────────────────────┐
                    │ DNS hostname           │
                    │ (e.g. sslip.io record) │
                    └───────────┬────────────┘
                                │  resolves to that worker’s IP
                                ▼
                    ┌────────────────────────┐
                    │ Worker (one selected)  │
                    │ IP in externalIPs      │
                    └───────────┬────────────┘
                                │
                                ▼
                    ┌────────────────────────┐
                    │ HAProxy Ingress        │
                    │ Service externalIPs[]  │
                    └───────────┬────────────┘
                                │
                                ▼
                    ┌────────────────────────┐
                    │ Run:ai control plane   │
                    └────────────────────────┘
```

### `--automatic` examples (start here)

```sh
# NGC — minimal
./runai-installer.sh --automatic --ngc-key "$NGC_API_KEY"
```

```sh
# NGC — custom DNS + non-interactive
./runai-installer.sh --automatic -y --ngc-key "$NGC_API_KEY" --dns runai.example.com
```

```sh
# NGC — custom TLS
./runai-installer.sh --automatic --ngc-key "$NGC_API_KEY" \
  --dns runai.example.com \
  --cert /path/to/cert.pem --key /path/to/key.pem --cacert /path/to/rootCA.pem
```

```sh
# JFrog
./runai-installer.sh --automatic -y --repo-secret ./license.yaml
```

```sh
# Stop after a phase (debug / partial runs)
./runai-installer.sh --automatic --ngc-key "$NGC_API_KEY" --automatic-stop-after prereqs
```

---

## 2. Manual install

Use explicit flags when you are not using **`--automatic`**.

**Usually required:** `--dns`, `--runai-version`, `--repo-secret` (unless air-gapped / other documented exceptions).

**Vanilla Kubernetes:** pick an ingress class for the control plane, e.g. **`--use-haproxy`** (often with **`--haproxy`**) or **`--use-nginx`** (often with **`--nginx`**). See `runai-installer.sh --help`.

```sh
./runai-installer.sh --dns 192.168.0.100.sslip.io --runai-version 2.22.47 \
  --use-nginx --nginx --repo-secret ./license.yaml
```

```sh
./runai-installer.sh --dns runai.example.com --runai-version latest \
  --use-nginx --repo-secret ./license.yaml
```

**Common option rules**

- `--internal-dns` → needs `--ip`
- `--cert` ↔ `--key` (use both)
- `--patch-nginx` / `--patch-haproxy` → needs `--ip`

---

## 3. Advanced examples

**Internal DNS**

```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 \
  --use-nginx --internal-dns --ip 172.21.140.20 --repo-secret ./license.yaml
```

**Custom certificates**

```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 \
  --use-nginx \
  --cert /path/to/cert.pem --key /path/to/key.pem \
  --cacert /path/to/rootCA.pem --repo-secret ./license.yaml
```

**Many optional components**

```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 \
  --use-nginx --nginx --prometheus --gpu-operator --training --lws --install-sc \
  --internal-dns --ip 172.21.140.20 --repo-secret ./license.yaml
```

**Subdomain / wildcard workloads**

```sh
./runai-installer.sh --dns runai.example.com --runai-version 2.22.47 \
  --use-nginx --subdomain --repo-secret ./license.yaml
```

**Prerequisites only (no Run:ai)**

```sh
./runai-installer.sh --install-only --nginx --knative --lws --install-sc
```

**Air-gapped** — use **`--air-gapped`** with **`--file`** and **`--registry`**. This path is **not** combined with **`--automatic`** in the current installer.

```sh
./runai-installer.sh --dns 192.168.0.100.sslip.io --use-nginx \
  --air-gapped --file /path/to/runai-air-gapped.tar.gz --registry registry.example.com \
  --repo-secret ./license.yaml
```

**Uninstall**

```sh
./runai-installer.sh --uninstall
./runai-installer.sh --uninstall -y
```

---

## OpenShift (OCP)

Run:ai uses **Routes** and **`kubernetesDistribution=openshift`**. Do **not** use **`--use-nginx` / `--use-haproxy`** for the control plane like on vanilla Kubernetes.

- **`--openshift`** — optional **`--dns`** if the installer can derive `runai.apps.<baseDomain>`
- **`--no-cert`** — typical when using the cluster router TLS
- **`--openshift-ingress-cacert`** — optional router CA PEM with **`--openshift`** + **`--no-cert`**

```sh
./runai-installer.sh --openshift --no-cert --ngc --ngc-api-key "$NGC_API_KEY" --runai-version 2.22.47
```

---

## Standalone helper scripts

Not called by `runai-installer.sh`.

| Script | Purpose |
|--------|---------|
| **`delete-pre-req.sh`** | Removes optional stack: Prometheus, Knative, GPU Operator, HAProxy, Training Operator, NIM Operator, LWS (`-y`, `--dry-run`) |
| **`dynamo-install.sh`** | Installs NVIDIA AI Dynamo (`dynamo-platform`); default chart pull via HTTPS tarball + NGC key ([Dynamo quickstart](https://docs.nvidia.com/dynamo/dev/getting-started/kubernetes-deployment)) |

---

## What the installer does

1. Validates flags and environment  
2. Optionally installs add-ons (ingress, Prometheus, GPU Operator, Knative, LWS, …)  
3. Labels nodes, DNS/certs as requested  
4. Deploys Run:ai backend and cluster (or air-gapped flow)  
5. Applies TLS secrets and optional subdomain / BCM steps  

---

## Default access

- **URL:** `https://YOUR_DNS_NAME`  
- **Default login (if unchanged):** `test@run.ai` / per your deployment docs  

---

## Reference: all options

| Option | Description | Required |
|--------|-------------|----------|
| `--dns DNS_NAME` | Run:ai FQDN / certificates | ✅ (most manual installs) |
| `--runai-version VER` | Version or `latest` | ✅ (most manual installs) |
| `--repo-secret FILE` | License / registry secret file | ✅ (most manual installs) |
| `--automatic` | Prep + Run:ai; NGC or JFrog | ❌ |
| `--automatic-chain` | Legacy alias of `--automatic` | ❌ |
| `--automatic-stop-after` | Stop after `helm`, `nodes`, `prereqs`, … | ❌ |
| `-y`, `--yes` | Non-interactive (`--automatic`, `--uninstall`) | ❌ |
| `--cluster-only` | Cluster chart only (skip backend) | ❌ |
| `--internal-dns` | CoreDNS patch | ❌ |
| `--ip` | Required with `--internal-dns`, patch-nginx, patch-haproxy | ❌ |
| `--cert` / `--key` / `--cacert` | Custom TLS | ❌ |
| `--no-cert` | Skip cert generation | ❌ |
| `--knative` | Knative Serving | ❌ |
| `--nginx` / `--patch-nginx` | Nginx ingress | ❌ |
| `--haproxy` / `--patch-haproxy` | HAProxy ingress | ❌ |
| `--use-haproxy` / `--use-nginx` | CP ingress class (vanilla K8s) | ❌ |
| `--prometheus` | Prometheus stack | ❌ |
| `--gpu-operator` | NVIDIA GPU Operator | ❌ |
| `--training` | Kubeflow Training Operator | ❌ |
| `--lws` | Local Workload Service | ❌ |
| `--install-sc` | Default StorageClass (local-path) | ❌ |
| `--nim-operator` | NIM Operator | ❌ |
| `--dynamo` | NVIDIA AI Dynamo | ❌ |
| `--BCM` | Bright Cluster Manager | ❌ |
| `--air-gapped` / `--file` / `--registry` | Offline bundle install | ❌ |
| `--registry-secret` / `--skip-upload` | Air-gapped helpers | ❌ |
| `--subdomain` | Wildcard ingress | ❌ |
| `--install-only` | Prerequisites only | ❌ |
| `--uninstall` | Remove Run:ai | ❌ |
| `--openshift` | OpenShift distribution | ❌ |
| `--openshift-ingress-cacert FILE` | OCP router CA (with `--no-cert`) | ❌ |

For the full CLI text, run:

```sh
./runai-installer.sh --help
```

---

## Kubernetes cluster install (Kubespray)

```sh
./install-k8.sh              # full stack
./install-k8.sh --core     # Kubernetes only
./install-k8.sh --addons --nginx --prometheus --gpu
./install-k8.sh --clean
```

---

## Contributing

Issues and pull requests are welcome.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Maintained by Erez Kirson — ekirson@nvidia.com
