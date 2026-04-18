#!/bin/bash
set -euo pipefail

# Server setup script for IDP
# Usage: ./idp-setup.sh <server-ip>

SERVER_IP="${1:?Usage: $0 <server-ip>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_TOKEN_FILE="$HOME/.linode_wavey"
if [ -f "$REPO_ROOT/.linode-token" ]; then
    DEFAULT_TOKEN_FILE="$REPO_ROOT/.linode-token"
fi

LINODE_TOKEN_FILE="${LINODE_TOKEN_FILE:-$DEFAULT_TOKEN_FILE}"
DOMAIN_NAME="${DOMAIN_NAME:-wavey.io}"
SUBDOMAIN="${SUBDOMAIN:-idp}"
FQDN="${FQDN:-$SUBDOMAIN.$DOMAIN_NAME}"
OIDC_ENV_FILE="${OIDC_ENV_FILE:-$REPO_ROOT/io/.env}"
TLS_ENV_FILE="${TLS_ENV_FILE:-$REPO_ROOT/tls-certs/.env}"

if [ ! -f "$LINODE_TOKEN_FILE" ]; then
    echo "ERROR: Linode token file not found: $LINODE_TOKEN_FILE"
    exit 1
fi
if [ ! -f "$OIDC_ENV_FILE" ]; then
    echo "ERROR: OIDC env file not found: $OIDC_ENV_FILE"
    exit 1
fi
if [ ! -f "$TLS_ENV_FILE" ]; then
    echo "ERROR: TLS env file not found: $TLS_ENV_FILE"
    exit 1
fi

set -a
source "$OIDC_ENV_FILE"
source "$TLS_ENV_FILE"
set +a

: "${OIDC_CLIENT_ID:?OIDC_CLIENT_ID missing from $OIDC_ENV_FILE}"
: "${OIDC_CLIENT_SECRET:?OIDC_CLIENT_SECRET missing from $OIDC_ENV_FILE}"
: "${OIDC_AUDIENCE:?OIDC_AUDIENCE missing from $OIDC_ENV_FILE}"

SIGNING_CERT_BASE64_VALUE="${SIGNING_CERT_BASE64:-${IDP_PRIVKEY_PEM:-}}"
: "${SIGNING_CERT_BASE64_VALUE:?SIGNING_CERT_BASE64 or IDP_PRIVKEY_PEM required}"

LINODE_TOKEN="$(head -n 1 "$LINODE_TOKEN_FILE")"
TMP_ENV_FILE="$(mktemp)"
cleanup() {
    rm -f "$TMP_ENV_FILE"
}
trap cleanup EXIT

cat > "$TMP_ENV_FILE" <<EOF
RUST_LOG=info
PORT=443
REDIRECT_URI=https://$FQDN/oauth2/callback
OIDC_AUDIENCE=$OIDC_AUDIENCE
OIDC_CLIENT_ID=$OIDC_CLIENT_ID
OIDC_CLIENT_SECRET=$OIDC_CLIENT_SECRET
SIGNING_CERT_BASE64=$SIGNING_CERT_BASE64_VALUE
EOF
chmod 600 "$TMP_ENV_FILE"

scp -o StrictHostKeyChecking=no "$TMP_ENV_FILE" root@"$SERVER_IP":/tmp/hyper-idp.env >/dev/null

echo "=== Setting up IDP server at $SERVER_IP ==="

ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" << ENDSSH
set -euo pipefail

echo "Installing dependencies..."
cat >/etc/pacman.d/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.theash.xyz/arch/\$repo/os/\$arch
Server = https://america.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch
EOF

pacman -Sy --noconfirm archlinux-keyring
rm -rf /usr/lib/firmware/nvidia
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
  base-devel \
  ca-certificates \
  curl \
  git \
  openssl \
  pkgconf \
  python

systemctl enable --now systemd-timesyncd
systemctl disable --now sshd.socket || true
systemctl enable --now sshd.service
systemctl restart sshd.service || true

# Install certbot + Linode DNS plugin in an isolated virtualenv so the host
# stays distro-managed while certbot remains current.
python -m venv /opt/certbot-venv
/opt/certbot-venv/bin/pip install --upgrade pip
/opt/certbot-venv/bin/pip install certbot certbot-dns-linode

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env

