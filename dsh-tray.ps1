#Requires -Version 5.1
# =============================================================================
# DSH Web 托盘控制器 v3（精简重写版）
# 与 start-dsh.vbs 同目录，双击 start-dsh.vbs 启动。
#
# 设计契约 —— 上一版所有故障的根因都在这里被切断：
#  1) 只管理「自己启动的」子进程：不按端口杀进程、不抢占他人端口、不用 WMI 猜身份。
#  2) 就绪与认证 URL 只来自「本次运行独占」的 stdout 日志。官方把 URL 行定义为监督方的
#     就绪信号（@deepseek-ai/dsh-web-app README.zh.md:84）。token 是每进程随机生成、不落盘、
#     不可推导的，所以只能观测不能计算；复用上一次的共享日志必然拿到过期 token。
#  3) 端口被占用就避让（--port 0 交给系统分配），而不是 taskkill 掉占用者。
#  4) 状态 JSON 原子读写；用 pid + 启动时刻证明「这是我的孩子」，可跨托盘重启复用自己此前
#     启动的实例，且 PID 被复用时不会误认。
#  5) -Headless 自检模式：不起托盘、不阻塞消息循环，跑完「启动 → 就绪」即输出结果并退出。
#
# 注意：本文件含中文，必须保存为 "UTF-8 with BOM"，否则 Windows PowerShell 5.1 显示乱码。
# =============================================================================
[CmdletBinding()]
param(
    [switch]$Headless,
    [int]$HeadlessLinger = 0,
    [int]$HeadlessTimeout = 45
)

$ErrorActionPreference = 'Stop'

# 无头模式下让 stdout 明确为 UTF-8，便于测试脚本稳定读取（含中文日志行）
if ($Headless) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

# ---------------------------------------------------------------- 路径与开关
$ScriptDir  = $PSScriptRoot
$VbsPath    = Join-Path $ScriptDir 'start-dsh.vbs'
$ConfigPath = if ($env:DSH_TRAY_CONFIG)    { $env:DSH_TRAY_CONFIG }    else { Join-Path $ScriptDir 'dsh-tray.config.json' }
# 默认与启动器同目录（.dsh-tray\），便于「打开日志」直接定位；该目录已被 .gitignore 忽略。
# 启动器放在只读位置（如 Program Files）时，用 DSH_TRAY_STATE_DIR 指到可写目录。
$StateDir   = if ($env:DSH_TRAY_STATE_DIR) { $env:DSH_TRAY_STATE_DIR } else { Join-Path $ScriptDir '.dsh-tray' }
$RunLogDir  = Join-Path $StateDir 'runs'
$StateFile  = Join-Path $StateDir 'state.json'
$TrayLog    = Join-Path $StateDir 'dsh-tray.log'
$MutexName  = if ($env:DSH_TRAY_MUTEX) { $env:DSH_TRAY_MUTEX } else { 'DSHWebTray.v3' }

$RunKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'DSH Web Tray'
$IconFile = Join-Path $ScriptDir 'harness-logo.png'

# 自动化测试开关：置 1（或无头模式）时绝不真正打开浏览器
$TestNoBrowser = ($env:DSH_TRAY_NOBROWSER -eq '1') -or $Headless

New-Item -ItemType Directory -Force -Path $StateDir, $RunLogDir | Out-Null

# ------------------------------------------------------------------- 配置
function Read-Config {
    $cfg = @{
        profile       = 'web'
        preferredPort = 3080
        autoOpen      = $true
        readyTimeout  = 45      # 秒，等 URL 行的上限
        restartMax    = 5       # 连续「快速失败」次数上限，超过就放弃并提示
        restartDelays = @(1, 2, 4, 8, 15)   # 秒，指数退避
        rapidExitSec  = 10      # 存活不足这个秒数算「快速失败」
        keepRunLogs   = 10
        extraArgs     = @()
        dshExecutable = ''      # 留空 = 自动探测 PATH 上的 dsh.cmd；测试可覆盖
        dshArgsPrefix = @()     # 在 --profile 之前插入的参数（测试用假 dsh 时用）
    }
    if (Test-Path $ConfigPath) {
        try {
            $user = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($user.PSObject.Properties.Name -contains $k) { $cfg[$k] = $user.$k }
            }
        } catch {
            Write-TrayLog ("配置读取失败，改用默认值：" + $_.Exception.Message)
        }
    }
    return $cfg
}

