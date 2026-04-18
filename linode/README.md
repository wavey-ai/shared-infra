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
