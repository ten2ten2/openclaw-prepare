# openclaw-prepare (Ubuntu Generic)

Prepare an Ubuntu server for OpenClaw with dynamic RAM/CPU budgeting, pgvector/Valkey infra, and OpenClaw Docker Gateway onboarding.

## Goals
- Generic Ubuntu bootstrap (cloud-agnostic)
- Preflight checks before any changes
- Host hardening (SSH/UFW/fail2ban/unattended-upgrades)
- Dynamic resource budget: OpenClaw first, then Postgres/pgvector, then Valkey
- zram + swapfile defaults for low-memory hosts
- Official OpenClaw Docker Gateway workflow (`docker-setup.sh`)

## Minimum Requirements
- Ubuntu `24.04+`
- root/sudo privileges
- `systemd` and Docker install support
- Internet access for apt + git
- Minimum host resources:
  - RAM `>= 4 GiB` (startup floor only)
  - CPU `>= 2 cores`
  - Disk Free `>= 80 GiB`

## Quick Start

### 1) Clone on target host
```bash
git clone <YOUR_REPO_URL> OpenClawDotfiles
cd OpenClawDotfiles
```

### 2) Prepare bootstrap config
```bash
sudo mkdir -p /opt/openclaw
sudo cp templates/bootstrap.env.example /opt/openclaw/bootstrap.env
sudo chmod 600 /opt/openclaw/bootstrap.env
sudo vim /opt/openclaw/bootstrap.env
```

### 3) Run host prep
```bash
sudo bash scripts/ubuntu/prep.sh
```

Default behavior includes starting infra. To run prep without starting infra:
```bash
START_INFRA=0 sudo -E bash scripts/ubuntu/prep.sh
```

### 4) Configure Cloudflare Tunnel (optional)
```bash
sudo bash scripts/cloudflare/setup_tunnel.sh
```

## Execution Flow
1. Load `/opt/openclaw/bootstrap.env`
2. Run preflight checks
3. Apply RAM tier compatibility defaults (`S/M/L/XL`)
4. Apply dynamic resource budget overrides
5. Harden host + install Docker/cloudflared
6. Configure swap + zram + sysctl
7. Render `/opt/openclaw/infra` and start pgvector/Valkey (default)
8. If `OPENCLAW_ENABLE_DOCKER_GATEWAY=1`, run official OpenClaw Docker onboarding and apply resource override compose file
9. Print applied RAM/CPU budget summary

## OpenClaw Official Home Scaffold
Prep initializes a persistent OpenClaw home scaffold under `/opt/openclaw/.openclaw` by default:
- workspace: `/opt/openclaw/.openclaw/workspace`
- skills: `/opt/openclaw/.openclaw/skills`
- tools: `/opt/openclaw/.openclaw/tools`
- official config JSON: `/opt/openclaw/.openclaw/openclaw.json`

OpenClaw config JSON is repo-initialized once (preserved on reruns).
It is mounted into gateway as `/root/.openclaw/openclaw.json`.

Default runtime JSON schema:
```json
{
  "agents": {
    "defaults": {
      "workspace": "/root/.openclaw/workspace"
    }
  }
}
```

## Dynamic Budget Rules
Input:
- `R = RAM_GB`
- `C = CPU_CORES`

RAM budget:
- `OS_RESERVE_GB = min(4.0, max(0.8, 0.20 * R))`
- `SVC_GB = R - OS_RESERVE_GB`
- `REDIS_GB = clamp(0.25, 0.06 * R, 1.0)`
- `OPENCLAW_GB = clamp(1.2, 0.40 * SVC_GB, 6.0)`
- `POSTGRES_GB = SVC_GB - OPENCLAW_GB - REDIS_GB`
- Enforce `POSTGRES_GB >= 1.0` by reducing OpenClaw share if needed

CPU budget:
- `OPENCLAW_WORKERS_RECOMMENDED = ceil(OPENCLAW_AGENT_TARGET / OPENCLAW_WORKER_PER_AGENTS)`
- OpenClaw: `cpu_shares=2048`, `cpus=min(C, 1.5)`
- Postgres: `cpu_shares=1536`, `cpus=min(C, 1.2)`
- Valkey: `cpu_shares=512`, `cpus=0.30` (default)

Postgres dynamic tuning:
- `shared_buffers = min(0.25 * POSTGRES_GB, 2GB)`
- `effective_cache_size = 0.70 * RAM_GB`
- `work_mem = 8MB`
- `maintenance_work_mem = min(0.15 * POSTGRES_GB, 1GB)`
- `max_connections = 50`
- Parallel knobs auto-derived from CPU with conservative caps

## OpenClaw Docker Gateway
When `OPENCLAW_ENABLE_DOCKER_GATEWAY=1`, prep runs:
- `scripts/openclaw/setup_gateway_docker.sh`
- clones/updates `OPENCLAW_REPO_URL` at `OPENCLAW_GATEWAY_DIR`
- checks out `OPENCLAW_REPO_REF`
- executes upstream `docker-setup.sh`
- writes `docker-compose.resource.override.yml` for `openclaw-gateway`
- auto-wires infra connectivity via `docker-compose.infra.override.yml` when `OPENCLAW_AUTOWIRE_INFRA=1`
- auto-wires runtime mounts/env via `docker-compose.runtime.override.yml` when `OPENCLAW_AUTOWIRE_RUNTIME=1`
- attaches both stacks to `OPENCLAW_SHARED_NETWORK` (default: `openclaw-shared`)
- starts gateway using base + override compose files

Runtime scaffold note:
- skills/tools directories are initialized only (no automatic skill/tool install in prep)

Dashboard token helper:
```bash
cd /opt/openclaw/gateway
docker compose run --rm openclaw-cli dashboard --no-open
```

## Validation
Run budget self-test:
```bash
bash scripts/ubuntu/tests/budget-selftest.sh
```

Run preflight only:
```bash
sudo bash scripts/ubuntu/doctor.sh
```

## Common Paths
- Bootstrap config: `/opt/openclaw/bootstrap.env`
- Infra directory: `/opt/openclaw/infra`
- OpenClaw gateway checkout: `/opt/openclaw/gateway`
- Tunnel config: `/etc/cloudflared/config.yml`

## Security Notes
- Do not commit `/opt/openclaw/bootstrap.env`
- Do not commit `~/.cloudflared/*.json` or `/etc/cloudflared/*.json`
- Keep database/Valkey private
- Keep OpenClaw admin endpoints bound to trusted network paths
