#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${ROOT_DIR}/deploy.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

DOMAIN="${DOMAIN:-localhost}"
PORT="${PORT:-8000}"
BASE_URL="http://${DOMAIN}:${PORT}"

passed=0
failed=0
warnings=0

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((passed++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((failed++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((warnings++))
}

check_container() {
    local name=$1
    local status
    status=$(docker compose ps --format json "$name" 2>/dev/null | grep -o '"State":"[^"]*"' | cut -d'"' -f4 || echo "not found")
    
    if [[ "$status" == "running" ]]; then
        check_pass "Container $name is running"
        return 0
    else
        check_fail "Container $name is not running (status: $status)"
        return 1
    fi
}

check_container_healthy() {
    local name=$1
    local health
    health=$(docker compose ps --format json "$name" 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    
    if [[ "$health" == "healthy" ]]; then
        check_pass "Container $name is healthy"
        return 0
    elif [[ "$health" == "unknown" || -z "$health" ]]; then
        check_warn "Container $name health status unknown (no healthcheck defined)"
        return 0
    else
        check_fail "Container $name is unhealthy (health: $health)"
        return 1
    fi
}

check_http() {
    local name=$1
    local url=$2
    local expected_code=${3:-200}
    local actual_code
    
    actual_code=$(curl -sf -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    
    if [[ "$actual_code" == "$expected_code" ]]; then
        check_pass "$name endpoint responding (HTTP $actual_code)"
        return 0
    elif [[ "$actual_code" == "000" ]]; then
        check_fail "$name endpoint not reachable at $url"
        return 1
    else
        check_warn "$name endpoint returned HTTP $actual_code (expected $expected_code)"
        return 0
    fi
}

check_db() {
    local name=$1
    local container=$2
    
    if docker compose exec -T "$container" pg_isready -U postgres &>/dev/null; then
        check_pass "$name database is accepting connections"
        return 0
    else
        check_fail "$name database is not accepting connections"
        return 1
    fi
}

echo ""
echo "=== Safe Infrastructure Health Check ==="
echo "Base URL: ${BASE_URL}"
echo ""

echo "--- Container Status ---"
containers=("nginx" "cfg-web" "cfg-db" "cgw-web" "cgw-redis" "cgw-db" "txs-web" "txs-db" "txs-redis" "txs-rabbitmq" "txs-worker-indexer" "txs-scheduler" "events-web" "events-db" "general-rabbitmq" "ui")
for container in "${containers[@]}"; do
    check_container "$container" || true
done

echo ""
echo "--- Database Health ---"
check_db "Config Service" "cfg-db" || true
check_db "Transaction Service" "txs-db" || true
check_db "Client Gateway" "cgw-db" || true
check_db "Events Service" "events-db" || true

echo ""
echo "--- HTTP Endpoints ---"
check_http "Nginx (reverse proxy)" "${BASE_URL}/" || true
check_http "Config Service API" "${BASE_URL}/cfg/api/v1/chains/" || true
check_http "Transaction Service API" "${BASE_URL}/txs/api/v1/about/" || true
check_http "Client Gateway API" "${BASE_URL}/cgw/health" || true
check_http "Events Service" "${BASE_URL}/events/health" || true

echo ""
echo "--- Service Health Checks ---"
check_container_healthy "cfg-db" || true
check_container_healthy "txs-db" || true
check_container_healthy "cgw-db" || true
check_container_healthy "events-db" || true
check_container_healthy "txs-redis" || true
check_container_healthy "cgw-redis" || true

echo ""
echo "=== Summary ==="
echo -e "Passed:   ${GREEN}${passed}${NC}"
echo -e "Failed:   ${RED}${failed}${NC}"
echo -e "Warnings: ${YELLOW}${warnings}${NC}"
echo ""

if [[ $failed -gt 0 ]]; then
    echo -e "${RED}Some checks failed. Review the output above for details.${NC}"
    exit 1
elif [[ $warnings -gt 0 ]]; then
    echo -e "${YELLOW}All critical checks passed with some warnings.${NC}"
    exit 0
else
    echo -e "${GREEN}All checks passed!${NC}"
    exit 0
fi

