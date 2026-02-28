# openclaw-prepare（Ubuntu 通用版）

語言: [English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

用於將 Ubuntu 伺服器準備為 OpenClaw 執行環境，包含動態 RAM/CPU 預算、pgvector/Valkey 基礎設施，以及 OpenClaw Docker Gateway 導引。

## 目標
- 通用 Ubuntu 初始化（與雲廠商無關）
- 在任何變更前執行預檢
- 主機加固（SSH/UFW/fail2ban/unattended-upgrades）
- 動態資源預算：優先 OpenClaw，其次 Postgres/pgvector，再到 Valkey
- 低記憶體主機預設啟用 zram + swapfile
- 官方 OpenClaw Docker Gateway 流程（`docker-setup.sh`）

## 最低需求
- Ubuntu `24.04+`
- root/sudo 權限
- 支援 `systemd` 與 Docker 安裝
- 可連網（apt + git）
- 最低主機資源：
  - RAM `>= 4 GiB`（僅啟動底線）
  - CPU `>= 2` 核
  - 可用磁碟 `>= 80 GiB`

## 快速開始

### 1) 在目標主機 clone 專案
```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/ten2ten2/openclaw-prepare openclaw-prepare
cd openclaw-prepare
```

### 2) 準備 bootstrap 設定
```bash
sudo mkdir -p /opt/openclaw
sudo cp templates/bootstrap.env.example /opt/openclaw/bootstrap.env
sudo chmod 600 /opt/openclaw/bootstrap.env
sudo vim /opt/openclaw/bootstrap.env
```

### 3) 執行主機準備
```bash
sudo bash scripts/ubuntu/prep.sh
```

預設會啟動基礎設施。若只做準備不啟動 infra：
```bash
START_INFRA=0 sudo -E bash scripts/ubuntu/prep.sh
```

### 4) 設定 Cloudflare Tunnel（可選）
```bash
sudo bash scripts/cloudflare/setup_tunnel.sh
```

## 執行流程
1. 載入 `/opt/openclaw/bootstrap.env`
2. 執行預檢
3. 套用 RAM 分級相容預設（`S/M/L/XL`）
4. 套用動態資源預算覆寫
5. 主機加固 + 安裝 Docker/cloudflared
6. 設定 swap + zram + sysctl
7. 產生 `/opt/openclaw/infra` 並啟動 pgvector/Valkey（預設）
8. 若 `OPENCLAW_ENABLE_DOCKER_GATEWAY=1`，執行官方 OpenClaw Docker 導引並套用資源 override compose
9. 輸出最終 RAM/CPU 預算摘要

## OpenClaw 官方 Home 目錄骨架
預設會在 `/opt/openclaw/.openclaw` 初始化持久目錄：
- workspace: `/opt/openclaw/.openclaw/workspace`
- skills: `/opt/openclaw/.openclaw/skills`
- tools: `/opt/openclaw/.openclaw/tools`
- 官方設定 JSON: `/opt/openclaw/.openclaw/openclaw.json`

OpenClaw 設定 JSON 在 repo 初始化時只寫入一次（重跑會保留）。
Gateway 內掛載路徑為 `/root/.openclaw/openclaw.json`。

預設 JSON 結構：
```json
{
  "agents": {
    "defaults": {
      "workspace": "/root/.openclaw/workspace"
    }
  }
}
```

## 動態預算規則
輸入：
- `R = RAM_GB`
- `C = CPU_CORES`

RAM 預算：
- `OS_RESERVE_GB = min(4.0, max(0.8, 0.20 * R))`
- `SVC_GB = R - OS_RESERVE_GB`
- `REDIS_GB = clamp(0.25, 0.06 * R, 1.0)`
- `OPENCLAW_GB = clamp(1.2, 0.40 * SVC_GB, 6.0)`
- `POSTGRES_GB = SVC_GB - OPENCLAW_GB - REDIS_GB`
- 若 `POSTGRES_GB < 1.0`，會下調 OpenClaw 佔比以保證 `POSTGRES_GB >= 1.0`

CPU 預算：
- `OPENCLAW_WORKERS_RECOMMENDED = ceil(OPENCLAW_AGENT_TARGET / OPENCLAW_WORKER_PER_AGENTS)`
- OpenClaw: `cpu_shares=2048`, `cpus=min(C, 1.5)`
- Postgres: `cpu_shares=1536`, `cpus=min(C, 1.2)`
- Valkey: `cpu_shares=512`, `cpus=0.30`（預設）

Postgres 動態參數：
- `shared_buffers = min(0.25 * POSTGRES_GB, 2GB)`
- `effective_cache_size = 0.70 * RAM_GB`
- `work_mem = 8MB`
- `maintenance_work_mem = min(0.15 * POSTGRES_GB, 1GB)`
- `max_connections = 50`
- 平行參數依 CPU 自動推導並採保守上限

## OpenClaw Docker Gateway
當 `OPENCLAW_ENABLE_DOCKER_GATEWAY=1` 時，prep 會執行：
- `scripts/openclaw/setup_gateway_docker.sh`
- 在 `OPENCLAW_GATEWAY_DIR` clone/update `OPENCLAW_REPO_URL`
- checkout 到 `OPENCLAW_REPO_REF`
- 執行上游 `docker-setup.sh`
- 為 `openclaw-gateway` 產生 `docker-compose.resource.override.yml`
- `OPENCLAW_AUTOWIRE_INFRA=1` 時自動產生 `docker-compose.infra.override.yml`
- `OPENCLAW_AUTOWIRE_RUNTIME=1` 時自動產生 `docker-compose.runtime.override.yml`
- 將兩套 stack 接到 `OPENCLAW_SHARED_NETWORK`（預設 `openclaw-shared`）
- 以 base compose + override compose 啟動 gateway

執行期目錄提示：
- prep 只會初始化 skills/tools 目錄（不會自動安裝 skills/tools 倉庫）

## 可選個人化設定包
可選擇把 repo 內的本地個人化設定匯入 OpenClaw home。

預設行為：
- `OPENCLAW_IMPORT_PERSONALIZATION=0`（關閉）
- `OPENCLAW_PERSONALIZATION_DIR` 預設 `templates/openclaw-personalization`
- `OPENCLAW_PERSONALIZATION_OVERWRITE=1`（開啟）：會覆蓋 `/opt/openclaw/.openclaw` 中同名檔案

啟用匯入：
```bash
OPENCLAW_IMPORT_PERSONALIZATION=1 sudo -E bash scripts/ubuntu/prep.sh
```

後續單獨匯入（不需重跑完整 prep）：
```bash
sudo -E bash scripts/openclaw/import_personalization.sh
```

停用覆蓋（保留既有檔案）：
```bash
OPENCLAW_IMPORT_PERSONALIZATION=1 \
OPENCLAW_PERSONALIZATION_OVERWRITE=0 \
sudo -E bash scripts/ubuntu/prep.sh
```

後續單獨匯入且不覆蓋：
```bash
OPENCLAW_PERSONALIZATION_OVERWRITE=0 \
sudo -E bash scripts/openclaw/import_personalization.sh
```

匯入模式：
- 不做路徑對應
- 直接從 `OPENCLAW_PERSONALIZATION_DIR` 複製到 `OPENCLAW_OFFICIAL_HOME_DIR`
- override 複製前會有明確警告日誌

Dashboard Token 取得：
```bash
cd /opt/openclaw/gateway
docker compose run --rm openclaw-cli dashboard --no-open
```

## 驗證
執行預算自測：
```bash
bash scripts/ubuntu/tests/budget-selftest.sh
```

只跑預檢：
```bash
sudo bash scripts/ubuntu/doctor.sh
```

## 常用路徑
- Bootstrap 設定：`/opt/openclaw/bootstrap.env`
- Infra 目錄：`/opt/openclaw/infra`
- OpenClaw gateway 程式碼目錄：`/opt/openclaw/gateway`
- Tunnel 設定：`/etc/cloudflared/config.yml`

## 安全說明
- 不要提交 `/opt/openclaw/bootstrap.env`
- 不要提交 `~/.cloudflared/*.json` 或 `/etc/cloudflared/*.json`
- 保持資料庫/Valkey 僅內網可達
- 保持 OpenClaw 管理端點僅綁定在可信網路路徑
