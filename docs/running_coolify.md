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
3. Select **GitHub** and connect to your repository
4. Set the **Docker Compose file** to `docker-compose.coolify.yml`

### 2. Configure Environment Variables

In Coolify's **Environment Variables** section, add these **required** variables:

```env
# Blockchain RPC
RPC_NODE_URL=https://mainnet.infura.io/v3/YOUR_KEY

# Security (generate with: openssl rand -base64 32)
DJANGO_SECRET_KEY=<generate-unique-value>
CGW_AUTH_TOKEN=<generate-unique-value>
POSTGRES_PASSWORD=<secure-password>

# Public URL (your domain)
PUBLIC_URL=https://safe.yourdomain.com
CSRF_TRUSTED_ORIGINS=https://safe.yourdomain.com
MEDIA_URL=https://safe.yourdomain.com/cfg/media/

# Admin credentials
ADMIN_USERNAME=root
ADMIN_PASSWORD=<strong-password>
ADMIN_EMAIL=admin@yourdomain.com
```

See `.env.coolify.example` for all available variables.

### 3. Configure Domain in Coolify

In Coolify's **Domains** tab for the `nginx` service:
- Set your domain (e.g., `safe.yourdomain.com`)
- Coolify automatically provisions SSL via Let's Encrypt

### 4. Deploy

Click **Deploy** and wait for all services to start (5-10 minutes on first deploy).

## How Coolify Transforms the Compose File

When you deploy, Coolify automatically:

1. **Adds Traefik labels** for SSL termination and routing
2. **Creates an isolated network** for your services
3. **Remaps volume paths** to Coolify's managed storage
4. **Injects SERVICE_FQDN_* variables** for service discovery

### What This Means for You

| Coolify Action | Your Responsibility |
|----------------|---------------------|
| SSL certificates | None - automatic |
| External routing | Set domain in Coolify UI |
| Internal routing | Use Docker DNS names (see below) |
| Data persistence | Automatic with remapped volumes |

## Internal Service Communication

Services communicate via **internal Docker DNS**, not public URLs:

| Service | Internal URL |
|---------|--------------|
| Nginx (gateway) | `http://nginx:8000` |
| Config Service | `http://nginx:8000/cfg` |
| Transaction Service | `http://nginx:8000/txs` |
| Client Gateway | `http://nginx:8000/cgw` |
| Events Service | `http://nginx:8000/events` |

### Critical Configuration Points

When configuring chains in Config Service admin, use **internal URLs**:

```
Transaction Service URI: http://nginx:8000/txs
VPC Transaction Service URI: http://nginx:8000/txs
```

⚠️ **Do NOT use your public domain** for internal service communication.

## Post-Deployment Setup

### 1. Verify Services

In Coolify, check that all services show "Running" with passing health checks.

Quick verification via terminal:
```bash
# From your server, check nginx is routing correctly
docker exec <nginx-container> wget -q --spider http://localhost:8000/cfg/api/v1/chains/
```

### 2. Create Admin Users

Superusers are created automatically using `ADMIN_USERNAME`, `ADMIN_PASSWORD`, and `ADMIN_EMAIL`.

If you need to create additional users:
```bash
# Config Service
docker exec -it <cfg-web-container> python src/manage.py createsuperuser

# Transaction Service
docker exec -it <txs-web-container> python manage.py createsuperuser
```

### 3. Configure Your Chain

1. Access Config Service admin: `https://your-domain.com/cfg/admin`
2. Login with your admin credentials
3. Go to **Chains** → **Add Chain**
4. Key fields:
   - **Chain ID**: Your chain's ID (1 for Mainnet, 137 for Polygon, etc.)
   - **Chain Name**: Display name
   - **Transaction Service URI**: `http://nginx:8000/txs`
   - **VPC Transaction Service URI**: `http://nginx:8000/txs`

### 4. Configure Webhooks

1. Access Events Service admin: `https://your-domain.com/events/admin`
2. Create a webhook:
   - **URL**: `http://nginx:8000/cgw/v1/hooks/events`
   - **Authorization**: `Basic <your-CGW_AUTH_TOKEN>`
   - Enable all event types you need

