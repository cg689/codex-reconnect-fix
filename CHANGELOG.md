# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的组织方式。

## [1.0.0] - 2026-09-10

首次发布。

### Added

- `scripts/Diagnose-CodexReconnect.ps1` —— 只读体检。检查三层出网路径（Windows 系统代理 / 代理环境变量 / `config.toml` 的 `respect_system_proxy`），再做两项实测（代理端口 TCP 可达、经代理访问 `chatgpt.com`，并附带直连对照）。输出 VERDICT 结论与可执行建议，退出码 `0/1/2` 便于接入巡检脚本，支持 `-ReportPath` 落盘报告。
- `scripts/Fix-CodexReconnect.ps1` —— 一键修复。备份 `config.toml` 与当前系统代理状态后，恢复系统代理并打开官方特性开关；支持 `-DryRun`、`-Port`、`-SetEnvironmentVariables`、`-SkipSystemProxy`、`-CodexHome`。
- `scripts/Rollback-CodexReconnect.ps1` —— 一条命令还原 `config.toml`、系统代理与用户级环境变量。
- 端口自动探测：系统代理已写端口 → 运行中的 v2rayN（`guiNConfig.json` → `binConfigs/config.json`）→ 默认 `10808`。
- `config/config.example.toml` —— 最小可用配置片段，含 `suppress_unstable_features_warning` 说明。
- `docs/` —— 完整排查记录、codex-rs 源码级定位（核对 tag `rust-v0.153.4`）、常见问题与踩坑。

### Notes

- 修复方式是启用上游特性开关 `respect_system_proxy`，**不替换 `model_provider`**。社区流行的 provider 替换方案在桌面版上会导致启动卡死。
- 写 `config.toml` 时使用 UTF-8 无 BOM 并保留原有换行符 —— BOM 会让 Codex 的 TOML 解析失败。
