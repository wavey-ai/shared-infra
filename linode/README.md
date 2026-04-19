# Linode Infrastructure

Scripts for managing Linode infrastructure.

## Prerequisites

1. Linode CLI token in `~/.linode_wavey` or repo-local `.linode-token`
2. SSH key (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`)
3. OIDC env at `io/.env`
4. TLS env at `tls-certs/.env`

## IDP Server

Single Sign-On server using hyper-idp with Auth0.

### Create

```bash
./idp.sh create
```

### Other Commands

```bash
./idp.sh status   # Show server status
./idp.sh ssh      # SSH into server
./idp.sh logs     # Tail service logs
./idp.sh destroy  # Destroy server
```

### Configuration

After creation, add callback URL to Auth0:
- Allowed Callback URLs: `https://idp.wavey.io/oauth2/callback`
- Allowed Logout URLs: `https://idp.wavey.io`

### Architecture

```
┌─────────────────────────────────────────────────────┐
│  Deploy Host                                         │
│  - repo-local Linode token                          │
│  - io/.env                                          │
│  - tls-certs/.env                                   │
└─────────────────────────────────────────────────────┘
                         │
                         ▼ (scp on setup)
┌─────────────────────────────────────────────────────┐
│  Linode Dedicated 4GB/2CPU (gb-lon)                │
│  - Arch Linux                                       │
│  - hyper-idp binary                                 │
│  - Let's Encrypt wildcard cert (*.wavey.io)         │
│  - Auto-renewal with deploy hook                    │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
              https://idp.wavey.io
```

### Endpoints

| Endpoint | Description |
|----------|-------------|
| `/login` | Redirects to Auth0 |
| `/oauth2/callback` | OAuth callback |
| `/profile` | User info (requires session) |
| `/users` | Active user IDs (for allow list) |
| `/validate?session_id=xxx` | Validate session |
| `/logout` | End session |

### Cert Renewal

Certificates auto-renew via certbot timer. The deploy hook at
`/etc/letsencrypt/renewal-hooks/deploy/hyper-idp.sh` updates
the service config and restarts it.

## ASR TRT GPU Server

Dedicated external Arch GPU node for TensorRT bring-up without Kubernetes.

### Recommended Type

Current guidance for full Cohere TRT engine build:

- `g2-gpu-rtx4000a1-m` for a single RTX4000 Ada with `32GB` RAM
- avoid `g2-gpu-rtx4000a1-s` for full first-build bring-up; it can OOM during engine compilation

Type data comes from the public Linode types API:

```bash
curl -s https://api.linode.com/v4/linode/types | jq '.data[] | select(.class == "gpu") | {id, label, memory, price}'
```

### Create

```bash
./asr-trt-gpu.sh create
```

Useful overrides:

```bash
REGION=de-fra-2 \
LINODE_TYPE=g2-gpu-rtx4000a1-m \
LABEL=asr-trt-gpu-01 \
./asr-trt-gpu.sh create
```

To manage a DNS entry, also set:

```bash
DOMAIN_ID=<linode-domain-id> \
SUBDOMAIN=cohere-trt-test \
DOMAIN_NAME=wavey.ai \
./asr-trt-gpu.sh create
```

### Runtime Setup

`asr-trt-gpu-setup.sh` prepares the base runtime layout used by the current TRT test host:

- Arch packages: `nvidia-open-dkms`, `nvidia-utils`, `cuda`, `linux-headers`
- side-by-side CUDA 12.8 runtime at `/opt/cuda-12.8-runtime`
- ONNX Runtime GPU at `/opt/onnxruntime-trt`
- TensorRT at `/opt/tensorrt`
- optional temporary swapfile `/swapfile-trt`

By default, ONNX Runtime is pulled from the public GitHub release:

```bash
ONNXRUNTIME_URL=https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-linux-x64-gpu-1.24.4.tgz
```

TensorRT should be provided explicitly:

```bash
TENSORRT_URL=<official TensorRT tarball URL> ./asr-trt-gpu.sh create
```

### Capture a Base Image

After the node is in the state you want to reuse:

```bash
IMAGE_LABEL=arch-gpu-trt-base-20260419 ./asr-trt-gpu.sh capture-image
```
