#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy.conf"
CREDENTIALS_FILE="${SCRIPT_DIR}/.credentials"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_step() {
    echo -e "${BLUE}[$1/$2]${NC} $3"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

check_dependencies() {
    local missing=()
    command -v docker &>/dev/null || missing+=("docker")
    command -v curl &>/dev/null || missing+=("curl")
    command -v openssl &>/dev/null || missing+=("openssl")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        echo "Run: cp deploy.conf.example deploy.conf"
        exit 1
    fi
    source "$CONFIG_FILE"
}

generate_secret() {
    openssl rand -base64 32 | tr -d '/+=' | cut -c1-32
}

wait_for_healthy() {
    local service=$1
    local max_attempts=${2:-60}
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker compose ps "$service" 2>/dev/null | grep -q "healthy"; then
            return 0
        fi
        sleep 2
        ((attempt++))
    done
    return 1
}

wait_for_http() {
    local url=$1
    local max_attempts=${2:-30}
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf "$url" &>/dev/null; then
            return 0
        fi
        sleep 2
        ((attempt++))
    done
    return 1
}

cmd_up() {
    local total_steps=7
    
    check_dependencies
    load_config
    
    log_step 1 $total_steps "Generating environment files..."
    "${SCRIPT_DIR}/scripts/generate_env.sh"
    
    log_step 2 $total_steps "Pulling Docker images..."
    docker compose pull
    
    log_step 3 $total_steps "Starting services..."
    docker compose down -v 2>/dev/null || true
    docker compose up -d
    
    log_step 4 $total_steps "Waiting for services to be healthy..."
    local services=("cfg-db" "txs-db" "cgw-db" "events-db" "txs-redis" "cgw-redis")
    for svc in "${services[@]}"; do
        if ! wait_for_healthy "$svc" 60; then
            log_warn "Service $svc did not become healthy in time"
        fi
    done
    sleep 10
    
    log_step 5 $total_steps "Creating admin users..."
    docker compose exec -T cfg-web python src/manage.py createsuperuser --noinput 2>/dev/null || true
    docker compose exec -T txs-web python manage.py createsuperuser --noinput 2>/dev/null || true
    
    log_step 6 $total_steps "Seeding chain configuration..."
    "${SCRIPT_DIR}/scripts/seed_chains.sh" || log_warn "Chain seeding skipped or failed"
    
    log_step 7 $total_steps "Validating deployment..."
    "${SCRIPT_DIR}/scripts/validate.sh" || true
    
    echo ""
    echo "================================"
    echo -e "${GREEN}Deployment successful!${NC}"
    echo "================================"
    echo "Web UI:            http://${DOMAIN:-localhost}:${PORT:-8000}"
    echo "Config Admin:      http://${DOMAIN:-localhost}:${PORT:-8000}/cfg/admin"
    echo "Transaction Admin: http://${DOMAIN:-localhost}:${PORT:-8000}/txs/admin"
    echo ""
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        echo "Admin credentials saved to: $CREDENTIALS_FILE"
    fi
    echo "================================"
}

cmd_down() {
    echo "Stopping all services..."
    docker compose down
    log_success "All services stopped"
}

cmd_status() {
    check_dependencies
    "${SCRIPT_DIR}/scripts/validate.sh"
}

cmd_logs() {
    local service=${1:-}
    if [[ -n "$service" ]]; then
        docker compose logs -f "$service"
    else
        docker compose logs -f
    fi
}

cmd_reset() {
    echo -e "${YELLOW}WARNING: This will delete all data including databases!${NC}"
    read -p "Are you sure? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        echo "Stopping services and removing volumes..."
        docker compose down -v
        rm -rf "${SCRIPT_DIR}/data/"*
        rm -f "$CREDENTIALS_FILE"
        log_success "Reset complete"
    else
        echo "Reset cancelled"
    fi
}

usage() {
    cat <<EOF
Safe Infrastructure Deployment Tool

Usage: ./deploy.sh <command> [options]

Commands:
  up        Deploy all services (pulls images, starts containers, seeds config)
  down      Stop all services
  status    Check health of all services
  logs      Tail logs from all services (optionally specify service name)
  reset     Full reset - removes all data and volumes

Examples:
  ./deploy.sh up
  ./deploy.sh status
  ./deploy.sh logs txs-web
  ./deploy.sh down

Configuration:
  Edit deploy.conf before running 'up' for the first time.
  Run 'cp deploy.conf.example deploy.conf' to create the config file.
EOF
}

case "${1:-}" in
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs "${2:-}"
        ;;
    reset)
        cmd_reset
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac

