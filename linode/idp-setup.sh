#!/bin/bash
set -e

# Server setup script for IDP
# Usage: ./idp-setup.sh <server-ip>

SERVER_IP="${1:?Usage: $0 <server-ip>}"
LINODE_TOKEN_FILE="${LINODE_TOKEN_FILE:-$HOME/.linode_wavey}"
LINODE_TOKEN=$(cat "$LINODE_TOKEN_FILE" | head -1)

# Object storage credentials
OBJ_ACCESS_KEY="${OBJ_ACCESS_KEY:-B74BMOQGUKE0M52WEFSV}"
OBJ_SECRET_KEY="${OBJ_SECRET_KEY:?OBJ_SECRET_KEY required}"

echo "=== Setting up IDP server at $SERVER_IP ==="

ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" << ENDSSH
set -e

echo "Installing dependencies..."
dnf install -y epel-release
dnf install -y certbot python3-pip gcc git openssl-devel awscli2

# Install certbot Linode DNS plugin
pip3 install certbot-dns-linode

# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env

# Configure AWS CLI for Object Storage
mkdir -p ~/.aws
cat > ~/.aws/config << 'EOF'
[default]
s3 =
    endpoint_url = https://gb-lon-1.linodeobjects.com
EOF

cat > ~/.aws/credentials << EOF
[default]
aws_access_key_id = $OBJ_ACCESS_KEY
aws_secret_access_key = $OBJ_SECRET_KEY
EOF
chmod 600 ~/.aws/credentials

# Setup certbot credentials
mkdir -p /etc/letsencrypt
cat > /etc/letsencrypt/linode.ini << EOF
dns_linode_key = $LINODE_TOKEN
dns_linode_version = 4
EOF
chmod 600 /etc/letsencrypt/linode.ini

# Generate wildcard cert
echo "Generating TLS certificate..."
certbot certonly \
  --dns-linode \
  --dns-linode-credentials /etc/letsencrypt/linode.ini \
  --dns-linode-propagation-seconds 120 \
  -d "*.wavey.io" \
  -d "wavey.io" \
  --non-interactive \
  --agree-tos \
  -m admin@wavey.io

# Enable cert auto-renewal
systemctl enable --now certbot-renew.timer

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

# Create environment file
cat > /etc/hyper-idp/env << 'EOF'
RUST_LOG=info
PORT=443
REDIRECT_URI=https://idp.wavey.io/oauth2/callback
EOF

# Get OIDC config from Object Storage
aws s3 cp s3://wavey-creds/oidc/config.env /tmp/oidc.env --endpoint-url https://gb-lon-1.linodeobjects.com
cat /tmp/oidc.env >> /etc/hyper-idp/env
rm /tmp/oidc.env

# Add TLS certs
CERT_PEM_BASE64=\$(base64 -w 0 /etc/letsencrypt/live/wavey.io/fullchain.pem)
KEY_PEM_BASE64=\$(base64 -w 0 /etc/letsencrypt/live/wavey.io/privkey.pem)
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
CERT_PEM_BASE64=\$(base64 -w 0 /etc/letsencrypt/live/wavey.io/fullchain.pem)
KEY_PEM_BASE64=\$(base64 -w 0 /etc/letsencrypt/live/wavey.io/privkey.pem)
sed -i '/CERT_PEM_BASE64=/d' /etc/hyper-idp/env
sed -i '/KEY_PEM_BASE64=/d' /etc/hyper-idp/env
echo "CERT_PEM_BASE64=\$CERT_PEM_BASE64" >> /etc/hyper-idp/env
echo "KEY_PEM_BASE64=\$KEY_PEM_BASE64" >> /etc/hyper-idp/env
systemctl restart hyper-idp
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/hyper-idp.sh

# Open firewall port
firewall-cmd --add-port=443/tcp --permanent
firewall-cmd --reload

# Start service
systemctl daemon-reload
systemctl enable hyper-idp
systemctl start hyper-idp

echo "Setup complete!"
ENDSSH

echo ""
echo "=== Setup Complete ==="
echo "Server: $SERVER_IP"
echo "URL: https://idp.wavey.io"
