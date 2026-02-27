# openclaw-prepare (Ubuntu Generic)

将一台 Ubuntu 24.04+ 服务器初始化到“可安装 OpenClaw”的状态。

## 目标
- Ubuntu 通用主机引导（不绑定云厂商）
- preflight 先行：系统/权限/网络/资源检查
- 主机安全加固（SSH/UFW/fail2ban/unattended-upgrades）
- Docker + cloudflared 官方仓库安装
- 生成 pgvector(Postgres) + Valkey infra（可选直接启动）
- Web 后台仅通过 Cloudflare Tunnel 暴露

## 最低要求（默认阻断）
- Ubuntu `24.04+`
- `apt-get update` 可用（外网/镜像源可用）
- root 或 sudo 权限
- 支持 systemd，且允许安装 Docker
- 最低资源：
  - RAM `>= 4 GiB`
  - CPU `>= 2 cores`
  - Disk Free `>= 80 GiB`

## 快速开始

### 1) 获取仓库（在目标服务器）
```bash
git clone <YOUR_REPO_URL> OpenClawDotfiles
cd OpenClawDotfiles
```

### 2) 准备 bootstrap.env（在目标服务器）
```bash
sudo mkdir -p /opt/openclaw
sudo cp templates/bootstrap.env.example /opt/openclaw/bootstrap.env
sudo chmod 600 /opt/openclaw/bootstrap.env
sudo vim /opt/openclaw/bootstrap.env
```

### 3) 运行主入口
```bash
sudo bash scripts/ubuntu/prep.sh
```

可选：初始化后立即启动 infra
```bash
START_INFRA=1 sudo -E bash scripts/ubuntu/prep.sh
```

### 4) 配置 Cloudflare Tunnel
```bash
sudo bash scripts/cloudflare/setup_tunnel.sh
```

## 执行流程
1. 读取 `/opt/openclaw/bootstrap.env`
2. preflight 检查：OS、apt、权限、systemd、连通性、最低资源
3. RAM 分档（S/M/L/XL）并应用默认参数
4. 主机安全加固 + Docker/cloudflared 安装
5. 生成 `/opt/openclaw/infra`（compose/.env/db-init）
6. `START_INFRA=1` 时直接 `docker compose up -d`
7. 输出建议值：
- `OPENCLAW_WORKERS_RECOMMENDED`
- `POSTGRES_MAX_PARALLEL_WORKERS_PER_GATHER_RECOMMENDED`

## RAM 分档
见 [docs/tuning-matrix.md](docs/tuning-matrix.md)。

可通过 `FORCE_RAM_TIER=S|M|L|XL` 强制指定档位。

## Preflight 规则
见 [docs/preflight-checks.md](docs/preflight-checks.md)。

关键开关：
- `PREFLIGHT_STRICT=1`：关键失败阻断
- `ALLOW_WEAK_HOST=1`：允许低规格继续（仅测试建议）

## Doctor（只检查不改动）
```bash
sudo bash scripts/ubuntu/doctor.sh
```

## 常用路径
- 引导配置：`/opt/openclaw/bootstrap.env`
- infra 目录：`/opt/openclaw/infra`
- Tunnel 配置：`/etc/cloudflared/config.yml`
- Tunnel 凭据：`/etc/cloudflared/<UUID>.json`

## 安全注意事项
- 不要提交 `/opt/openclaw/bootstrap.env`
- 不要提交 `~/.cloudflared/*.json` 或 `/etc/cloudflared/*.json`
- 数据库/Valkey 不开放公网端口
- OpenClaw Web 后台只监听 `127.0.0.1` 或 Docker 内网
