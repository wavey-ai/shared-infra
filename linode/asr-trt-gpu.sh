#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_TOKEN_FILE="$HOME/.linode_wavey"
if [ -f "$REPO_ROOT/.linode-token" ]; then
    DEFAULT_TOKEN_FILE="$REPO_ROOT/.linode-token"
fi

LINODE_TOKEN_FILE="${LINODE_TOKEN_FILE:-$DEFAULT_TOKEN_FILE}"
REGION="${REGION:-de-fra-2}"
LINODE_TYPE="${LINODE_TYPE:-g2-gpu-rtx4000a1-m}"
LINODE_IMAGE="${LINODE_IMAGE:-linode/arch}"
LABEL="${LABEL:-asr-trt-gpu-01}"
DOMAIN_NAME="${DOMAIN_NAME:-wavey.ai}"
DOMAIN_ID="${DOMAIN_ID:-}"
SUBDOMAIN="${SUBDOMAIN:-}"
FQDN="${FQDN:-}"
IMAGE_LABEL="${IMAGE_LABEL:-$LABEL-base-$(date +%Y%m%d)}"

if [ -z "$FQDN" ] && [ -n "$SUBDOMAIN" ]; then
    FQDN="$SUBDOMAIN.$DOMAIN_NAME"
fi

if [ ! -f "$LINODE_TOKEN_FILE" ]; then
    echo "ERROR: Linode token file not found: $LINODE_TOKEN_FILE"
    exit 1
fi

export LINODE_CLI_TOKEN
LINODE_CLI_TOKEN="$(head -n 1 "$LINODE_TOKEN_FILE")"

usage() {
    cat <<EOF
Usage: $0 [create|destroy|status|ssh|logs|capture-image]

Commands:
  create         Create a dedicated Arch GPU node and run base TRT setup
  destroy        Destroy the node
  status         Show node status
  ssh            SSH into the node
  logs           Tail asr-api test service logs
  capture-image  Create a reusable custom image from the current node

Important env overrides:
  REGION=$REGION
  LINODE_TYPE=$LINODE_TYPE
  LABEL=$LABEL
  DOMAIN_ID=${DOMAIN_ID:-<unset>}
  SUBDOMAIN=${SUBDOMAIN:-<unset>}
  FQDN=${FQDN:-<unset>}
EOF
    exit 1
}

json_first() {
    jq -r '.[0] // empty'
}

get_linode_json() {
    linode-cli linodes list --label "$LABEL" --json 2>/dev/null
}

get_linode_id() {
    get_linode_json | jq -r '.[0].id // empty'
}

get_linode_ip() {
    get_linode_json | jq -r '.[0].ipv4[0] // empty'
}

get_dns_record_id() {
    if [ -z "$DOMAIN_ID" ] || [ -z "$SUBDOMAIN" ]; then
        return 0
    fi
    linode-cli domains records-list "$DOMAIN_ID" --json 2>/dev/null | \
        jq -r --arg name "$SUBDOMAIN" '.[] | select(.name == $name and .type == "A") | .id' | \
        head -n 1
}