$Config = Read-Config

# ------------------------------------------------------------------- 日志
function Write-TrayLog {
    param([string]$Message)
    try {
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message
        Add-Content -Path $TrayLog -Value $line -Encoding UTF8
        if ($Headless) { Write-Host ("[tray] " + $Message) }
    } catch { }
}

function Get-LogTail {
    param([string]$Path, [int]$Lines = 5)
    if (-not $Path -or -not (Test-Path $Path)) { return '' }
    try {
        $t = (Get-Content $Path -Tail $Lines -ErrorAction Stop) -join ' / '
        return $t.Trim()
    } catch { return '' }
}

function ConvertTo-AsciiJson {
    # 把结果 JSON 转成纯 ASCII（非 ASCII 转义成 \uXXXX）：无论控制台代码页是 GBK 还是
    # UTF-8，测试脚本都能稳定解析这一行机器可读结果。
    param($Object)
    $json = $Object | ConvertTo-Json -Compress -Depth 5
    if ($null -eq $json) { return 'null' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 32 -or $code -gt 126) { $null = $sb.AppendFormat('\u{0:x4}', $code) }
        else { $null = $sb.Append($ch) }
    }
    return $sb.ToString()
}

# ------------------------------------------------------- 状态文件（原子读写）
function Save-State {
    try {
        $state = [ordered]@{
            version    = 3
            pid        = $script:ChildPid
            startedAt  = $script:ChildStartUnix
            port       = $script:ActualPort
            url        = $script:WebUrl
            logFile    = $script:RunOutLog
            errFile    = $script:RunErrLog
            profile    = $Config.profile
            state      = $script:State
            restarts   = $script:RestartCount
            updatedAt  = (Get-Date).ToString('o')
        }
        $tmp = $StateFile + '.tmp'
        ($state | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $StateFile -Force
    } catch {
        Write-TrayLog ("状态写入失败：" + $_.Exception.Message)
    }
}

function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    try { return (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# --------------------------------------------------------------- 进程身份
function Get-ChildAlive {
    # 只用 pid + 启动时刻证明身份：WMI 命令行在受限环境会失败，且失败原因无法与
    # 「不是我们的进程」区分；pid 复用则会被启动时刻识破。
    param([int]$ProcessId, [int64]$StartUnix)
    if (-not $ProcessId) { return $null }
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    if ($StartUnix) {
        try { $actual = [int64](([DateTimeOffset]$p.StartTime).ToUnixTimeSeconds()) }
        catch { return $null }
        if ([Math]::Abs($actual - $StartUnix) -gt 5) { return $null }
    }
    return $p
}

function Get-PortFromUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    try { return ([uri]$Url).Port } catch { return $null }
}

function Test-PortFree {
    # 用真实 bind 判断，不依赖 Get-NetTCPConnection（在受限环境下不可靠）
    param([int]$Port)
    if ($Port -le 0) { return $true }
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch { return $false }
    finally { if ($listener) { try { $listener.Stop() } catch { } } }
}

# --------------------------------------------------------------- 服务管理
function Resolve-DshExecutable {
    if ($Config.dshExecutable) {
        if (-not (Test-Path $Config.dshExecutable)) { throw ("配置的 dshExecutable 不存在：" + $Config.dshExecutable) }
        return $Config.dshExecutable
    }
    foreach ($name in @('dsh.cmd', 'dsh.exe', 'dsh')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    throw 'PATH 上找不到 dsh 命令：请先 npm i -g @deepseek-ai/dsh，或在 dsh-tray.config.json 里设置 dshExecutable'
}

function Quote-Arg {
    # Start-Process 不会可靠地给数组元素加引号；本仓库路径含空格，必须自己处理
    param([string]$Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Remove-OldRunLogs {
    try {
        $keep = [int]$Config.keepRunLogs
        if ($keep -le 0) { return }
        Get-ChildItem $RunLogDir -Filter 'run-*.log' |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $keep |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Start-DshChild {
    $dsh = Resolve-DshExecutable

    $port = [int]$Config.preferredPort
    $script:PortAvoided = $false
    if (-not (Test-PortFree $port)) {
        Write-TrayLog ("端口 $port 已被占用：改用 --port 0 让系统分配（不抢占、不杀他人进程）")
        $script:PortAvoided = $true
        $port = 0
    }

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $script:RunOutLog = Join-Path $RunLogDir ("run-$stamp.out.log")
    $script:RunErrLog = Join-Path $RunLogDir ("run-$stamp.err.log")

    $argList = @()
    $argList += @($Config.dshArgsPrefix)
    $argList += @('--profile', [string]$Config.profile, '--port', "$port", '--no-open')
    $argList += @($Config.extraArgs)
    $argString = ($argList | ForEach-Object { Quote-Arg ([string]$_) }) -join ' '

    Write-TrayLog ("启动子进程：" + $dsh + ' ' + $argString)
    $p = Start-Process -FilePath $dsh -ArgumentList $argString -WindowStyle Hidden `
        -RedirectStandardOutput $script:RunOutLog -RedirectStandardError $script:RunErrLog -PassThru

    $script:ChildPid       = [int]$p.Id
    $script:ChildStartUnix = [int64](([DateTimeOffset]$p.StartTime).ToUnixTimeSeconds())
    $script:ChildStartedAt = Get-Date
    $script:WebUrl         = $null
    $script:ActualPort     = $null
    $script:Deadline       = (Get-Date).AddSeconds([int]$Config.readyTimeout)

    Remove-OldRunLogs
    Save-State
}

function Stop-OwnChild {
    # 只停自己启动并已证明身份的进程树。
    # 关键：native 命令失败绝不能把托盘带崩——$ErrorActionPreference='Stop' 之下，
    # taskkill 写到 stderr 的任何一行（例如「拒绝访问」）都会变成终止性错误。
    if (-not $script:ChildPid) { return }
    $pidToStop = $script:ChildPid
    $alive = Get-ChildAlive -ProcessId $pidToStop -StartUnix $script:ChildStartUnix
    if ($alive) {
        Write-TrayLog ("停止自己的子进程树 pid=" + $pidToStop)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & taskkill.exe /PID $pidToStop /T /F 2>&1 | Out-Null
            for ($i = 0; $i -lt 20; $i++) {
                if (-not (Get-Process -Id $pidToStop -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 100
            }
            # taskkill 被拒（权限/沙箱）时的兜底：用托管 API 结束它
            if (Get-Process -Id $pidToStop -ErrorAction SilentlyContinue) {
                Write-TrayLog 'taskkill 未生效，改用 Stop-Process 兜底'
                Stop-Process -Id $pidToStop -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-TrayLog ('停止子进程时出错（忽略并继续）：' + $_.Exception.Message)
        } finally { $ErrorActionPreference = $prev }

        if (Get-Process -Id $pidToStop -ErrorAction SilentlyContinue) {
            Write-TrayLog ("警告：子进程 pid=" + $pidToStop + " 仍未退出，已不再跟踪它")
        }
    }
    $script:ChildPid       = $null
    $script:ChildStartUnix = $null
    $script:ChildStartedAt = $null
}

# ------------------------------------------------------------- 就绪判据
function Get-WebUrlFromRunLog {
    # 唯一就绪信号：本次运行独占日志里的 URL 行（官方定义的监督信号）
    if (-not $script:RunOutLog -or -not (Test-Path $script:RunOutLog)) { return $null }
    try {
        $line = Get-Content $script:RunOutLog -Tail 30 -ErrorAction Stop |
            Where-Object { $_ -match 'dsh web:\s+(http://\S+)' } |
            Select-Object -Last 1
        if ($line -and $line -match 'dsh web:\s+(http://\S+)') { return $Matches[1] }
    } catch { }
    return $null
}

function Open-WebBrowser {
    if ($TestNoBrowser) { return }
    $url = $script:WebUrl
    if ([string]::IsNullOrWhiteSpace($url)) { return }
    try { [System.Diagnostics.Process]::Start($url) | Out-Null }
    catch { Write-TrayLog ("打开浏览器失败：" + $_.Exception.Message) }
}

# ------------------------------------------------------- 托盘界面（可无头）
function Show-Toast {
    param([string]$Text, [string]$Kind = 'Info')
    Write-TrayLog ("提示[" + $Kind + "]：" + $Text)
    if ($Headless -or -not $script:Icon) { return }
    try {
        $iconKind = [System.Windows.Forms.ToolTipIcon]::Info
        if ($Kind -eq 'Error') { $iconKind = [System.Windows.Forms.ToolTipIcon]::Error }
        $script:Icon.ShowBalloonTip(5000, 'DSH Web', $Text, $iconKind)
    } catch { }
}

function Update-TrayText {
    if ($Headless -or -not $script:Icon) { return }
    $label = switch ($script:State) {
        'ready'   { '运行中' }
        'wait'    { '启动中' }
        'delay'   { '启动中' }
        'failed'  { '已停止' }
        default   { '空闲' }
    }
    $portText = if ($script:ActualPort) { [string]$script:ActualPort } else { [string]$Config.preferredPort }
    $text = "DSH Web · $portText · $label"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }   # NotifyIcon.Text 上限
    try { $script:Icon.Text = $text } catch { }
}

# ------------------------------------------------------------- 状态机
$script:State          = 'idle'   # idle | delay | wait | ready | failed
$script:ActionAt       = $null
$script:Deadline       = $null
$script:ChildPid       = $null
$script:ChildStartUnix = $null
$script:ChildStartedAt = $null
$script:RunOutLog      = $null
$script:RunErrLog      = $null
$script:WebUrl         = $null
$script:ActualPort     = $null
$script:PortAvoided    = $false
$script:Stopping       = $false
$script:AutoOpenPending = $true
$script:RapidFailures  = 0
$script:RestartCount   = 0
$script:LastFailReason = $null

function Set-PollInterval {
    # 启动期高频轮询（更快撞上 URL 行），就绪后降到 1s，减少空转
    param([int]$Ms)
    if ($script:Timer -and $script:Timer.Interval -ne $Ms) { $script:Timer.Interval = $Ms }
}

function Begin-Restart {
    param([int]$DelayMs = 800, [bool]$AutoOpen = $true)
    $script:WebUrl          = $null
    $script:ActualPort      = $null
    $script:AutoOpenPending = $AutoOpen
    $script:State           = 'delay'
    $script:ActionAt        = (Get-Date).AddMilliseconds($DelayMs)
    $script:Deadline        = (Get-Date).AddSeconds([int]$Config.readyTimeout)
    Set-PollInterval 100
    Update-TrayText
    Save-State
}

function Restart-Service {
    # 冷启动 / 用户主动重启
    $hadChild = [bool]$script:ChildPid
    if ($hadChild) {
        $script:Stopping = $true
        Stop-OwnChild
        $script:Stopping = $false
    }
    $script:RapidFailures = 0
    Write-TrayLog '重启服务'
    if ($hadChild) {
        # 只有刚杀过进程才需要等端口释放：否则会掉到 --port 0 上，而浏览器 cookie 与端口绑定
        Begin-Restart -DelayMs 800 -AutoOpen $true
        return
    }
    # 冷启动：立刻拉起，不进 delay 状态、也不等第一次 tick（省掉原先白等的 800ms）
    Set-PollInterval 100
    try {
        Start-DshChild
        $script:State = 'wait'
        $script:AutoOpenPending = $true
        Update-TrayText
        Save-State
    } catch {
        Fail-Service ('启动失败：' + $_.Exception.Message)
    }
}

function Fail-Service {
    param([string]$Reason)
    $script:State = 'failed'
    $script:WebUrl = $null
    $script:LastFailReason = $Reason
    Update-TrayText
    Save-State
    Show-Toast ($Reason + '；日志见 ' + $StateDir) 'Error'
}

function Set-Ready {
    param([string]$Url)
    $script:WebUrl     = $Url
    $script:ActualPort = Get-PortFromUrl $Url
    $script:State      = 'ready'
    $script:RapidFailures = 0
    Set-PollInterval 1000   # 就绪后降频，只留崩溃探测
    Write-TrayLog ("服务就绪 port=" + $script:ActualPort + " pid=" + $script:ChildPid + " url=" + $Url)
    Update-TrayText
    Save-State
    if ($script:AutoOpenPending) {
        $script:AutoOpenPending = $false
        if ($Config.autoOpen) { Open-WebBrowser }
    }
}

function Handle-ChildExit {
    param([string]$Reason)
    if ($script:Stopping) { return }
    $lived = 999
    if ($script:ChildStartedAt) { $lived = ((Get-Date) - $script:ChildStartedAt).TotalSeconds }
    $errTail = Get-LogTail $script:RunErrLog 3
    Write-TrayLog ($Reason + "（存活 " + [int]$lived + " 秒）" + $(if ($errTail) { ' stderr: ' + $errTail } else { '' }))

    if ($lived -lt [int]$Config.rapidExitSec) { $script:RapidFailures++ } else { $script:RapidFailures = 0 }

    $script:ChildPid = $null
    $script:ChildStartUnix = $null

    if ($script:RapidFailures -gt [int]$Config.restartMax) {
        Fail-Service ("服务连续 " + $script:RapidFailures + " 次启动失败，已放弃自动重启")
        return
    }
    $delays = @($Config.restartDelays)
    if ($delays.Count -eq 0) { $delays = @(1) }
    $idx = [Math]::Min([Math]::Max($script:RapidFailures - 1, 0), $delays.Count - 1)
    $delaySec = [int]$delays[$idx]
    $script:RestartCount++
    Write-TrayLog ("第 " + $script:RestartCount + " 次自动重启，等待 " + $delaySec + " 秒")
    Begin-Restart -DelayMs ($delaySec * 1000) -AutoOpen $false
}

function Invoke-Tick {
    if ($script:Stopping) { return }
    switch ($script:State) {
        'delay' {
            if ((Get-Date) -ge $script:ActionAt) {
                try { Start-DshChild; $script:State = 'wait'; Update-TrayText }
                catch { Fail-Service ('启动失败：' + $_.Exception.Message) }
            }
        }
        'wait' {
            $url = Get-WebUrlFromRunLog
            if ($url) { Set-Ready $url; return }
            $alive = Get-ChildAlive -ProcessId $script:ChildPid -StartUnix $script:ChildStartUnix
            if (-not $alive) { Handle-ChildExit -Reason '进程在宣告 URL 之前退出'; return }
            if ((Get-Date) -ge $script:Deadline) {
                $errTail = Get-LogTail $script:RunErrLog 3
                # 超时就先收掉自己的孩子，避免留下一个拿不到认证 URL 的孤儿服务
                $script:Stopping = $true
                Stop-OwnChild
                $script:Stopping = $false
                Fail-Service ('服务启动超时（' + [int]$Config.readyTimeout + ' 秒）' + $(if ($errTail) { '：' + $errTail } else { '' }))
            }
        }
        'ready' {
            $alive = Get-ChildAlive -ProcessId $script:ChildPid -StartUnix $script:ChildStartUnix
            if (-not $alive) { Handle-ChildExit -Reason '服务进程意外退出' }
        }
    }
}

function Try-AdoptExisting {
    # 复用「自己此前启动的」实例：pid + 启动时刻一致才算数；拿不到认证 URL 就重启它。
    # 绝不触碰无法证明属于我们的进程。
    $st = Read-State
    if (-not $st -or -not $st.pid) { return $false }
    if (-not $st.startedAt) {
        # 没有启动时刻就无法证明这个 pid 是我们的（PID 可能已被复用）——只清状态，绝不动进程
        Write-TrayLog '状态文件缺少启动时刻，无法证明进程归属：清理状态后重新启动'
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    $alive = Get-ChildAlive -ProcessId ([int]$st.pid) -StartUnix ([int64]$st.startedAt)
    if (-not $alive) {
        Write-TrayLog '状态文件里的进程已不存在（或 PID 被复用）：清理状态后重新启动'
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    $script:ChildPid       = [int]$st.pid
    $script:ChildStartUnix = [int64]$st.startedAt
    $script:RunOutLog      = $st.logFile
    $script:RunErrLog      = $st.errFile

    $url = $st.url
    if ([string]::IsNullOrWhiteSpace($url)) { $url = Get-WebUrlFromRunLog }   # 从自己的旧日志里恢复
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-TrayLog '确认是自己的子进程，但已恢复不出认证 URL：重启它以恢复'
        $script:Stopping = $true
        Stop-OwnChild
        $script:Stopping = $false
        return $false
    }
    $script:WebUrl     = $url
    $script:ActualPort = Get-PortFromUrl $url
    $script:State      = 'ready'
    Set-PollInterval 1000
    Write-TrayLog ("复用自己此前启动的实例 pid=" + $script:ChildPid + " port=" + $script:ActualPort)
    # 复用成功同样要按配置打开 UI（修复：此前接管后不会自动打开浏览器）
    if ($script:AutoOpenPending) {
        $script:AutoOpenPending = $false
        if ($Config.autoOpen) { Open-WebBrowser }
    }
    return $true
}

function Get-ExistingInstanceUrl {
    # 已有托盘在运行：不另起服务，直接返回那个实例当前可用的认证 URL（没有就返回 $null）。
    # 这让「托盘常驻时再双击快捷方式」变成瞬时打开，省掉整个冷启动。
    # 注意：函数内不要用 Write-Output —— 它的输出会成为本函数的「返回值」被调用方取走。
    $deadline = (Get-Date).AddSeconds([int]$Config.readyTimeout)
    while ((Get-Date) -lt $deadline) {
        $st = Read-State
        if ($st -and $st.url -and $st.startedAt -and
            (Get-ChildAlive -ProcessId ([int]$st.pid) -StartUnix ([int64]$st.startedAt))) {
            Write-TrayLog ('直接打开运行中的服务：' + $st.url)
            if (-not $TestNoBrowser) {
                try { [System.Diagnostics.Process]::Start($st.url) | Out-Null } catch { }
            }
            return [string]$st.url
        }
        Start-Sleep -Milliseconds 150
    }
    Write-TrayLog '已有托盘实例在运行，但等待其就绪超时'
    return $null
}

# ------------------------------------------------------------ 开机自启
function Get-AutoStart {
    return (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue) -ne $null
}
function Set-AutoStart {
    param([bool]$On)
    if ($On) { Set-ItemProperty -Path $RunKey -Name $RunName -Value ('wscript.exe "{0}"' -f $VbsPath) }
    else     { Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue }
}

# ================================================================ 主流程
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) }
    catch {
        # 前任被强杀时 WaitOne 抛「abandoned mutex」——此时所有权已归我们，视为获取成功
        if ($_.Exception.InnerException -is [System.Threading.AbandonedMutexException]) { $acquired = $true }
        else { throw }
    }
    if (-not $acquired) {
        if ($Headless) {
            # 无头自测需要多实例隔离，继续往下跑
            Write-TrayLog '已有托盘实例在运行（无头模式：继续以便测试隔离）'
        } else {
            # 桌面快捷方式再点一次 = 立即打开已有服务的 UI，而不是静默退出
            Write-TrayLog '已有托盘实例在运行：直接打开已有服务'
            $existingUrl = Get-ExistingInstanceUrl
            if ($existingUrl) { Write-Output ('OPEN_EXISTING ' + $existingUrl) }   # 留一条 stdout 信号，便于外部脚本/人工核对
            if ($mutex) { try { $mutex.Dispose() } catch { } }
            exit 0
        }
    }
} catch {
    Write-TrayLog ('单实例检查异常，继续运行：' + $_.Exception.Message)
}

Write-TrayLog ('托盘启动' + $(if ($Headless) { '（无头模式）' } else { '' }))

# ------------------------------------------------------------ 无头自测模式
if ($Headless) {
    $headlessError = $null
    try {
        if (-not (Try-AdoptExisting)) { Restart-Service }
        $deadline = (Get-Date).AddSeconds($HeadlessTimeout)
        $lingerUntil = $null
        while ($true) {
            try { Invoke-Tick } catch { Fail-Service ('内部异常：' + $_.Exception.Message) }
            if ($script:State -eq 'ready') {
                if ($HeadlessLinger -le 0) { break }
                if (-not $lingerUntil) { $lingerUntil = (Get-Date).AddSeconds($HeadlessLinger) }
                if ((Get-Date) -ge $lingerUntil) { break }
            }
            if ($script:State -eq 'failed') { break }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Milliseconds 100
        }
    } catch {
        # 任何意外都不能让脚本「无结果地静默退出」——否则测试只能看到一个空白的退出码
        $headlessError = $_.Exception.Message
    }

    $finalState = $script:State
    if ($headlessError) { $finalState = 'error' }

    # 先取快照，再清理子进程（Stop-OwnChild 会把 pid 清空）
    $snapshot = [ordered]@{
        state         = $finalState
        ready         = ($finalState -eq 'ready')
        pid           = $script:ChildPid
        port          = $script:ActualPort
        url           = $script:WebUrl
        restarts      = $script:RestartCount
        rapidFailures = $script:RapidFailures
        portAvoided   = $script:PortAvoided
        logFile       = $script:RunOutLog
        stateDir      = $StateDir
        error         = $headlessError
    }
    $snapshot['exitCode'] = 2
    if ($finalState -eq 'ready') { $snapshot['exitCode'] = 0 }
    elseif ($finalState -eq 'failed') { $snapshot['exitCode'] = 1 }

    $script:Stopping = $true
    Stop-OwnChild
    $script:Stopping = $false

    Write-TrayLog ('无头结果 state=' + $finalState)
    Write-Output ('HEADLESS_RESULT ' + (ConvertTo-AsciiJson $snapshot))
    exit ([int]$snapshot['exitCode'])
}

# ---- 先把服务拉起来，让 dsh 的启动与下面 WinForms 初始化并行（省掉这段串行开销）
$script:PendingFailReason = $null
try {
    if (-not (Try-AdoptExisting)) { Restart-Service }
} catch {
    $script:PendingFailReason = $_.Exception.Message
}
if ($script:State -eq 'failed') { $script:PendingFailReason = $script:LastFailReason }

# ------------------------------------------------------------ 托盘 UI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ctx  = New-Object System.Windows.Forms.ApplicationContext
$script:Icon = New-Object System.Windows.Forms.NotifyIcon
$script:Icon.Visible = $true
try {
    # 优先直接用 .ico：省掉 FromFile + GetHicon 的转换，也不泄漏 HICON
    $icoFile = Join-Path $ScriptDir 'harness-logo.ico'
    if (Test-Path $icoFile) {
        $script:Icon.Icon = New-Object System.Drawing.Icon($icoFile)
    } else {
        $img = [System.Drawing.Image]::FromFile($IconFile)
        $hic = $img.GetHicon()
        $script:Icon.Icon = [System.Drawing.Icon]::FromHandle($hic)
    }
} catch {
    $script:Icon.Icon = [System.Drawing.SystemIcons]::Application
}

$menu      = New-Object System.Windows.Forms.ContextMenu
$miOpen    = New-Object System.Windows.Forms.MenuItem('打开网页')
$miCopy    = New-Object System.Windows.Forms.MenuItem('复制链接')
$miRestart = New-Object System.Windows.Forms.MenuItem('重启服务')
$miAuto    = New-Object System.Windows.Forms.MenuItem('开机自启')
$miLogs    = New-Object System.Windows.Forms.MenuItem('打开日志')
$miQuit    = New-Object System.Windows.Forms.MenuItem('退出')
$null = $menu.MenuItems.Add($miOpen)
$null = $menu.MenuItems.Add($miCopy)
$null = $menu.MenuItems.Add($miRestart)
$null = $menu.MenuItems.Add('-')
$null = $menu.MenuItems.Add($miAuto)
$null = $menu.MenuItems.Add($miLogs)
$null = $menu.MenuItems.Add('-')
$null = $menu.MenuItems.Add($miQuit)
$script:Icon.ContextMenu = $menu

function Update-AutoLabel {
    $miAuto.Text = if (Get-AutoStart) { '开机自启 √' } else { '开机自启' }
}
Update-AutoLabel

function Open-Ui {
    if ($script:State -eq 'ready' -and $script:WebUrl) { Open-WebBrowser }
    elseif ($script:State -eq 'failed' -or $script:State -eq 'idle') { Restart-Service }
    # 启动中：什么都不做，就绪时会自动打开
}

$miOpen.Add_Click({ Open-Ui })
$miCopy.Add_Click({
    if ($script:WebUrl) {
        try { Set-Clipboard -Value $script:WebUrl; Show-Toast '已复制链接（含 token）' }
        catch { Show-Toast ('复制失败：' + $_.Exception.Message) 'Error' }
    } else { Show-Toast '服务尚未就绪，暂无可复制的网址' }
})
$miRestart.Add_Click({ Restart-Service })
$miAuto.Add_Click({ Set-AutoStart (-not (Get-AutoStart)); Update-AutoLabel })
$miLogs.Add_Click({ try { [System.Diagnostics.Process]::Start('explorer.exe', $StateDir) | Out-Null } catch { } })
$miQuit.Add_Click({
    $script:Stopping = $true
    if ($script:Timer) { $script:Timer.Stop() }
    Stop-OwnChild
    $ctx.ExitThread()
})
$script:Icon.Add_DoubleClick({ Open-Ui })

$script:Timer = New-Object System.Windows.Forms.Timer
# 启动期 100ms 高频轮询（Set-Ready 会把它降到 1s）
if ($script:State -eq 'ready') { $script:Timer.Interval = 1000 } else { $script:Timer.Interval = 100 }
$script:Timer.Add_Tick({
    try { Invoke-Tick } catch { Fail-Service ('内部异常：' + $_.Exception.Message) }
})

Update-TrayText
# 启动阶段失败时气泡还没有图标可挂，等 UI 就绪后补一条
if ($script:PendingFailReason) {
    Show-Toast ($script:PendingFailReason + '；日志见 ' + $StateDir) 'Error'
    $script:PendingFailReason = $null
}
$script:Timer.Start()

# 进入消息循环，托盘常驻（无任何窗口）
[System.Windows.Forms.Application]::Run($ctx)

# ------------------------------------------------------------ 退出清理
if ($script:Timer) { $script:Timer.Stop() }
$script:Icon.Visible = $false
$script:Icon.Dispose()
if ($mutex) { try { $mutex.ReleaseMutex() } catch { } }
Write-TrayLog '托盘退出'
