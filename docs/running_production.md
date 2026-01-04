# Running Safe Infrastructure for Production

This guide covers deploying Safe infrastructure to a production environment using the automated deployment tooling.

## Prerequisites

- Docker Engine 20.10+ with Docker Compose V2
- curl
- openssl
- At least 16GB RAM recommended (8GB minimum)
- 50GB+ disk space for databases

## Quick Start

```bash
# 1. Clone the repository
git clone <repository-url>
cd safe-infrastructure

# 2. Create and configure deploy.conf
cp deploy.conf.example deploy.conf

# 3. Edit the configuration
vim deploy.conf  # Set RPC_NODE_URL, DOMAIN, etc.

# 4. Deploy
./deploy.sh up
```

## Configuration

Edit `deploy.conf` with your environment settings:

```bash
# Network configuration
DOMAIN=safe.yourdomain.com
PORT=8000

# Blockchain configuration
RPC_NODE_URL=https://mainnet.infura.io/v3/YOUR_KEY
CHAIN_ID=1
CHAIN_NAME="Ethereum Mainnet"

# Service versions (pin for production stability)
CFG_VERSION=v2.60.0
CGW_VERSION=v0.4.1
TXS_VERSION=v4.6.1
UI_VERSION=v1.2.0
EVENTS_VERSION=v0.5.0
```

### Required Configuration

| Variable | Description |
|----------|-------------|
| `RPC_NODE_URL` | Full RPC endpoint URL for your target chain |
| `CHAIN_ID` | Numeric chain ID (1 for Mainnet, 137 for Polygon, etc.) |
| `CHAIN_NAME` | Human-readable chain name |

### Optional Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `DOMAIN` | Domain/hostname for services | `localhost` |
| `PORT` | Port for reverse proxy | `8000` |
| `INFURA_TOKEN` | Infura token for UI | (empty) |
| `TENDERLY_*` | Tenderly integration for tx simulation | (empty) |

## Deployment Commands

```bash
./deploy.sh up        # Full deployment
./deploy.sh down      # Stop all services
./deploy.sh status    # Health check all services
./deploy.sh logs      # Tail all logs
./deploy.sh logs txs-web  # Tail specific service logs
./deploy.sh reset     # Full reset (WARNING: deletes all data)
```

## What Happens During Deployment

1. **Environment Generation**: Secure secrets are generated and env files created
2. **Image Pull**: Docker images are pulled from Docker Hub
3. **Service Start**: Containers start with proper dependency ordering
4. **Health Checks**: Script waits for all services to be healthy
5. **Admin Users**: Django superusers are created automatically
6. **Chain Seeding**: Chain configuration template is prepared
7. **Validation**: All endpoints are checked for availability

## Post-Deployment Steps

### 1. Access Admin Credentials

After deployment, credentials are saved to `.credentials`:

```bash
cat .credentials
```

### 2. Configure Chain in Admin Panel

1. Open Config Service Admin: `http://<DOMAIN>:<PORT>/cfg/admin`
2. Login with credentials from `.credentials`
3. Navigate to **Chains** > **Add Chain**
4. Fill in the chain details (a template is prepared in `.chain_<CHAIN_ID>.json`)

Key fields:
- **Chain ID**: Must match your `CHAIN_ID` in deploy.conf
- **Transaction Service URI**: `http://nginx:8000/txs`
- **VPC Transaction Service URI**: `http://nginx:8000/txs`

### 3. Configure Webhooks

For the Events Service to notify the Client Gateway:

1. Open Events Admin: `http://<DOMAIN>:<PORT>/events/admin`
2. Create a new Webhook:
   - URL: `http://nginx:8000/cgw/v1/hooks/events`
   - Authorization: `Basic <AUTH_TOKEN>` (from `.credentials` or `cgw.env`)
   - Enable all event types

## Resource Requirements

### Transaction Service (per chain)

| Network | Service CPU/RAM | Database CPU/RAM |
|---------|-----------------|------------------|
| Mainnet | 8 vCPU / 32GB | 8 cores / 64GB |
| Polygon | 4 vCPU / 16GB | 4 cores / 16GB |
| Gnosis Chain | 4 vCPU / 16GB | 4 cores / 16GB |
| Testnets | 4 vCPU / 16GB | 2 cores / 8GB |

### Other Services

| Service | CPU | RAM |
|---------|-----|-----|
| Client Gateway | 2 vCPU | 8GB |
| Config Service | 2 vCPU | 8GB |
| Config Database | 2 vCPU | 8GB |

## Production Hardening

### 1. Use a Reverse Proxy with TLS

Place nginx or Traefik in front with HTTPS:

```nginx
server {
    listen 443 ssl;
    server_name safe.yourdomain.com;
    
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    
    location / {
        proxy_pass http://localhost:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 2. Secure Credentials

```bash
# Restrict access to credentials file
chmod 600 .credentials

# Consider using Docker secrets or external secret management
# for production deployments
```

### 3. Database Backups

```bash
# Backup all databases
docker compose exec txs-db pg_dump -U postgres postgres > backup_txs.sql
docker compose exec cfg-db pg_dump -U postgres postgres > backup_cfg.sql
docker compose exec cgw-db pg_dump -U postgres postgres > backup_cgw.sql
docker compose exec events-db pg_dump -U postgres postgres > backup_events.sql
```

### 4. Monitoring

Use the included monitoring compose file:

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

This adds Flower for Celery monitoring at port 5555.

## Troubleshooting

### Check Service Health

```bash
./deploy.sh status
```

### View Logs

```bash
# All services
./deploy.sh logs

# Specific service
docker compose logs -f txs-web
docker compose logs -f cfg-web
```

### Common Issues

**Services not starting:**
- Check Docker has enough resources allocated
- Verify RPC_NODE_URL is accessible
- Check `docker compose ps` for error states

**Chain not appearing in UI:**
- Verify chain is configured in Config Service admin
- Check `transactionService` URL is `http://nginx:8000/txs`
- Restart Client Gateway: `docker compose restart cgw-web`

**Transaction indexing not working:**
- Check txs-worker-indexer logs: `docker compose logs txs-worker-indexer`
- Verify RPC endpoint is responsive
- Check Safe contracts are deployed on target chain

## Multi-Chain Setup

For multiple chains, you need one Transaction Service instance per chain. The recommended approach:

1. Deploy a base infrastructure with Config Service and Client Gateway
2. For each additional chain, deploy a separate Transaction Service stack
3. Register each Transaction Service URL in the Config Service

See the [chain_templates/](../chain_templates/) directory for pre-configured chain JSON files.

## Upgrading

```bash
# Update versions in deploy.conf
vim deploy.conf

# Pull new images and restart
docker compose pull
docker compose up -d
```

For major version upgrades, check the release notes of each service for migration steps.
