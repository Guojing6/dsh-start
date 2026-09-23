# DSH Start

一个用于启动 DeepSeek Harness Web 的 Windows 托盘启动器（`dsh --profile web`）。

## 功能

- 双击 `start-dsh.vbs` 后静默启动托盘程序，不弹出 PowerShell 控制台。
- 托盘在后台拉起 `dsh --profile web --no-open`，解析官方打印的认证 URL，并用它打开网页。
- **托盘已在运行时再次双击：立即打开已有服务**（不新起进程、不重启、几乎零等待）。
- 双击托盘图标打开网页；右键菜单支持重启服务、复制链接、开机自启、打开日志、退出。
- 服务就绪失败/子进程崩溃时自动退避重启，连续失败会放弃并弹出提示。
- 日志与状态写入脚本目录下的 `.dsh-tray\`（已被 `.gitignore` 忽略），路径可用 `DSH_TRAY_STATE_DIR` 覆盖。

## 文件

- `start-dsh.vbs`：隐藏窗口启动入口。
- `dsh-tray.ps1`：托盘控制器主脚本（v3）。
- `dsh-tray.config.json`：外置配置（端口、profile、重启策略等）。
- `harness-logo.png` / `harness-logo.ico`：托盘和窗口图标。
- `.githooks/pre-commit`：提交时校验 `dsh-tray.ps1` 的 UTF-8 BOM（见「注意」）。
- `.gitattributes`：固定 `.githooks/*` 的行尾为 LF。

## 版本

当前版本 **v3.1.0**（对应 `git tag v3.1.0`）。版本号定义在 `dsh-tray.ps1` 的 `$ScriptVersion`，
并暴露在几处便于核对：

- 托盘图标的提示文字：`DSH Web 3.1.0 · 3080 · 运行中`；
- 右键菜单底部的只读项：`版本 3.1.0`；
- `dsh-tray.log` 的启动行：`托盘启动 v3.1.0`；
- `-Headless` 自检输出的 `HEADLESS_RESULT` 里的 `version` 字段；`state.json` 里另有 `launcherVersion`。

> `state.json` 的 `version: 3` 是**状态文件 schema 版本**，与启动器版本无关，两者不要混用。

行为变更时递增 `$ScriptVersion` 并打同名 tag。

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

## 兼容性

启动器依赖的 dsh 契约只有三条，升级 dsh 后按此核对即可：

1. `dsh --profile <name> --port <n> --no-open` 能被接受（`--port 0` = 交给系统分配端口）；
2. 子进程 stdout 上出现 `dsh web: http://127.0.0.1:<port>/?token=…` 这一行；
3. 该 URL 请求返回 303 并种下签名 cookie（浏览器据此免 token 打开）。

**已在 `dsh` 0.1.7-alpha.2 上实测通过**（Windows PowerShell 5.1，隔离 `DSH_HOME` / 状态目录 / 端口）：

| 用例 | 结果 |
| --- | --- |
| 常规启动 | `ready`，~3–5 s（含全新 `DSH_HOME` 首次初始化），URL 行与解析正则完全吻合 |
| 认证链路 | URL → 303 → 跟随后 200 + 含 `__DSH_BOOT__` 的 HTML |
| 首选端口被占用 | 自动避让 `--port 0`，在系统分配的端口就绪，不碰占用者 |

0.1.6-alpha.2 → 0.1.7-alpha.2 的差异中，**承载上述契约的 `dsh-web-app/lib/index.js` 与
`lib/startup.js` 字节级未变**，CLI 的改动只涉及 `--dump-config-schema` 等 dump 模式，
因此启动器无需改动。升级后若启动失败，先看 `.dsh-tray\runs\run-*.out.log` / `.err.log`。

> 注意：dsh 会明确拒绝 `--host 0.0.0.0`（安全考虑），不要把它写进 `extraArgs`。

## 性能（本机实测）

从启动托盘到服务就绪（Windows PowerShell 5.1 + `dsh` 0.1.6-alpha.2 时测得，每个场景取 2 次测量均值；
0.1.7-alpha.2 下同机复测仍处同一量级，见上面「兼容性」）：

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
3. 在系统托盘中找到 `DSH Web` 图标，双击打开网页。

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

- 状态目录：脚本目录下的 `.dsh-tray\`（右键托盘「打开日志」）。

### 状态目录里的文件

- `dsh-tray.log`：托盘自身的决策日志；`runs\run-*.out.log` / `.err.log`：每次运行的 dsh 输出。
- `state.json`：当前跟踪的子进程与认证 URL，以及写入它的启动器版本（`launcherVersion`）。
- 启动器若放在只读位置（如 `Program Files`），把 `DSH_TRAY_STATE_DIR` 指到可写目录即可。
- 环境变量（主要用于测试）：`DSH_TRAY_CONFIG`、`DSH_TRAY_STATE_DIR`、`DSH_TRAY_NOBROWSER`、`DSH_TRAY_MUTEX`。

## 从 v2 迁移

- 日志/状态在脚本目录的 `.dsh-tray\`（更早的 v3 版本放在 `%LOCALAPPDATA%\dsh-tray`，确认不再需要后可删除）。
- 单实例互斥体改名为 `DSHWebTray.v3`，与 v2 的 `DSHWebTray` 互不影响。
- **行为变化**：v2 会「接管」端口上已在运行的 dsh（并在识别失败时强杀端口占用者）；
  v3 不再做任何接管或强杀——端口被占用就另起一个（`--port 0`）。
- 浏览器 cookie 与 `host:port` 绑定（默认有效期 30 天），所以**保持端口稳定**才能长期免 token 打开；
  端口变化时用托盘的「打开网页 / 复制链接」重新认证一次即可。

## 注意

`dsh-tray.ps1` 含中文注释，必须保存为 **UTF-8 with BOM**。

丢掉 BOM 的后果比想象中严重：Windows PowerShell 5.1 会按 ANSI 解码，脚本**直接解析失败**
（实测报 `Unexpected token '}'` / `Missing '=' operator after key in hash literal`）。而 `start-dsh.vbs`
是以隐藏窗口拉起托盘的，所以这个失败是**静默**的——没有托盘图标、没有日志、没有提示。
PowerShell 7 / VS Code 里又完全看不出异常，因此很容易漏掉。

### 提交时拦截

仓库用 `.githooks/pre-commit` 在提交时校验 BOM：

```powershell
git config core.hooksPath .githooks      # 新克隆后执行一次
```

hook 检查的是**索引里的 blob**（即真正要提交的内容），缺 BOM 会直接拒绝提交并打印修复命令；
临时跳过用 `git commit --no-verify`。

### 手动核对与修复

```powershell
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path 'dsh-tray.ps1'))
$bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF   # 必须为 True

# 需要补回 BOM 时：
$p = (Resolve-Path 'dsh-tray.ps1').Path
[System.IO.File]::WriteAllText($p, [System.IO.File]::ReadAllText($p), (New-Object System.Text.UTF8Encoding($true)))
git add dsh-tray.ps1
```

> 已实测：`git checkout` 会保留 blob 里的 BOM，所以只要提交进去的版本带 BOM，任何克隆出来的副本都正常，
> 风险只在「本地改写后提交」这一步——正是 hook 拦的位置。另外 `.githooks/*` 在 `.gitattributes` 里固定为 LF：
> `core.autocrlf` 会给 Git 自带的 sh 一个 CRLF 脚本，那样 hook 根本跑不起来。
