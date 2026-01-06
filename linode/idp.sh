#!/bin/bash
set -e

# IDP Server Deployment Script for Linode
# Usage: ./idp.sh [create|destroy|status]

LINODE_TOKEN_FILE="${LINODE_TOKEN_FILE:-$HOME/.linode_wavey}"
REGION="gb-lon"
LINODE_TYPE="g6-nanode-1"
LINODE_IMAGE="linode/rocky9"
LABEL="idp-wavey-io"
DOMAIN_ID="2958920"  # wavey.io domain
BUCKET_NAME="wavey-creds"
BUCKET_REGION="gb-lon-1"

# Object Storage credentials (set these or use env vars)
OBJ_ACCESS_KEY="${OBJ_ACCESS_KEY:-B74BMOQGUKE0M52WEFSV}"

export LINODE_CLI_TOKEN=$(cat "$LINODE_TOKEN_FILE" | head -1)

usage() {
    echo "Usage: $0 [create|destroy|status|ssh|logs]"
    echo ""
    echo "Commands:"
    echo "  create  - Create IDP server and configure"
    echo "  destroy - Destroy IDP server"
    echo "  status  - Show server status"
    echo "  ssh     - SSH into server"
    echo "  logs    - Show service logs"
    exit 1
}

get_linode_id() {
    linode-cli linodes list --label "$LABEL" --json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null
}

get_linode_ip() {
    linode-cli linodes list --label "$LABEL" --json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['ipv4'][0] if d else '')" 2>/dev/null
}

create() {
    echo "=== Creating IDP Server ==="

    # Check if already exists
    if [ -n "$(get_linode_id)" ]; then
        echo "Server '$LABEL' already exists"
        status
        exit 0
    fi

    # Get SSH key
    SSH_KEY=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null)
    if [ -z "$SSH_KEY" ]; then
        echo "ERROR: No SSH public key found"
        exit 1
    fi

    # Create Linode
    echo "Creating Linode in $REGION..."
    RESULT=$(linode-cli linodes create \
        --label "$LABEL" \
        --region "$REGION" \
        --type "$LINODE_TYPE" \
        --image "$LINODE_IMAGE" \
        --root_pass "$(openssl rand -base64 24)" \
        --authorized_keys "$SSH_KEY" \
        --json)

    IP=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['ipv4'][0])")
    echo "Created server with IP: $IP"

    # Create DNS record
    echo "Creating DNS record for idp.wavey.io..."
    linode-cli domains records-create "$DOMAIN_ID" \
        --type A \
        --name idp \
        --target "$IP" \
        --ttl_sec 300

    echo "Waiting for server to boot..."
    sleep 60

    # Run setup script
    echo "Running server setup..."
    ./idp-setup.sh "$IP"

    echo ""
    echo "=== IDP Server Created ==="
    echo "IP: $IP"
    echo "URL: https://idp.wavey.io"
    echo ""
    echo "Don't forget to add callback URL to Auth0:"
    echo "  https://idp.wavey.io/oauth2/callback"
}

destroy() {
    echo "=== Destroying IDP Server ==="

    LINODE_ID=$(get_linode_id)
    if [ -z "$LINODE_ID" ]; then
        echo "Server '$LABEL' not found"
        exit 0
    fi

    read -p "Are you sure you want to destroy $LABEL? [y/N] " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 0
    fi

    # Delete DNS record
    echo "Removing DNS record..."
    RECORD_ID=$(linode-cli domains records-list "$DOMAIN_ID" --json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(next((r['id'] for r in d if r['name']=='idp'), ''))")
    if [ -n "$RECORD_ID" ]; then
        linode-cli domains records-delete "$DOMAIN_ID" "$RECORD_ID"
    fi

    # Delete Linode
    echo "Deleting server..."
    linode-cli linodes delete "$LINODE_ID"

    echo "Server destroyed"
}

status() {
    echo "=== IDP Server Status ==="

    LINODE_ID=$(get_linode_id)
    if [ -z "$LINODE_ID" ]; then
        echo "Server '$LABEL' not found"
        exit 0
    fi

    linode-cli linodes view "$LINODE_ID" --format "label,status,ipv4,region" --text

    IP=$(get_linode_ip)
    echo ""
    echo "Service status:"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" \
        "systemctl status hyper-idp --no-pager" 2>/dev/null || echo "Cannot connect to server"
}

do_ssh() {
    IP=$(get_linode_ip)
    if [ -z "$IP" ]; then
        echo "Server not found"
        exit 1
    fi
    ssh root@"$IP"
}

logs() {
    IP=$(get_linode_ip)
    if [ -z "$IP" ]; then
        echo "Server not found"
        exit 1
    fi
    ssh root@"$IP" "journalctl -u hyper-idp -f"
}

case "${1:-}" in
    create)  create ;;
    destroy) destroy ;;
    status)  status ;;
    ssh)     do_ssh ;;
    logs)    logs ;;
    *)       usage ;;
esac
