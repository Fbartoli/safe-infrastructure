#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/deploy.conf"
TEMPLATES_DIR="${ROOT_DIR}/chain_templates"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

CFG_BASE_URL="http://${DOMAIN:-localhost}:${PORT:-8000}/cfg"
CFG_API_URL="${CFG_BASE_URL}/api/v1"
CFG_ADMIN_URL="${CFG_BASE_URL}/admin"

CREDENTIALS_FILE="${ROOT_DIR}/.credentials"
if [[ -f "$CREDENTIALS_FILE" ]]; then
    ADMIN_PASSWORD=$(grep -A2 "Config Service Admin:" "$CREDENTIALS_FILE" | grep "Password:" | awk '{print $2}')
else
    ADMIN_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-admin}"
fi

wait_for_service() {
    local url=$1
    local max_attempts=${2:-30}
    local attempt=0
    
    echo "Waiting for Config Service to be ready..."
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf "${url}/api/v1/chains/" &>/dev/null; then
            echo "Config Service is ready"
            return 0
        fi
        sleep 2
        ((attempt++))
    done
    echo "Error: Config Service did not become ready"
    return 1
}

get_csrf_token() {
    local cookie_jar=$1
    curl -sf -c "$cookie_jar" -b "$cookie_jar" "${CFG_ADMIN_URL}/login/" | \
        grep -o 'csrfmiddlewaretoken" value="[^"]*"' | \
        sed 's/csrfmiddlewaretoken" value="//;s/"$//' || echo ""
}

admin_login() {
    local cookie_jar=$1
    local csrf_token
    
    csrf_token=$(get_csrf_token "$cookie_jar")
    if [[ -z "$csrf_token" ]]; then
        echo "Warning: Could not get CSRF token for admin login"
        return 1
    fi
    
    curl -sf -c "$cookie_jar" -b "$cookie_jar" \
        -X POST "${CFG_ADMIN_URL}/login/" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Referer: ${CFG_ADMIN_URL}/login/" \
        -d "csrfmiddlewaretoken=${csrf_token}&username=root&password=${ADMIN_PASSWORD}" \
        -o /dev/null
}

check_chain_exists() {
    local chain_id=$1
    curl -sf "${CFG_API_URL}/chains/${chain_id}/" &>/dev/null
}

create_chain_from_template() {
    local template_file=$1
    local rpc_url=${2:-}
    
    if [[ ! -f "$template_file" ]]; then
        echo "Error: Template file not found: $template_file"
        return 1
    fi
    
    local chain_data
    chain_data=$(cat "$template_file")
    
    if [[ -n "$rpc_url" ]]; then
        chain_data=$(echo "$chain_data" | sed "s|RPC_URL|${rpc_url}|g")
    fi
    
    echo "$chain_data"
}

seed_chain() {
    local chain_id=$1
    local chain_name=$2
    local rpc_url=$3
    
    if check_chain_exists "$chain_id"; then
        echo "Chain ${chain_id} (${chain_name}) already exists, skipping..."
        return 0
    fi
    
    local template_file="${TEMPLATES_DIR}/${chain_id}_*.json"
    template_file=$(ls $template_file 2>/dev/null | head -1 || echo "")
    
    if [[ -z "$template_file" || ! -f "$template_file" ]]; then
        template_file="${TEMPLATES_DIR}/template.json"
        echo "Using generic template for chain ${chain_id}"
    fi
    
    local chain_data
    chain_data=$(cat "$template_file")
    
    chain_data=$(echo "$chain_data" | sed "s|\"chainId\": \"[^\"]*\"|\"chainId\": \"${chain_id}\"|g")
    chain_data=$(echo "$chain_data" | sed "s|\"chainName\": \"[^\"]*\"|\"chainName\": \"${chain_name}\"|g")
    chain_data=$(echo "$chain_data" | sed "s|CHAIN_ID|${chain_id}|g")
    chain_data=$(echo "$chain_data" | sed "s|CHAIN_NAME|${chain_name}|g")
    
    if [[ -n "$rpc_url" ]]; then
        local escaped_rpc_url=$(echo "$rpc_url" | sed 's/[&/\]/\\&/g')
        chain_data=$(echo "$chain_data" | sed "s|RPC_URL|${escaped_rpc_url}|g")
        chain_data=$(echo "$chain_data" | sed "s|https://mainnet.infura.io/v3/|${escaped_rpc_url}|g")
    fi
    
    echo "Chain configuration prepared for ${chain_name} (ID: ${chain_id})"
    echo "Note: Chain must be added via Admin UI at ${CFG_ADMIN_URL}/chains/chain/add/"
    echo ""
    echo "Pre-configured template saved to: ${ROOT_DIR}/.chain_${chain_id}.json"
    echo "$chain_data" > "${ROOT_DIR}/.chain_${chain_id}.json"
    
    return 0
}

main() {
    wait_for_service "$CFG_BASE_URL" 60 || exit 1
    
    CHAIN_ID="${CHAIN_ID:-1}"
    CHAIN_NAME="${CHAIN_NAME:-Ethereum Mainnet}"
    RPC_URL="${RPC_NODE_URL:-}"
    
    echo ""
    echo "=== Chain Configuration ==="
    echo "Chain ID: ${CHAIN_ID}"
    echo "Chain Name: ${CHAIN_NAME}"
    echo "RPC URL: ${RPC_URL}"
    echo ""
    
    seed_chain "$CHAIN_ID" "$CHAIN_NAME" "$RPC_URL"
    
    echo ""
    echo "=== Next Steps ==="
    echo "1. Open the Config Service Admin: ${CFG_ADMIN_URL}"
    echo "2. Login with username 'root' and password from .credentials file"
    echo "3. Navigate to Chains > Add Chain"
    echo "4. Import the configuration from .chain_${CHAIN_ID}.json or enter manually"
    echo ""
    echo "Key fields to set:"
    echo "  - Chain ID: ${CHAIN_ID}"
    echo "  - Chain Name: ${CHAIN_NAME}"
    echo "  - Transaction Service URI: http://nginx:8000/txs"
    echo "  - VPC Transaction Service URI: http://nginx:8000/txs"
    echo ""
}

main "$@"

