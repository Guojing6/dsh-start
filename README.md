# DSH Start

一个用于启动 DeepSeek Harness Web 的 Windows 托盘启动器（`dsh --profile web`）。

## 功能

- 双击 `start-dsh.vbs` 后静默启动托盘程序，不弹出 PowerShell 控制台。
- 托盘在后台拉起 `dsh --profile web --no-open`，解析官方打印的认证 URL，并用它打开 Web UI。
- **托盘已在运行时再次双击：立即打开已有服务**（不新起进程、不重启、几乎零等待）。
- 双击托盘图标打开 Web UI；右键菜单支持重启服务、复制带 token 的网址、开机自启、打开状态目录、退出。
- 服务就绪失败/子进程崩溃时自动退避重启，连续失败会放弃并弹出提示。
- 日志与状态写入 `%LOCALAPPDATA%\dsh-tray`，不污染脚本目录。

## 文件

- `start-dsh.vbs`：隐藏窗口启动入口。
- `dsh-tray.ps1`：托盘控制器主脚本（v3）。
- `dsh-tray.config.json`：外置配置（端口、profile、重启策略等）。
- `harness-logo.png` / `harness-logo.ico`：托盘和窗口图标。

## 设计契约

重写版本的核心是把「集成契约」做对，而不是换语言：

1. **只管理自己启动的子进程**。不按端口杀进程、不抢占他人端口、不用 WMI 猜进程身份。
   进程归属靠「pid + 启动时刻」证明，PID 被复用时不会误认。
2. **就绪与认证 URL 只来自本次运行独占的 stdout 日志**（`runs/run-*.out.log`）。
   官方把 `dsh web:` 这一行定义为监督方的就绪信号；token 是每进程随机生成、不落盘、不可推导的，
   所以只能观测不能计算——复用上一次的共享日志必然拿到过期 token。
3. **端口被占用就避让**：首选端口忙则改用 `--port 0` 让系统分配，实际端口从 URL 行解析。
4. **状态 JSON 原子读写**（`state.json`：pid / 启动时刻 / 端口 / URL / 日志路径），
   可跨托盘重启复用「自己此前启动的」实例；拿不到 URL 时能从那次的日志里恢复。
5. **native 命令失败绝不能让托盘崩掉**：`$ErrorActionPreference='Stop'` 下 `taskkill` 的
   stderr 会变成终止性错误，因此停止进程有 try/catch + 托管 API 兜底。

## 性能（本机实测）

从启动托盘到服务就绪（Windows PowerShell 5.1 + `dsh` 0.1.6-alpha.2，每个场景取 2 次测量均值）：

| 场景 | 优化前 | 优化后 |
| --- | --- | --- |
| 冷启动：托盘 → 服务就绪 | 2700 ms | **1605 ms** |
| 冷启动：托盘 → 子进程已拉起 | ~1150 ms | **~430 ms** |
| 托盘常驻时再次双击快捷方式 | 无任何反应 | **即时打开**（不新起服务） |

参考基线：`dsh` 自身从进程启动到打印 URL 行约 1170–1240 ms。实测 `dsh.cmd` 与直接 `node bin.js`
的差异落在噪声内（1240 ms vs 1204 ms），所以**没有**改这一处——省掉 cmd.exe 中转不值得增加复杂度。

做了四件事：

1. **冷启动不再白等 800ms**：原先无论有没有旧进程都先睡 800ms 等端口释放；现在只有真的杀过进程才等。
2. **先拉服务、再建托盘 UI**：`Add-Type`、图标、菜单的初始化与 dsh 启动并行，不再串行叠加。
3. **轮询自适应**：启动期 100ms（原 250ms）更快撞上 URL 行，就绪后降到 1s 减少空转。
4. **二次启动直接复用**：托盘已在运行时，读状态文件里属于该进程的认证 URL 直接打开，省掉整个冷启动。

剩余 ~1600ms 里约 1200ms 是 dsh 自身的启动、约 300–400ms 是 `powershell.exe` 的启动，已接近本架构下限。
想再快只有两条路：保持常驻（登录自启已开着，配合第 4 条即为「瞬时打开」），或改用编译型启动器。

## 配置

`dsh-tray.config.json`（留空/缺省即用默认值）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `profile` | `web` | 传给 dsh 的 `--profile` |
| `preferredPort` | `3080` | 首选端口；被占用则自动改用 `--port 0` |
| `autoOpen` | `true` | 就绪后自动打开浏览器 |
| `readyTimeout` | `45` | 等 URL 行的秒数 |
| `restartMax` | `5` | 连续「快速失败」次数上限 |
| `restartDelays` | `[1,2,4,8,15]` | 退避秒数（按失败次数取用） |
| `rapidExitSec` | `10` | 存活不足该秒数算「快速失败」 |
| `keepRunLogs` | `10` | 保留最近几次运行的日志 |
| `extraArgs` | `[]` | 追加给 dsh 的参数（例如 `--trusted-host`） |
| `dshExecutable` | `""` | 留空 = 用 PATH 上的 `dsh.cmd`；可指定绝对路径 |
| `dshArgsPrefix` | `[]` | 插在 `--profile` 之前的参数（例如指向自定义包装脚本） |

> 注意：不要关闭 dsh 的 `printUrl`（默认 true）。启动器依赖 `dsh web:` 这一行来获得认证 URL。

## 使用

1. 确保已经安装 Node.js 和 `@deepseek-ai/dsh`。
2. 双击 `start-dsh.vbs` 启动。
3. 在系统托盘中找到 `DSH Web` 图标，双击打开 Web UI。

## 自检

托盘脚本自带无头模式（`-Headless`）：不起托盘图标、不阻塞，跑完「启动 → 就绪」就退出，
并用一行 `HEADLESS_RESULT {…}` 输出结果，便于人工或脚本核对。

验证真实 dsh 的认证链路（隔离 `DSH_HOME`，先把 `preferredPort` 换成空闲端口）：

```powershell
$env:DSH_HOME = "$env:TEMP\dsh-e2e-home"
powershell -NoProfile -ExecutionPolicy Bypass -File dsh-tray.ps1 -Headless -HeadlessLinger 20
# 用输出里的 url 请求一次：应返回 303 并带上 Set-Cookie
```

## 排查

- 状态目录：`%LOCALAPPDATA%\dsh-tray`（右键托盘「打开状态目录」）。
- `dsh-tray.log`：托盘自身的决策日志；`runs\run-*.out.log` / `.err.log`：每次运行的 dsh 输出。
- `state.json`：当前跟踪的子进程与认证 URL。
- 环境变量（主要用于测试）：`DSH_TRAY_CONFIG`、`DSH_TRAY_STATE_DIR`、`DSH_TRAY_NOBROWSER`、`DSH_TRAY_MUTEX`。

## 从 v2 迁移

- 日志/状态在 `%LOCALAPPDATA%\dsh-tray`（v2 时代放在脚本目录的 `.dsh-tray\` 已弃用并删除）。
- 单实例互斥体改名为 `DSHWebTray.v3`，与 v2 的 `DSHWebTray` 互不影响。
- **行为变化**：v2 会「接管」端口上已在运行的 dsh（并在识别失败时强杀端口占用者）；
  v3 不再做任何接管或强杀——端口被占用就另起一个（`--port 0`）。
- 浏览器 cookie 与 `host:port` 绑定（默认有效期 30 天），所以**保持端口稳定**才能长期免 token 打开；
  端口变化时用托盘的「打开 Web UI / 复制带 token 的网址」重新认证一次即可。

## 注意

`dsh-tray.ps1` 含中文注释，必须保存为 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会读成乱码。
