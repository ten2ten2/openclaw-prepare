# 预检查（Preflight Checks）

语言: [English](preflight-checks.md) | **简体中文** | [繁體中文](preflight-checks.zh-TW.md)

`scripts/ubuntu/prep.sh` 会在执行变更前先运行预检查。

## 阻断项检查（默认）
- Ubuntu 24.04+
- root/sudo 权限
- `apt-get update` 可执行
- `systemd` 可用
- Docker 与 Cloudflare 的 apt 源可达
- 最低阈值：
  - RAM >= 4 GiB
  - CPU >= 2 核
  - 可用磁盘 >= 80 GiB

## 警告项
- 若根盘为 HDD（`ROTA=1`），会提示 RAG/索引/检查点工作负载风险
- 动态预算期间，低内存场景可能出现降级模式警告
- 提示：`4 GiB` 只是启动下限
- Runtime scaffold 只初始化 workspace/skills/tools 目录，不会自动安装 skills/tools 仓库

## 行为控制
- `PREFLIGHT_STRICT=1` 且 `ALLOW_WEAK_HOST=0`：检查失败即退出
- `ALLOW_WEAK_HOST=1`：将失败降级为警告（仅测试用途）
