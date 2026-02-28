# 預檢（Preflight Checks）

語言: [English](preflight-checks.md) | [简体中文](preflight-checks.zh-CN.md) | **繁體中文**

`scripts/ubuntu/prep.sh` 會在執行變更前先跑預檢。

## 阻擋檢查（預設）
- Ubuntu 24.04+
- root/sudo 權限
- `apt-get update` 可執行
- `systemd` 可用
- Docker 與 Cloudflare 的 apt 端點可達
- 最低門檻：
  - RAM >= 4 GiB
  - CPU >= 2 核
  - 可用磁碟 >= 80 GiB

## 警告項
- 若根磁碟為 HDD（`ROTA=1`），會提示 RAG/索引/checkpoint 工作負載風險
- 動態預算期間，低記憶體場景可能出現降級模式警告
- 提示：`4 GiB` 只是啟動下限
- Runtime scaffold 只初始化 workspace/skills/tools 目錄，不會自動安裝 skills/tools 倉庫

## 行為控制
- `PREFLIGHT_STRICT=1` 且 `ALLOW_WEAK_HOST=0`：檢查失敗即退出
- `ALLOW_WEAK_HOST=1`：將失敗降級為警告（僅測試用途）
