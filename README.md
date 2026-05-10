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
- [Contributing](#contributing)
- [Slow image pulls & flaky networks](#slow-image-pulls-flaky-networks)

---

## Prerequisites

- Run:ai license / registry credentials (NGC or JFrog)
- Kubernetes cluster and working `kubectl`
- `helm`, `jq`, `openssl` (typical installs)

---

## 1. Recommended: `--automatic`

**Try this first** — NGC (API key on the CLI or in `NGC_API_KEY`):

```sh
./runai-installer.sh --automatic --ngc-api-key "$NGC_API_KEY"
```

JFrog instead (non-interactive example):

```sh
./runai-installer.sh --automatic -y --repo-secret ./license.yaml
```

Use **either** NGC **or** JFrog, not both. Common extras: **`-y`** (no prompts), **`--dns`**, **`--cert` / `--key` / `--cacert`**.

On **vanilla Kubernetes**, the installer picks a worker, sets HAProxy **`externalIPs`** to that IP, and usually derives DNS (e.g. sslip-style) unless you pass **`--dns`**. On **OpenShift**, there is no HAProxy + ExternalIP path — see [OpenShift (OCP)](#openshift-ocp).

<details>
<summary>More <code>--automatic</code> examples</summary>

```sh
./runai-installer.sh --automatic -y --ngc-api-key "$NGC_API_KEY" --dns runai.example.com
```

```sh
./runai-installer.sh --automatic --ngc-api-key "$NGC_API_KEY" \
  --dns runai.example.com \
  --cert /path/to/cert.pem --key /path/to/key.pem --cacert /path/to/rootCA.pem
```

```sh
./runai-installer.sh --automatic --ngc-api-key "$NGC_API_KEY" --automatic-stop-after prereqs
```

</details>

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
| **`add-inference.sh`** | After `--knative`: TLS secret in `knative-serving`, KnativeServing domain/network (like `tools/knative-external.yaml`), optional HAProxy + `--ip` (`--dns`, `--cert`, `--key`) |

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

## Slow image pulls & flaky networks

For slow registries or flaky networks, **export these before** you run the installer. Defaults are already conservative (roughly ~50 minutes of auth/install polling at 5s steps; pod checks every 10s).

| Variable | Default | Role |
|----------|---------|------|
| `RUNAI_INSTALL_WAIT_MAX_ATTEMPTS` | `600` | Auth / install-info retries |
| `RUNAI_INSTALL_WAIT_SLEEP_SEC` | `5` | Sleep between those attempts |
| `RUNAI_POD_READY_POLL_SLEEP_SEC` | `10` | Interval for pod-readiness loops |
| `RUNAI_CLUSTER_INSTALL_MAX_RETRIES` | `10` | Air-gapped re-runs of cluster `install.sh` |

```sh
export RUNAI_INSTALL_WAIT_MAX_ATTEMPTS=1200
export RUNAI_INSTALL_WAIT_SLEEP_SEC=10
export RUNAI_POD_READY_POLL_SLEEP_SEC=15
export RUNAI_CLUSTER_INSTALL_MAX_RETRIES=15
```

Waits for `runai-backend` and `runai` readiness are **unbounded** (they end when the workloads become Ready).
