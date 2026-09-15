# Changelog

## Unreleased

- 跨机器安全加固：遵循 `CODEX_HOME`，保守解析含引号/注释的 TOML，并在重复表、重复键或非布尔值时拒绝写入。
- `Fix` 改为唯一备份与补偿事务，精确记录注册表及用户代理环境变量原有的存在状态和值。
- `Diagnose` 支持 `ALL_PROXY` 路由、报告凭据脱敏，并禁止跳过/失败探测时输出健康结论。
- `Rollback` 验证备份 schema 和完整状态，只自动选择真实改动备份，部分恢复失败时返回非零并逐项报告。
- 双击启动器只解除当前目标脚本的下载阻止标记；新增 Windows PowerShell 5.1 / PowerShell 7 隔离回归测试。

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的组织方式。

## [1.1.1] - 2026-09-10

修掉 1.1.0 里安全检查自身的一个漏洞：`-SkipProxyCheck` 关掉的其实是整道闸。

### Fixed

- `-SkipProxyCheck` 原来跳过的是**整个安全检查**，包括「端口有没有人在监听」这一步 —— 于是 `Fix -SkipProxyCheck -Port <死端口>` 仍会把系统代理写向一个死端口，把这台机器改断网。而文档把它描述成「机器还没联网时」用的无害开关，恰恰是在端口很可能就是死的那种场景下把用户引进去。现在这个开关**只跳过需要联网的「链路」探测**（经代理访问 `chatgpt.com`）；「存活」检查读的是本地内核 TCP 表、不需要联网，因此**始终执行**，死端口一律拒绝。要连存活检查一起跳过，只有 `-Force` 这一条明确路径。

### Changed

- README（中英）与 `docs/03` Q4 增加「安全检查分两层」对照表，写明哪一层需要联网、能被哪个开关跳过。
- `Fix-CodexReconnect.ps1` 补上缺失的 `.PARAMETER Force` 与 `.PARAMETER SkipProxyCheck` 帮助条目。

### Verified

- 四个用例实测：死端口（闸开）→ 拒绝、退出码 `4`；死端口 + `-SkipProxyCheck` → **拒绝、退出码 `4`**（不再放行）；活端口 + `-SkipProxyCheck` → 放行且链路显示「not tested」；`-Force` + 死端口 → 告警后继续。三个脚本 0 解析错误。

## [1.1.0] - 2026-09-10

让「下载下来就能跑」成立，并且不再可能把用户的网络改断。

### Added

- 根目录三个双击启动器 `Diagnose.cmd` / `Fix.cmd` / `Rollback.cmd`。Windows 默认执行策略是 `Restricted`（任何 `.ps1` 都不让跑），而「Download ZIP」解出来的文件还带 Mark-of-the-Web 标记（`RemoteSigned` 下同样被拦）—— 实测确认这两种情况都会让 README 里的命令直接失败。启动器内置 `Unblock-File` + `-ExecutionPolicy Bypass`，把这两个坑一起填掉。
- `Fix` 的**安全检查**：写系统代理前先确认目标端口在监听、且经它能连通 `chatgpt.com`。不通过就什么都不写，退出码 `4`，并给出四种继续方式。新增 `-Force`、`-SkipProxyCheck`、`-ProxyTestTimeoutSec`。
- 端口探测改为**通用**：新增 Clash / Clash Verge / mihomo / sing-box / Xray / nekobox 的进程与配置文件识别（JSON 与 YAML 两种布局），不再只认 v2rayN。
- 报告与修复输出都会打印候选端口的**来源**与**是否在监听**，区分「端口猜错」与「代理挂了」两种截然不同的故障。

### Changed

- 端口解析顺序改为「先去重、再取第一个真的在监听的」：`-Port` → 系统代理已写端口 → 客户端配置文件的入站端口 → 常见端口里在监听的那个 → 猜测值 → 兜底 `10808`。死候选永远不会盖过活候选，因为往系统代理里写一个死端口会让整台机器断网。
- YAML 配置只匹配**顶格**的键。订阅文件里每个代理节点都带一个 `port:`（节点远程端口），原来的宽松匹配会把几十个无关端口吸进候选列表 —— 实测某机器上一次吸进 20 个，把报告冲成噪声，还拖慢 15 秒。
- 读监听端口改用 `IPGlobalProperties.GetActiveTcpListeners()`（毫秒级）取代逐个端口连接试探。Windows 上被拒绝的 loopback 连接仍会耗满整个超时，12 个端口就是 4.5 秒。
- `Get-ScheduledTask` 改为仅在更便宜的探测手段全部落空时才调用（该调用约 2 秒）。
- 脚本内各探测步骤加缓存，一次运行内不重复扫描。
- **性能**：实测同一台机器上 `Diagnose` 从 17.6s 降到 5.1s，`Fix -DryRun` 从 25.6s 降到 1.4s。
- README 增加「运行前必读」说明（执行策略 / 下载标记 / 双层拦截）与端口识别顺序表；`docs/03` 增加 Q4b、Q4c。

### Fixed

- `List[string].AddRange(@(...))` 在 PowerShell 5.1 下抛 `MethodException`（`Object[]` 不能转成 `IEnumerable[string]`）。因为包在 `$ErrorActionPreference = 'Stop'` 里，表现为**脚本中途静默中止、什么都不输出** —— 而这条路径正是「不传 `-Port` 的默认调用」，也就是绝大多数用户。已改为显式 `foreach`。
- `Fix` 原来对目标端口不做任何存活校验，会把 `ProxyEnable=1` + `ProxyServer=127.0.0.1:<死端口>` 直接写进注册表（实测 `-Port 9999` 确实走到了写这一步）。这会让整台机器失去 HTTPS 访问。
- 仓库里残留的本机绝对路径（`D:\Software\v2rayN-windows-64-desktop\...`）已替换为注册表卸载项 + 标准安装位置 + 进程路径的通用发现逻辑。
- `.gitattributes` 为 `*.cmd` / `*.bat` 强制 `eol=crlf` —— `cmd.exe` 解析 LF-only 批处理不可靠。

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
