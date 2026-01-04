# Deploying Safe Infrastructure with Coolify

This guide covers deploying Safe infrastructure using [Coolify](https://coolify.io), a self-hosted PaaS that simplifies Docker deployments with automatic SSL, monitoring, and updates.

## Prerequisites

- A server with Coolify installed ([installation guide](https://coolify.io/docs/get-started/installation))
- A domain pointing to your Coolify server (or use Coolify's sslip.io domains)
- An RPC endpoint for your target blockchain

## Quick Start

### 1. Add the Repository

1. In Coolify, go to **Projects** → **Add New Project**
2. Add a new **Resource** → **Docker Compose**
3. Select **GitHub** and connect to `Fbartoli/safe-infrastructure` (or your fork)
4. Set the **Docker Compose file** to `docker-compose.coolify.yml`

### 2. Configure Environment Variables

In Coolify's **Environment Variables** section, add these required variables:

```env
# Required - Blockchain
RPC_NODE_URL=https://mainnet.infura.io/v3/YOUR_KEY

# Required - Security (generate unique values!)
DJANGO_SECRET_KEY=<run: openssl rand -base64 32>
CGW_AUTH_TOKEN=<run: openssl rand -base64 32>
POSTGRES_PASSWORD=<secure-password>
ADMIN_PASSWORD=<admin-password>

# Required - URLs (Coolify will provide these via SERVICE_FQDN_*)
PUBLIC_URL=https://your-domain.com
CSRF_TRUSTED_ORIGINS=https://your-domain.com
MEDIA_URL=https://your-domain.com/cfg/media/
```

### 3. Configure Domains

In Coolify's **Domains** tab:
- Set the primary domain for the `nginx` service
- Coolify will automatically provision SSL via Let's Encrypt

### 4. Deploy

Click **Deploy** and wait for all services to start (this may take 5-10 minutes on first deploy).

## Post-Deployment Setup

### Create Admin Users

After deployment, exec into the containers to create superusers:

```bash
# Config Service
docker exec -it <cfg-web-container> python src/manage.py createsuperuser --noinput

# Transaction Service
docker exec -it <txs-web-container> python manage.py createsuperuser --noinput
```

Or use Coolify's **Terminal** feature for each service.

### Configure Chain

1. Access Config Service admin: `https://your-domain.com/cfg/admin`
2. Login with your admin credentials
3. Go to **Chains** → **Add Chain**
4. Key fields:
   - Chain ID: Your chain's ID (1 for Mainnet)
   - Chain Name: Display name
   - Transaction Service URI: `http://nginx:8000/txs`
   - VPC Transaction Service URI: `http://nginx:8000/txs`

### Configure Webhooks

1. Access Events Service admin: `https://your-domain.com/events/admin`
2. Create a webhook:
   - URL: `http://nginx:8000/cgw/v1/hooks/events`
   - Authorization: `Basic <your-CGW_AUTH_TOKEN>`
   - Enable all event types

## Architecture with Coolify

```
┌─────────────────────────────────────────────────────────────┐
│                        Coolify Server                        │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────┐                                                │
│  │ Traefik │ ← SSL termination, routing                     │
│  └────┬────┘                                                │
│       │                                                      │
│  ┌────▼────┐    ┌─────────┐    ┌─────────┐                 │
│  │  nginx  │───►│ cfg-web │───►│ cfg-db  │                 │
│  │ :8000   │    └─────────┘    └─────────┘                 │
│  │         │                                                │
│  │         │    ┌─────────┐    ┌─────────┐    ┌─────────┐  │
│  │         │───►│ txs-web │───►│ txs-db  │    │txs-redis│  │
│  │         │    └─────────┘    └─────────┘    └─────────┘  │
│  │         │         │                                      │
│  │         │    ┌────▼────┐                                │
│  │         │    │ workers │ (indexer, contracts, webhooks) │
│  │         │    └─────────┘                                │
│  │         │                                                │
│  │         │    ┌─────────┐    ┌─────────┐                 │
│  │         │───►│ cgw-web │───►│cgw-redis│                 │
│  │         │    └─────────┘    └─────────┘                 │
│  │         │                                                │
│  │         │    ┌──────────┐   ┌──────────┐                │
│  │         │───►│events-web│───►│events-db │                │
│  └─────────┘    └──────────┘   └──────────┘                │
│                                                              │
│  ┌─────────┐                                                │
│  │   ui    │ (Safe Wallet Web)                              │
│  └─────────┘                                                │
└─────────────────────────────────────────────────────────────┘
```

## Key Differences from Manual Deployment

| Aspect | Manual (`docker-compose.yml`) | Coolify (`docker-compose.coolify.yml`) |
|--------|------------------------------|----------------------------------------|
| SSL | Manual nginx/traefik setup | Automatic via Traefik |
| Env files | Separate `container_env_files/*.env` | All in Coolify UI or single `.env` |
| Secrets | Generated by `deploy.sh` | Set manually in Coolify UI |
| Updates | `docker compose pull && up` | One-click in Coolify UI |
| Monitoring | DIY | Built into Coolify |
| Backups | Manual scripts | Coolify's backup feature |

## Environment Variables Reference

### Required Variables

| Variable | Description |
|----------|-------------|
| `RPC_NODE_URL` | Blockchain RPC endpoint |
| `DJANGO_SECRET_KEY` | Django secret (32+ chars) |
| `CGW_AUTH_TOKEN` | Shared auth token for service communication |
| `POSTGRES_PASSWORD` | Database password |
| `PUBLIC_URL` | Public URL for the deployment |
| `CSRF_TRUSTED_ORIGINS` | Comma-separated trusted origins |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CFG_VERSION` | `latest` | Config Service version |
| `CGW_VERSION` | `latest` | Client Gateway version |
| `TXS_VERSION` | `latest` | Transaction Service version |
| `UI_VERSION` | `latest` | Wallet Web UI version |
| `EVENTS_VERSION` | `latest` | Events Service version |
| `ADMIN_USERNAME` | `root` | Django admin username |
| `ADMIN_PASSWORD` | `admin` | Django admin password |
| `INFURA_TOKEN` | - | Infura API key for UI |

## Troubleshooting

### Services Not Starting

Check Coolify logs for each service. Common issues:
- Missing required environment variables
- Database not ready (healthcheck failing)
- RPC endpoint not accessible

### Internal Communication Failing

Services communicate via internal Docker DNS:
- Config → CGW: `http://nginx:8000/cgw`
- CGW → Config: `http://nginx:8000/cfg`
- Workers → RabbitMQ: `amqp://txs-rabbitmq` or `amqp://general-rabbitmq`

If services can't reach each other, ensure they're on the same Docker network (Coolify handles this automatically).

### Chain Not Appearing in UI

1. Verify chain is added in Config Service admin
2. Check `transactionService` URL is `http://nginx:8000/txs`
3. Restart CGW: In Coolify, click Restart on `cgw-web`

### Database Connection Issues

Ensure `POSTGRES_PASSWORD` matches across all services. Check that database containers are healthy before web services start.

## Updating

1. In Coolify, go to your project
2. Update the version environment variables (e.g., `TXS_VERSION=v4.7.0`)
3. Click **Redeploy**

For major version changes, check upstream release notes for migration steps.