# Setup certbot credentials
mkdir -p /etc/letsencrypt
cat > /etc/letsencrypt/linode.ini << EOF
dns_linode_key = $LINODE_TOKEN
dns_linode_version = 4
EOF
chmod 600 /etc/letsencrypt/linode.ini

# Generate wildcard cert
echo "Generating TLS certificate..."
/opt/certbot-venv/bin/certbot certonly \
  --dns-linode \
  --dns-linode-credentials /etc/letsencrypt/linode.ini \
  --dns-linode-propagation-seconds 120 \
  -d "*.$DOMAIN_NAME" \
  -d "$DOMAIN_NAME" \
  --non-interactive \
  --agree-tos \
  -m admin@$DOMAIN_NAME

# Clone and build hyper-idp
echo "Building hyper-idp..."
mkdir -p /opt
cd /opt
git clone https://github.com/wavey-ai/hyper-idp.git
cd hyper-idp
CARGO_BUILD_JOBS=1 cargo build --release --bin hyper-idp

# Install binary
cp target/release/hyper-idp /usr/local/bin/
chmod +x /usr/local/bin/hyper-idp

# Create config directory
mkdir -p /etc/hyper-idp

# Create environment file from local secrets prepared by the deploy host
mv /tmp/hyper-idp.env /etc/hyper-idp/env

# Add TLS certs
CERT_PEM_BASE64=\$(base64 -w 0 /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem)
KEY_PEM_BASE64=\$(base64 -w 0 /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem)
echo "CERT_PEM_BASE64=\$CERT_PEM_BASE64" >> /etc/hyper-idp/env
echo "KEY_PEM_BASE64=\$KEY_PEM_BASE64" >> /etc/hyper-idp/env
chmod 600 /etc/hyper-idp/env

# Create systemd service
cat > /etc/systemd/system/hyper-idp.service << 'EOF'
[Unit]
Description=Hyper IDP SSO Server
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/hyper-idp/env
ExecStart=/usr/local/bin/hyper-idp
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/etc/letsencrypt
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

# Create cert renewal hook
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/hyper-idp.sh << 'HOOK'
#!/bin/bash
set -euo pipefail
DOMAIN_NAME="__DOMAIN_NAME__"
CERT_PEM_BASE64=\$(base64 -w 0 /etc/letsencrypt/live/\$DOMAIN_NAME/fullchain.pem)
KEY_PEM_BASE64=\$(base64 -w 0 /etc/letsencrypt/live/\$DOMAIN_NAME/privkey.pem)
sed -i '/CERT_PEM_BASE64=/d' /etc/hyper-idp/env
sed -i '/KEY_PEM_BASE64=/d' /etc/hyper-idp/env
echo "CERT_PEM_BASE64=\$CERT_PEM_BASE64" >> /etc/hyper-idp/env
echo "KEY_PEM_BASE64=\$KEY_PEM_BASE64" >> /etc/hyper-idp/env
systemctl restart hyper-idp
HOOK
sed -i "s/__DOMAIN_NAME__/$DOMAIN_NAME/" /etc/letsencrypt/renewal-hooks/deploy/hyper-idp.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/hyper-idp.sh

# Create cert renewal timer that uses the same isolated certbot install.
cat > /etc/systemd/system/hyper-idp-cert-renew.service << 'EOF'
[Unit]
Description=Renew Hyper IDP Let's Encrypt certificate

[Service]
Type=oneshot
ExecStart=/opt/certbot-venv/bin/certbot renew --quiet
EOF

cat > /etc/systemd/system/hyper-idp-cert-renew.timer << 'EOF'
[Unit]
Description=Twice-daily Hyper IDP certificate renewal check

[Timer]
OnCalendar=*-*-* 00,12:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Start service
systemctl daemon-reload
systemctl enable --now hyper-idp-cert-renew.timer
systemctl enable hyper-idp
systemctl start hyper-idp

echo "Setup complete!"
ENDSSH

echo ""
echo "=== Setup Complete ==="
echo "Server: $SERVER_IP"
echo "URL: https://$FQDN"
