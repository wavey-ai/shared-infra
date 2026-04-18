#!/bin/bash
set -euo pipefail

# IDP Server Deployment Script for Linode
# Usage: ./idp.sh [create|destroy|status]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_TOKEN_FILE="$HOME/.linode_wavey"
if [ -f "$REPO_ROOT/.linode-token" ]; then
    DEFAULT_TOKEN_FILE="$REPO_ROOT/.linode-token"
fi

LINODE_TOKEN_FILE="${LINODE_TOKEN_FILE:-$DEFAULT_TOKEN_FILE}"
REGION="${REGION:-gb-lon}"
LINODE_TYPE="${LINODE_TYPE:-g6-dedicated-2}"
LINODE_IMAGE="${LINODE_IMAGE:-linode/arch}"
LABEL="${LABEL:-idp-wavey-io}"
DOMAIN_NAME="${DOMAIN_NAME:-wavey.io}"
DOMAIN_ID="${DOMAIN_ID:-2958920}"
SUBDOMAIN="${SUBDOMAIN:-idp}"
FQDN="${FQDN:-$SUBDOMAIN.$DOMAIN_NAME}"

if [ ! -f "$LINODE_TOKEN_FILE" ]; then
    echo "ERROR: Linode token file not found: $LINODE_TOKEN_FILE"
    exit 1
fi

export LINODE_CLI_TOKEN
LINODE_CLI_TOKEN="$(head -n 1 "$LINODE_TOKEN_FILE")"

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

get_dns_record_id() {
    linode-cli domains records-list "$DOMAIN_ID" --json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(next((r['id'] for r in d if r.get('name')=='$SUBDOMAIN' and r.get('type')=='A'), ''))" 2>/dev/null
}

upsert_dns_record() {
    local ip="$1"
    local record_id

    record_id="$(get_dns_record_id)"
    if [ -n "$record_id" ]; then
        echo "Updating DNS record for $FQDN -> $ip..."
        linode-cli domains records-update "$DOMAIN_ID" "$record_id" \
            --target "$ip" \
            --ttl_sec 300 >/dev/null
    else
        echo "Creating DNS record for $FQDN -> $ip..."
        linode-cli domains records-create "$DOMAIN_ID" \
            --type A \
            --name "$SUBDOMAIN" \
            --target "$ip" \
            --ttl_sec 300 >/dev/null
    fi
}

wait_for_ssh() {
    local ip="$1"
    local attempt=0
    local max_attempts=30

    until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ip" "echo ok" >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "ERROR: Timed out waiting for SSH on $ip"
            return 1
        fi
        sleep 5
    done
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

    upsert_dns_record "$IP"

    echo "Waiting for server to accept SSH..."
    wait_for_ssh "$IP"

    # Run setup script
    echo "Running server setup..."
    DOMAIN_NAME="$DOMAIN_NAME" \
    SUBDOMAIN="$SUBDOMAIN" \
    FQDN="$FQDN" \
    LINODE_TOKEN_FILE="$LINODE_TOKEN_FILE" \
    "$SCRIPT_DIR/idp-setup.sh" "$IP"

    echo ""
    echo "=== IDP Server Created ==="
    echo "IP: $IP"
    echo "URL: https://$FQDN"
    echo ""
    echo "Don't forget to add callback URL to Auth0:"
    echo "  https://$FQDN/oauth2/callback"
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
    RECORD_ID="$(get_dns_record_id)"
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