upsert_dns_record() {
    local ip="$1"
    local record_id

    if [ -z "$DOMAIN_ID" ] || [ -z "$SUBDOMAIN" ]; then
        echo "Skipping DNS update; DOMAIN_ID/SUBDOMAIN not set"
        return 0
    fi

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
    local max_attempts=60

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
    local ssh_key
    local result
    local ip

    echo "=== Creating ASR TRT GPU Server ==="

    if [ -n "$(get_linode_id)" ]; then
        echo "Server '$LABEL' already exists"
        status
        exit 0
    fi

    ssh_key="$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || true)"
    if [ -z "$ssh_key" ]; then
        echo "ERROR: No SSH public key found"
        exit 1
    fi

    echo "Creating $LINODE_TYPE in $REGION..."
    result="$(linode-cli linodes create \
        --label "$LABEL" \
        --region "$REGION" \
        --type "$LINODE_TYPE" \
        --image "$LINODE_IMAGE" \
        --root_pass "$(openssl rand -base64 24)" \
        --authorized_keys "$ssh_key" \
        --json)"

    ip="$(echo "$result" | jq -r '.[0].ipv4[0]')"
    echo "Created server with IP: $ip"

    upsert_dns_record "$ip"

    echo "Waiting for SSH..."
    wait_for_ssh "$ip"

    echo "Running base TRT setup..."
    "$SCRIPT_DIR/asr-trt-gpu-setup.sh" "$ip"

    echo
    echo "=== ASR TRT GPU Server Created ==="
    echo "IP: $ip"
    if [ -n "$FQDN" ]; then
        echo "FQDN: $FQDN"
    fi
    echo "Type: $LINODE_TYPE"
}

destroy() {
    local linode_id
    local record_id

    echo "=== Destroying ASR TRT GPU Server ==="

    linode_id="$(get_linode_id)"
    if [ -z "$linode_id" ]; then
        echo "Server '$LABEL' not found"
        exit 0
    fi

    read -r -p "Are you sure you want to destroy $LABEL? [y/N] " confirm
    if [ "$confirm" != "y" ]; then
        echo "Aborted"
        exit 0
    fi

    record_id="$(get_dns_record_id)"
    if [ -n "$record_id" ]; then
        echo "Removing DNS record for $FQDN..."
        linode-cli domains records-delete "$DOMAIN_ID" "$record_id"
    fi

    echo "Deleting server..."
    linode-cli linodes delete "$linode_id"
}

status() {
    local linode_id
    local ip

    echo "=== ASR TRT GPU Server Status ==="

    linode_id="$(get_linode_id)"
    if [ -z "$linode_id" ]; then
        echo "Server '$LABEL' not found"
        exit 0
    fi

    linode-cli linodes view "$linode_id" --format "label,status,type,ipv4,region,image" --text

    ip="$(get_linode_ip)"
    if [ -n "$ip" ]; then
        echo
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ip" \
            "hostname; systemctl status asr-api-cohere-test.service --no-pager || true; nvidia-smi --query-gpu=name,memory.total --format=csv,noheader" \
            2>/dev/null || echo "Cannot connect to server"
    fi
}

do_ssh() {
    local ip
    ip="$(get_linode_ip)"
    if [ -z "$ip" ]; then
        echo "Server not found"
        exit 1
    fi
    ssh root@"$ip"
}

logs() {
    local ip
    ip="$(get_linode_ip)"
    if [ -z "$ip" ]; then
        echo "Server not found"
        exit 1
    fi
    ssh root@"$ip" "journalctl -u asr-api-cohere-test.service -f"
}

capture_image() {
    local linode_id
    local disk_id
    local create_args=()

    linode_id="$(get_linode_id)"
    if [ -z "$linode_id" ]; then
        echo "Server '$LABEL' not found"
        exit 1
    fi

    disk_id="$(linode-cli linodes disks-list "$linode_id" --json | jq -r '.[0].id // empty')"
    if [ -z "$disk_id" ]; then
        echo "ERROR: Could not determine root disk for $LABEL"
        exit 1
    fi

    echo "Creating custom image $IMAGE_LABEL from disk $disk_id..."
    create_args+=(--disk_id "$disk_id" --label "$IMAGE_LABEL" --description "Arch GPU TRT base from $LABEL")
    if [ "${IMAGE_CLOUD_INIT:-true}" = "true" ]; then
        create_args+=(--cloud_init)
    fi
    linode-cli images create "${create_args[@]}"
}

case "${1:-}" in
    create)         create ;;
    destroy)        destroy ;;
    status)         status ;;
    ssh)            do_ssh ;;
    logs)           logs ;;
    capture-image)  capture_image ;;
    *)              usage ;;
esac
