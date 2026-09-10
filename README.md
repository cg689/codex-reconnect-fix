# codex-reconnect-fix

**修掉 Codex / ChatGPT 桌面版的「正在重新连接 1/5 → 5/5」**

[中文](#中文) | [English](#english)

---

<a id="中文"></a>
## 中文

### 症状

每次新建对话，发第一条消息后客户端显示 **「正在重新连接 1/5 → 5/5」**，重连满 5 次才开始回复。同一个会话内之后正常，但每个新会话都要重来一遍。

受影响客户端：OpenAI **Codex 桌面版**，以及**内置 Codex 内核的 ChatGPT 桌面版**（Windows）。

### 根因

一句话：**Codex 的 Rust 后端默认不读 Windows 系统代理**，请求直连被墙 → 反复失败 → 客户端重试 5 次后降级到普通 HTTP。

三层决定「后端能不能出网」，必须**至少有一层**是通的：

```
                    ┌─────────────────────────────────────────┐
   Codex 后端进程 ──►│ 读 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY  │  ← 默认唯一认的
                    └─────────────────────────────────────────┘
                              ✗ 都不存在时
                    ┌─────────────────────────────────────────┐
                    │ 读 Windows 系统代理（WinHTTP 解析/PAC）   │  ← 需 respect_system_proxy = true
                    └─────────────────────────────────────────┘
                              ✗ 开关为 false 时
                    ┌─────────────────────────────────────────┐
                    │ 直连                                     │  ← 被墙 → 1/5 .. 5/5
                    └─────────────────────────────────────────┘
```

- 出站策略定义在 `codex-rs/http-client/src/outbound_proxy.rs`：`ReqwestDefault`（默认，只看环境变量）与 `RespectSystemProxy`（走 WinHTTP 解析系统代理/PAC）。
- 由 `codex-rs/core/src/config/mod.rs` 里的 `features.enabled(Feature::RespectSystemProxy)` 决定；该特性 key 为 `respect_system_proxy`，**默认 false**（`codex-rs/features/src/lib.rs`）。

### 快速开始

**方式 A —— 双击（不用碰命令行）**

不管你是 `git clone` 还是「Download ZIP」，拿到仓库后直接双击根目录里的文件：

| 双击这个 | 作用 |
| --- | --- |
| **`Diagnose.cmd`** | 体检。**只读**，不改任何东西 |
| **`Fix.cmd`** | 修复。动手前先备份，判断不安全就拒绝执行 |
| **`Rollback.cmd`** | 一键还原 |

这三个 `.cmd` 会自动处理下面那个「Windows 拦下脚本」的问题，你不需要改任何系统设置。

**方式 B —— 命令行**

```powershell
git clone https://github.com/cg689/codex-reconnect-fix.git
cd codex-reconnect-fix\scripts

.\Diagnose-CodexReconnect.ps1        # 1. 先体检（只读，不改任何东西）
.\Fix-CodexReconnect.ps1 -DryRun     # 2. 看一眼它打算改什么
.\Fix-CodexReconnect.ps1             # 3. 动手

# 4. 完全退出 Codex / ChatGPT 桌面端（含托盘）再启动，新建对话验证
```

> **如果命令行报错说「无法加载文件……未对文件进行数字签名」**：这不是脚本有问题，是 Windows 的默认拦截。两个原因叠在一起 ——
> ① Windows 默认执行策略是 `Restricted`，**任何 `.ps1` 都不让跑**；
> ② 「Download ZIP」解出来的文件带 Mark-of-the-Web 标记，即使策略是 `RemoteSigned` 也会被拦。
>
> 任选一种解法：改用**方式 A**（`.cmd` 已内置处理）；或者手动绕过：
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\Diagnose-CodexReconnect.ps1
> ```
>
> 域环境下若公司用组策略把 `Bypass` 也禁掉了，那只能把脚本内容贴进控制台执行 —— 这是企业策略，脚本无能为力。

无需管理员权限（只写 `HKCU`）。所有改动前自动备份，一条命令回滚：

```powershell
.\Rollback-CodexReconnect.ps1
```

### 脚本做了什么

| 步骤 | 动作 | 位置 |
| --- | --- | --- |
| 安全检查 | 确认目标端口真的在监听、且经它能连通 chatgpt.com。**不通过就拒绝执行** | — |
| 备份 | 复制 `config.toml`，并把当前系统代理值写进 `state.json` | `<CodexHome>\reconnect-fix-backups\<时间戳>\` |
| 修复 1 | `ProxyEnable=1`、`ProxyServer=127.0.0.1:<端口>` | `HKCU\...\Internet Settings` |
| 修复 2 | 在 `[features]` 下写入 `respect_system_proxy = true` | `<CodexHome>\config.toml` |

**为什么有那道安全检查**：把 Windows 系统代理指向一个**没人监听的端口**，会让整台机器断网（所有 HTTPS 请求都失败）。所以脚本在写注册表**之前**会先确认端口可用；不通过时它什么都不写，直接退出（退出码 `4`），并告诉你怎么继续。确认自己清楚风险时可以用 `-Force` 跳过。

这道检查分两层，`-SkipProxyCheck` 只会关掉第二层：

| 层 | 查什么 | 需要联网吗 | 能否跳过 |
| --- | --- | --- | --- |
| 存活 | 本地有没有进程在监听该端口（读内核 TCP 表） | 否 | **不能**（要跳过请用 `-Force`） |
| 链路 | 经该代理能不能连通 chatgpt.com | 是 | `-SkipProxyCheck` |

`Fix` 支持的参数：

```powershell
.\Fix-CodexReconnect.ps1 -DryRun                    # 只预览
.\Fix-CodexReconnect.ps1 -Port 7890                 # 指定代理端口
.\Fix-CodexReconnect.ps1 -SkipSystemProxy -SetEnvironmentVariables   # 只写环境变量，不碰系统代理
.\Fix-CodexReconnect.ps1 -SkipProxyCheck            # 跳过“联网链路”探测（机器还没联网时）；端口存活检查照跑
.\Fix-CodexReconnect.ps1 -Force                     # 跳过安全检查（含端口存活检查）
```

**不做的事**（很重要）：

- ❌ 不替换 `model_provider`。网上流行的「自定义 provider + `supports_websockets = false`」写法对 CLI 有效，但在桌面版上实测会**卡在启动界面**。
- ❌ 不动 `auth.json`、不动登录态、不动插件配置。
- ❌ 不装常驻进程、不建计划任务。
- ❌ 除目标两行外，`config.toml` 的其余内容（注释、空行、顺序、换行符）逐字节保留；重写时用 **UTF-8 无 BOM**（BOM 会让 Codex 的 TOML 解析失败）。

### 诊断输出长这样

```
[1] Windows system proxy  (HKCU\...\Internet Settings)
    OK   ProxyEnable           : 1 (on)
    OK   ProxyServer           : 127.0.0.1:10808
[2] Proxy environment variables
         HTTP_PROXY             : (not set)
         HTTPS_PROXY            : (not set)
[3] Codex config switch  [features] respect_system_proxy
    FAIL respect_system_proxy  : absent from [features]
[4] Proxy port reachability
    OK   127.0.0.1:10808       : accepting TCP connections
[5] End-to-end probes
    OK   via proxy (chatgpt.com): HTTP 403 Forbidden (tunnel OK)

-------------------------------------------------------------
 VERDICT: ROOT CAUSE FOUND
-------------------------------------------------------------
```

退出码：`Diagnose` 用 `0` 正常 / `1` 发现问题 / `2` 找不到 CodexHome；`Fix` 用 `0` 完成 / `1` 配置缺失 / `3` 写入失败 / `4` 被安全检查拒绝。适合接到你自己的巡检脚本里。加 `-ReportPath report.txt` 可把纯文本报告存盘，方便贴 issue。

### 端口是怎么自动识别的

不传 `-Port` 时，脚本按下面的顺序收集线索，然后**取第一个真的在监听的**（没人监听的端口只会让情况更糟）：

| 顺序 | 来源 |
| --- | --- |
| 1 | `-Port` 指定的 |
| 2 | 当前 Windows 系统代理设置里已写的端口 |
| 3 | 本机代理客户端配置文件里的入站端口（v2rayN / Clash / mihomo / sing-box / Xray） |
| 4 | 常见代理端口里正在监听的那个（Clash 7890/7897、v2rayN 10808、sing-box 2080…） |
| 5 | 上面都没命中时，退回一个**猜测值**并在报告里标明这是猜的 |
| 6 | 兜底 `10808` |

报告里会打印每个候选端口的**来源**和**是否在监听**，所以「端口猜错了」不会被误报成「代理挂了」。想换一个试：`-Port <n>`。

### 为什么代理开了还是不行

排查中遇到的另一种叠加情况：系统代理本身就处于**关闭**状态，端口字段还是别的工具（本例是某机场客户端的 `7688`）留下的残值。这时即使 `respect_system_proxy = true` 也没东西可用。`Diagnose` 会把这一层单独报出来。

如果问题是「系统代理被别的代理软件反复抢占」，那是另一个问题，用配套项目解决：

**[v2rayn-proxy-guard](https://github.com/cg689/v2rayn-proxy-guard)** —— 自动探测本机 v2rayN 端口并在系统代理被改写/关闭时夺回。

### 复发自查（30 秒）

1. 代理客户端的「系统代理」开关还开着吗？端口还是 `127.0.0.1:<你的端口>` 吗？
2. `~/.codex/config.toml` 的 `[features]` 里 `respect_system_proxy = true` 还在吗？（Codex 更新后可能重写配置）
3. 本地代理端口本身通不通？`Test-NetConnection 127.0.0.1 -Port 10808`

三条全 OK 还重连，问题在代理链路本身（节点失效 / 订阅过期 / 出站配置错），换节点试。

### 备选方案：用环境变量

不能改系统代理（或代理客户端互相抢）时，可以只靠环境变量让后端出网 —— 这是 `ReqwestDefault` 策略原生支持的路：

```powershell
.\Fix-CodexReconnect.ps1 -SetEnvironmentVariables -SkipSystemProxy
```

等价于把 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 写进**用户级**环境变量。注意：环境变量只对**之后启动**的进程生效，必须完全退出再启动客户端。

### 目录结构

```
codex-reconnect-fix/
├── Diagnose.cmd                       # 双击体检（自动处理执行策略与下载标记）
├── Fix.cmd                            # 双击修复
├── Rollback.cmd                       # 双击回滚
├── scripts/
│   ├── Diagnose-CodexReconnect.ps1    # 体检（只读）
│   ├── Fix-CodexReconnect.ps1         # 修复（安全检查 + 备份 + 两步改动）
│   └── Rollback-CodexReconnect.ps1    # 回滚
├── config/
│   └── config.example.toml            # 最小可用配置片段
└── docs/
    ├── 01-排查全过程.md                # 从社区线索到源码定性到对照实验
    ├── 02-源码级定位.md                # codex-rs 中的相关代码与结论
    └── 03-常见问题.md                  # FAQ 与踩坑
```

### 环境与适用范围

- Windows 10 / 11，Windows PowerShell 5.1 或 PowerShell 7+
- 验证版本：`codex-cli 0.153.x`（商店包 `OpenAI.Codex`），2026-09
- 其他代理客户端同理：只要它提供本地 HTTP 入站端口，`-Port` 指过去即可
- 三个 `.ps1` 全部是纯 ASCII、无 BOM —— PowerShell 5.1 在没有 BOM 时按 ANSI 解码文件，脚本里一旦出现非 ASCII 字符就会乱码甚至解析失败，这点是刻意规避的

### 已知遗留

- `respect_system_proxy` 被 OpenAI 标记为 under development，启动日志会有黄色警告。`config.example.toml` 里给了消除它的开关。
- 插件目录（`ps` / `mcp`）的 WebSocket 通道在代理下仍偶有报错，与聊天无关，可忽略。

### 致谢

思路起点是 linux.do 的两个帖子：《[一步到位解决 codex 的 reconnecting 5 次才回复](https://linux.do/t/topic/2161909)》《[ChatGPT APP 总是提示"正在重新连接 1/5"](https://linux.do/t/topic/2653201)》。它们的现象描述准确，但根因归到 WebSocket 上；本项目用源码和对照实验定位到了更底层的「后端进程从未走过代理」。

---

<a id="english"></a>
## English

**Fixes the `Reconnecting 1/5 .. 5/5` loop in the Codex and ChatGPT desktop apps on Windows.**

The Codex Rust backend never reads the Windows system proxy by default. It only honours
`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`. With no environment variable set, every request
goes out directly, gets blocked, and the client retries five times before falling back to
plain HTTP — which is exactly what "Reconnecting 1/5 .. 5/5" is.

Two options, both handled by the scripts:

1. **Turn on the official feature switch** — `[features] respect_system_proxy = true` in
   `~/.codex/config.toml` (see `codex-rs/http-client/src/outbound_proxy.rs`,
   `RespectSystemProxy`). Cleanest path, one line.
2. **Or set proxy environment variables** — `.\Fix-CodexReconnect.ps1 -SetEnvironmentVariables`.

**Easiest way in:** double-click the launchers in the repository root. No PowerShell
knowledge required.

| Double-click | What it does |
| --- | --- |
| `Diagnose.cmd` | Read-only health check. Changes nothing. |
| `Fix.cmd` | Applies the fix. Backs up first, refuses unsafe changes. |
| `Rollback.cmd` | Undoes everything. |

These wrappers exist because Windows blocks `.ps1` files out of the box (execution policy
`Restricted`) and additionally refuses files that came out of a downloaded ZIP. They handle
both, so you do not have to touch your system settings.

Or from a PowerShell window:

```powershell
cd scripts
.\Diagnose-CodexReconnect.ps1        # read-only health check, exits 1 when the cause is found
.\Fix-CodexReconnect.ps1 -DryRun     # preview
.\Fix-CodexReconnect.ps1             # apply (backs up config.toml and the current proxy state)
.\Rollback-CodexReconnect.ps1        # undo
```

If the bare `.ps1` call is blocked, prefix it:

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose-CodexReconnect.ps1
```

Then fully quit and restart the desktop app.

**Safety gate.** `Fix` refuses to point the Windows system proxy at a port that is not
accepting connections — that would take the whole machine offline. When it refuses, nothing
has been written and it exits with code `4`. Override with `-Force` only if you know the
proxy is about to come up.

The gate has two layers. The local liveness check (is anything listening on the port?) reads
the kernel TCP table and needs no internet, so it always runs. The remote chain check (can
traffic through the proxy reach chatgpt.com?) needs internet and is what `-SkipProxyCheck`
turns off. A dead port is refused either way; only `-Force` overrides that.

Deliberately **not** done: replacing `model_provider`. The forum-popular provider swap with
`supports_websockets = false` works for the CLI but hangs the desktop client on startup.

Requirements: Windows 10/11, PowerShell 5.1 or 7+, no admin rights (writes only to `HKCU`).
The three `.ps1` files are pure ASCII and carry no BOM on purpose: without a BOM,
PowerShell 5.1 decodes a script using the ANSI code page, so any non-ASCII character would
turn into garbage or break parsing.

Companion project for the "something keeps stealing my system proxy" case:
[v2rayn-proxy-guard](https://github.com/cg689/v2rayn-proxy-guard).

### License

[MIT](LICENSE)
