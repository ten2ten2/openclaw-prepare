# 调优矩阵（动态预算 + RAM 分级兼容）

语言: [English](tuning-matrix.md) | **简体中文** | [繁體中文](tuning-matrix.zh-TW.md)

本项目保留 `S/M/L/XL` RAM 分级以兼容历史配置，然后执行一轮动态预算，优先保障 OpenClaw，并重新计算 infra 限额。

## 预算顺序
1. 预留主机内存（`OS_RESERVE_GB`）
2. 分配 OpenClaw 内存预算
3. 分配 Valkey 内存预算
4. 其余内存分配给 Postgres（带下限）

## 公式
已知 `R = RAM_GB`，`C = CPU_CORES`：

- `OS_RESERVE_GB = min(4.0, max(0.8, 0.20 * R))`
- `SVC_GB = R - OS_RESERVE_GB`
- `REDIS_GB = clamp(0.25, 0.06 * R, 1.0)`
- `OPENCLAW_GB = clamp(1.2, 0.40 * SVC_GB, 6.0)`
- `POSTGRES_GB = SVC_GB - OPENCLAW_GB - REDIS_GB`
- 若 `POSTGRES_GB < 1.0`，会降低 OpenClaw 占比以保证 `POSTGRES_GB >= 1.0`。

## CPU 分配（Agent 优先）
- `OPENCLAW_WORKERS_RECOMMENDED = ceil(OPENCLAW_AGENT_TARGET / OPENCLAW_WORKER_PER_AGENTS)`
- OpenClaw: `cpu_shares=2048`, `cpus=min(C, 1.5)`
- Postgres: `cpu_shares=1536`, `cpus=min(C, 1.2)`
- Valkey: `cpu_shares=512`, 默认 `cpus=0.30`

## Postgres 动态参数
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
- `ZRAM_GB = clamp(0.25 * R, 1, 8)`，压缩算法 `lz4`，优先级 `100`

## 覆盖规则
`bootstrap.env` 中任何显式值都会优先于动态默认值。

仍可使用兼容覆盖：
- `FORCE_RAM_TIER=S|M|L|XL`
