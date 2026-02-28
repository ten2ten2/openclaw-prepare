# 調校矩陣（動態預算 + RAM 分級相容）

語言: [English](tuning-matrix.md) | [简体中文](tuning-matrix.zh-CN.md) | **繁體中文**

本專案保留 `S/M/L/XL` RAM 分級以相容舊配置，接著執行一輪動態預算，優先保障 OpenClaw，並重新計算 infra 限額。

## 預算順序
1. 預留主機記憶體（`OS_RESERVE_GB`）
2. 分配 OpenClaw 記憶體預算
3. 分配 Valkey 記憶體預算
4. 剩餘記憶體分配給 Postgres（含下限）

## 公式
已知 `R = RAM_GB`，`C = CPU_CORES`：

- `OS_RESERVE_GB = min(4.0, max(0.8, 0.20 * R))`
- `SVC_GB = R - OS_RESERVE_GB`
- `REDIS_GB = clamp(0.25, 0.06 * R, 1.0)`
- `OPENCLAW_GB = clamp(1.2, 0.40 * SVC_GB, 6.0)`
- `POSTGRES_GB = SVC_GB - OPENCLAW_GB - REDIS_GB`
- 若 `POSTGRES_GB < 1.0`，會降低 OpenClaw 佔比以確保 `POSTGRES_GB >= 1.0`。

## CPU 分配（Agent 優先）
- `OPENCLAW_WORKERS_RECOMMENDED = ceil(OPENCLAW_AGENT_TARGET / OPENCLAW_WORKER_PER_AGENTS)`
- OpenClaw: `cpu_shares=2048`, `cpus=min(C, 1.5)`
- Postgres: `cpu_shares=1536`, `cpus=min(C, 1.2)`
- Valkey: `cpu_shares=512`, 預設 `cpus=0.30`

## Postgres 動態參數
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
- `ZRAM_GB = clamp(0.25 * R, 1, 8)`，壓縮演算法 `lz4`，優先序 `100`

## 覆寫規則
`bootstrap.env` 中任何顯式值都會優先於動態預設值。

仍可使用相容覆寫：
- `FORCE_RAM_TIER=S|M|L|XL`
