# Tuning Matrix (Dynamic Budget + RAM Tier Compatibility)

Language: **English** | [简体中文](tuning-matrix.zh-CN.md) | [繁體中文](tuning-matrix.zh-TW.md)

This project keeps RAM tiers (`S/M/L/XL`) for compatibility, then applies a dynamic budget pass that prioritizes OpenClaw and recalculates infra limits.

## Budget Order
1. Reserve host memory (`OS_RESERVE_GB`)
2. Assign OpenClaw memory budget
3. Assign Valkey memory budget
4. Give remaining memory to Postgres (with floor)

## Formulas
Given `R = RAM_GB`, `C = CPU_CORES`:

- `OS_RESERVE_GB = min(4.0, max(0.8, 0.20 * R))`
- `SVC_GB = R - OS_RESERVE_GB`
- `REDIS_GB = clamp(0.25, 0.06 * R, 1.0)`
- `OPENCLAW_GB = clamp(1.2, 0.40 * SVC_GB, 6.0)`
- `POSTGRES_GB = SVC_GB - OPENCLAW_GB - REDIS_GB`
- If `POSTGRES_GB < 1.0`, reduce OpenClaw share to keep `POSTGRES_GB >= 1.0`.

## CPU Allocation (Agent-First)
- `OPENCLAW_WORKERS_RECOMMENDED = ceil(OPENCLAW_AGENT_TARGET / OPENCLAW_WORKER_PER_AGENTS)`
- OpenClaw: `cpu_shares=2048`, `cpus=min(C, 1.5)`
- Postgres: `cpu_shares=1536`, `cpus=min(C, 1.2)`
- Valkey: `cpu_shares=512`, default `cpus=0.30`

## Postgres Dynamic Parameters
- `shared_buffers = min(0.25 * POSTGRES_GB, 2GB)`
- `effective_cache_size = 0.70 * R`
- `work_mem = 8MB`
- `maintenance_work_mem = min(0.15 * POSTGRES_GB, 1GB)`
- `max_connections = 50`
- `max_worker_processes = clamp(C, 4, 16)`
- `max_parallel_workers = clamp(floor(C/2), 2, 8)`
- `max_parallel_workers_per_gather = clamp(floor(C/4), 1, 4)`
- `max_parallel_maintenance_workers = clamp(floor(C/4), 1, 4)`

## swap / zram
- `SWAP_GB = clamp(0.5 * R, 2, 16)`
- `ZRAM_GB = clamp(0.25 * R, 1, 8)` with `lz4`, priority `100`

## Overrides
Any explicit values in `bootstrap.env` take precedence over dynamic defaults.

Compatibility override remains available:
- `FORCE_RAM_TIER=S|M|L|XL`
