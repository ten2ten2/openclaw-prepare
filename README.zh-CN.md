# openclaw-prepare（Ubuntu 通用版）

语言: [English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

用于将 Ubuntu 服务器准备为 OpenClaw 运行环境，包含动态 RAM/CPU 预算、pgvector/Valkey 基础设施，以及 OpenClaw Docker Gateway 引导。

## 目标
- 通用 Ubuntu 初始化（与云厂商无关）
- 在任何变更前执行预检查
- 主机加固（SSH/UFW/fail2ban/unattended-upgrades）
- 动态资源预算：优先 OpenClaw，其次 Postgres/pgvector，再到 Valkey
- 低内存主机默认启用 zram + swapfile
- 官方 OpenClaw Docker Gateway 流程（`docker-setup.sh`）

## 最低要求
- Ubuntu `24.04+`
- root/sudo 权限
- 支持 `systemd` 和 Docker 安装
- 可访问互联网（apt + git）
- 最低主机资源：
  - RAM `>= 4 GiB`（仅启动底线）
  - CPU `>= 2` 核
  - 可用磁盘 `>= 80 GiB`

## 快速开始

### 1) 在目标主机克隆仓库
```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/ten2ten2/openclaw-prepare openclaw-prepare
cd openclaw-prepare
```

### 2) 准备 bootstrap 配置
```bash
sudo mkdir -p /opt/openclaw
sudo cp templates/bootstrap.env.example /opt/openclaw/bootstrap.env
sudo chmod 600 /opt/openclaw/bootstrap.env
sudo vim /opt/openclaw/bootstrap.env
```

### 3) 执行主机准备
```bash
sudo bash scripts/ubuntu/prep.sh
```

默认会启动基础设施。若仅准备环境但不启动 infra：
```bash
START_INFRA=0 sudo -E bash scripts/ubuntu/prep.sh
```

### 4) 配置 Cloudflare Tunnel（可选）
```bash
sudo bash scripts/cloudflare/setup_tunnel.sh
```

## 执行流程
1. 加载 `/opt/openclaw/bootstrap.env`
2. 执行预检查
3. 应用 RAM 分级兼容默认值（`S/M/L/XL`）
4. 应用动态资源预算覆盖
5. 主机加固 + 安装 Docker/cloudflared
6. 配置 swap + zram + sysctl
7. 渲染 `/opt/openclaw/infra` 并启动 pgvector/Valkey（默认）
8. 若 `OPENCLAW_ENABLE_DOCKER_GATEWAY=1`，执行官方 OpenClaw Docker 引导并应用资源 override compose
9. 输出最终 RAM/CPU 预算摘要

## OpenClaw 官方 Home 目录骨架
默认会在 `/opt/openclaw/.openclaw` 初始化持久目录：
- workspace: `/opt/openclaw/.openclaw/workspace`
- skills: `/opt/openclaw/.openclaw/skills`
- tools: `/opt/openclaw/.openclaw/tools`
- 官方配置 JSON: `/opt/openclaw/.openclaw/openclaw.json`

OpenClaw 配置 JSON 在仓库初始化时只写入一次（重复执行会保留）。
Gateway 内挂载路径为 `/root/.openclaw/openclaw.json`。

默认 JSON 结构：
```json
{
  "agents": {
    "defaults": {
      "workspace": "/root/.openclaw/workspace"
    }
  }
}
```

## 动态预算规则
输入：
- `R = RAM_GB`
- `C = CPU_CORES`

RAM 预算：
- `OS_RESERVE_GB = min(4.0, max(0.8, 0.20 * R))`
- `SVC_GB = R - OS_RESERVE_GB`
- `REDIS_GB = clamp(0.25, 0.06 * R, 1.0)`
- `OPENCLAW_GB = clamp(1.2, 0.40 * SVC_GB, 6.0)`
- `POSTGRES_GB = SVC_GB - OPENCLAW_GB - REDIS_GB`
- 若 `POSTGRES_GB < 1.0`，会下调 OpenClaw 占比以保证 `POSTGRES_GB >= 1.0`

CPU 预算：
- `OPENCLAW_WORKERS_RECOMMENDED = ceil(OPENCLAW_AGENT_TARGET / OPENCLAW_WORKER_PER_AGENTS)`
- OpenClaw: `cpu_shares=2048`, `cpus=min(C, 1.5)`
- Postgres: `cpu_shares=1536`, `cpus=min(C, 1.2)`
- Valkey: `cpu_shares=512`, `cpus=0.30`（默认）

Postgres 动态参数：
- `shared_buffers = min(0.25 * POSTGRES_GB, 2GB)`
- `effective_cache_size = 0.70 * RAM_GB`
- `work_mem = 8MB`
- `maintenance_work_mem = min(0.15 * POSTGRES_GB, 1GB)`
- `max_connections = 50`
- 并行参数依据 CPU 自动推导并采用保守上限

## OpenClaw Docker Gateway
当 `OPENCLAW_ENABLE_DOCKER_GATEWAY=1` 时，prep 会执行：
- `scripts/openclaw/setup_gateway_docker.sh`
- 在 `OPENCLAW_GATEWAY_DIR` 克隆/更新 `OPENCLAW_REPO_URL`
- 切换到 `OPENCLAW_REPO_REF`
- 执行上游 `docker-setup.sh`
- 为 `openclaw-gateway` 写入 `docker-compose.resource.override.yml`
- `OPENCLAW_AUTOWIRE_INFRA=1` 时自动写入 `docker-compose.infra.override.yml`
- `OPENCLAW_AUTOWIRE_RUNTIME=1` 时自动写入 `docker-compose.runtime.override.yml`
- 将两套栈接入 `OPENCLAW_SHARED_NETWORK`（默认 `openclaw-shared`）
- 使用基础 compose + override compose 启动 gateway

运行时目录提示：
- prep 仅初始化 skills/tools 目录（不会自动安装 skills/tools 仓库）

## 可选个性化配置包
可选地把仓库中的本地个性化配置导入到 OpenClaw home。

默认行为：
- `OPENCLAW_IMPORT_PERSONALIZATION=0`（关闭）
- `OPENCLAW_PERSONALIZATION_DIR` 默认 `templates/openclaw-personalization`
- `OPENCLAW_PERSONALIZATION_OVERWRITE=1`（开启）：会覆盖 `/opt/openclaw/.openclaw` 中同名文件

开启导入：
```bash
OPENCLAW_IMPORT_PERSONALIZATION=1 sudo -E bash scripts/ubuntu/prep.sh
```

后期单独导入（无需重跑完整 prep）：
```bash
sudo -E bash scripts/openclaw/import_personalization.sh
```

关闭覆盖（保留已有文件）：
```bash
OPENCLAW_IMPORT_PERSONALIZATION=1 \
OPENCLAW_PERSONALIZATION_OVERWRITE=0 \
sudo -E bash scripts/ubuntu/prep.sh
```

后期单独导入且不覆盖：
```bash
OPENCLAW_PERSONALIZATION_OVERWRITE=0 \
sudo -E bash scripts/openclaw/import_personalization.sh
```

导入模式：
- 不做路径映射
- 直接从 `OPENCLAW_PERSONALIZATION_DIR` 复制到 `OPENCLAW_OFFICIAL_HOME_DIR`
- override 复制前会有明确警告日志

Dashboard Token 获取：
```bash
cd /opt/openclaw/gateway
docker compose run --rm openclaw-cli dashboard --no-open
```

## 验证
运行预算自测：
```bash
bash scripts/ubuntu/tests/budget-selftest.sh
```

仅运行预检查：
```bash
sudo bash scripts/ubuntu/doctor.sh
```

## 常用路径
- Bootstrap 配置：`/opt/openclaw/bootstrap.env`
- Infra 目录：`/opt/openclaw/infra`
- OpenClaw gateway 代码目录：`/opt/openclaw/gateway`
- Tunnel 配置：`/etc/cloudflared/config.yml`

## 安全说明
- 不要提交 `/opt/openclaw/bootstrap.env`
- 不要提交 `~/.cloudflared/*.json` 或 `/etc/cloudflared/*.json`
- 保持数据库/Valkey 私网可达
- 保持 OpenClaw 管理端点仅绑定在可信网络路径
