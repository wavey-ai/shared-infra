# Linode Infrastructure

Scripts for managing Linode infrastructure.

## Prerequisites

1. Linode CLI token in `~/.linode_wavey`
2. SSH key (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`)
3. Object Storage secret key (set `OBJ_SECRET_KEY` env var)

## IDP Server

Single Sign-On server using hyper-idp with Auth0.

### Create

```bash
export OBJ_SECRET_KEY="<object-storage-secret>"
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
│  Linode Object Storage (gb-lon-1)                   │
│  Bucket: wavey-creds                                │
│  ├── tls/certs.env                                  │
│  └── oidc/config.env                                │
└─────────────────────────────────────────────────────┘
                         │
                         ▼ (fetch on setup)
┌─────────────────────────────────────────────────────┐
│  Linode Nanode (gb-lon)                             │
│  - Rocky Linux 9                                    │
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

### Object Storage

Bucket: `wavey-creds` in `gb-lon-1`

| Path | Contents |
|------|----------|
| `oidc/config.env` | OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_AUDIENCE |
| `tls/certs.env` | Base64 encoded certs |
| `tls/fullchain.pem` | TLS certificate chain |
| `tls/privkey.pem` | TLS private key |

### Cert Renewal

Certificates auto-renew via certbot timer. The deploy hook at
`/etc/letsencrypt/renewal-hooks/deploy/hyper-idp.sh` updates
the service config and restarts it.
