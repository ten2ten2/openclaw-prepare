# Preflight Checks

Language: **English** | [简体中文](preflight-checks.zh-CN.md) | [繁體中文](preflight-checks.zh-TW.md)

`scripts/ubuntu/prep.sh` runs preflight checks before mutation.

## Blocking Checks (Default)
- Ubuntu 24.04+
- root/sudo privileges
- `apt-get update` works
- `systemd` is available
- Docker and Cloudflare apt endpoints reachable
- Minimum thresholds:
  - RAM >= 4 GiB
  - CPU >= 2 cores
  - Disk Free >= 80 GiB

## Warnings
- HDD root disk (`ROTA=1`) warning for RAG/index/checkpoint workloads
- Low-memory degraded-mode warnings can appear during dynamic budgeting
- Reminder: `4 GiB` is startup minimum
- Runtime scaffold initializes workspace/skills/tools directories only; it does not auto-install skills/tools repositories

## Behavior Controls
- `PREFLIGHT_STRICT=1` and `ALLOW_WEAK_HOST=0`: exit on failures
- `ALLOW_WEAK_HOST=1`: downgrade failures to warnings (testing only)