## Architecture with Coolify

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Coolify Server                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐                                                │
│  │   Traefik   │ ◄── SSL termination, Let's Encrypt             │
│  │   (Coolify) │                                                │
│  └──────┬──────┘                                                │
│         │ :443                                                   │
│         ▼                                                        │
│  ┌─────────────┐    Isolated Docker Network                     │
│  │    nginx    │──────────────────────────────────────────────┐ │
│  │   :8000     │                                              │ │
│  └──────┬──────┘                                              │ │
│         │                                                      │ │
│   ┌─────┴─────┬─────────────┬─────────────┬─────────────┐     │ │
│   ▼           ▼             ▼             ▼             ▼     │ │
│ /cfg/      /txs/         /cgw/       /events/         /       │ │
│   │           │             │             │             │     │ │
│ ┌─┴─┐     ┌───┴───┐     ┌───┴───┐     ┌───┴───┐     ┌──┴──┐  │ │
│ │cfg│     │txs-web│     │cgw-web│     │events │     │ ui  │  │ │
│ │web│     │       │     │       │     │ -web  │     │     │  │ │
│ └─┬─┘     └───┬───┘     └───┬───┘     └───┬───┘     └─────┘  │ │
│   │           │             │             │                   │ │
│ ┌─┴─┐     ┌───┴───┐     ┌───┴───┐     ┌───┴───┐              │ │
│ │cfg│     │txs-db │     │cgw-db │     │events │              │ │
│ │db │     │redis  │     │redis  │     │db     │              │ │
│ └───┘     │rabbit │     └───────┘     └───────┘              │ │
│           │workers│                                           │ │
│           └───────┘                                           │ │
└─────────────────────────────────────────────────────────────────┘
```

## Differences from Manual Deployment

| Aspect | Manual (`docker-compose.yml`) | Coolify (`docker-compose.coolify.yml`) |
|--------|------------------------------|----------------------------------------|
| SSL | Manual nginx/traefik config | Automatic via Traefik |
| Env files | Separate `*.env` files | Single set in Coolify UI |
| Secrets | Generated by `deploy.sh` | Set manually in Coolify UI |
| Updates | `docker compose pull && up` | One-click in Coolify UI |
| Monitoring | DIY | Built into Coolify |
| Backups | Manual scripts | Coolify's backup feature |
| Networking | `docker compose` networks | Coolify-managed isolated network |

## Environment Variables Reference

### Required

| Variable | Description |
|----------|-------------|
| `RPC_NODE_URL` | Blockchain RPC endpoint |
| `DJANGO_SECRET_KEY` | Django secret key (32+ random chars) |
| `CGW_AUTH_TOKEN` | Shared auth token for inter-service auth |
| `POSTGRES_PASSWORD` | Database password for all Postgres instances |
| `PUBLIC_URL` | Your public domain URL |
| `CSRF_TRUSTED_ORIGINS` | Comma-separated trusted origins |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `CFG_VERSION` | `latest` | Config Service version |
| `CGW_VERSION` | `latest` | Client Gateway version |
| `TXS_VERSION` | `latest` | Transaction Service version |
| `UI_VERSION` | `latest` | Wallet Web UI version |
| `EVENTS_VERSION` | `latest` | Events Service version |
| `ADMIN_USERNAME` | `root` | Django admin username |
| `ADMIN_PASSWORD` | `admin` | Django admin password |
| `ADMIN_EMAIL` | `admin@safe.local` | Admin email |
| `INFURA_TOKEN` | - | Infura API key for UI |
| `REVERSE_PROXY_PORT` | `8000` | Internal nginx port |

## Troubleshooting

### Services Not Starting

**Check logs in Coolify UI** for each service. Common issues:

1. **Missing environment variables**: Look for errors like `DJANGO_SECRET_KEY is required`
2. **Database not ready**: Postgres needs time to initialize - wait for healthcheck
3. **RPC endpoint issues**: Verify your `RPC_NODE_URL` is accessible from the server

### Internal Communication Failing

Services must use Docker DNS names, not public URLs:

✅ Correct: `http://nginx:8000/cfg`
❌ Wrong: `https://safe.yourdomain.com/cfg`

Test internal routing:
```bash
# From inside nginx container
docker exec <nginx-container> wget -q -O- http://cfg-web:8001/api/v1/chains/
```

### Chain Not Appearing in UI

1. Verify chain exists in Config Service admin (`/cfg/admin`)
2. Check `transactionService` URL is `http://nginx:8000/txs`
3. Restart CGW service in Coolify
4. Clear browser cache

### Database Connection Issues

- Ensure `POSTGRES_PASSWORD` matches across all environment variables
- Check database containers are healthy before web services start
- Verify database hostnames: `txs-db`, `cfg-db`, `events-db`, `cgw-db`

### Volume Mount Issues

If nginx can't find `nginx.conf`:
1. Verify `docker/nginx/nginx.conf` exists in your repository
2. Check Coolify has correctly cloned the repository
3. Redeploy after ensuring the file is present

### Healthcheck Failures

If services fail healthchecks but containers are running:
1. Increase `start_period` for slow-starting services
2. Check internal ports match healthcheck URLs
3. Verify databases are accepting connections

## Updating Services

### Minor Updates (same major version)

1. In Coolify, update version variables (e.g., `TXS_VERSION=v4.7.1`)
2. Click **Redeploy**

### Major Updates

1. Check upstream release notes for breaking changes
2. Backup databases via Coolify's backup feature
3. Update version variables
4. Deploy and monitor logs
5. Run any required migrations

## Security Recommendations

1. **Generate unique secrets**: Never reuse `DJANGO_SECRET_KEY` or `CGW_AUTH_TOKEN`
2. **Use strong passwords**: `POSTGRES_PASSWORD` and `ADMIN_PASSWORD`
3. **Pin versions**: Use specific image tags in production
4. **Enable Coolify's firewall**: Block direct access to service ports
5. **Regular updates**: Keep both Coolify and Safe services updated
