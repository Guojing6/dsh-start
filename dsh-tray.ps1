#Requires -Version 5.1
# DSH Web 托盘控制器 —— 与 start-dsh.vbs 放同一目录，双击 start-dsh.vbs 启动
# v2（异步版）：托盘图标立即可用；服务在后台异步启动，HTTP 就绪才自动开浏览器；
#             服务已在运行（同端口、同 dsh）时直接接管，不重复停启。
# 注意：本文件含中文，保存编码必须是 "UTF-8 with BOM"，否则 Windows PowerShell 5.1 会显示乱码

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

# ---------- 配置 ----------
$IconFile = Join-Path $PSScriptRoot 'harness-logo.png'   # 托盘图标（与脚本同目录）
$StateDir = Join-Path $PSScriptRoot '.dsh-tray'          # 日志/状态目录，随脚本一起走
$OutLog   = Join-Path $StateDir 'dsh.out.log'
$ErrLog   = Join-Path $StateDir 'dsh.err.log'
$PidFile  = Join-Path $StateDir 'dsh.pid'
$RunKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName  = 'DSH Web Tray'
$VbsPath  = Join-Path $PSScriptRoot 'start-dsh.vbs'
$BinPath  = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'

$Port = 3080
$WebUrl = "http://127.0.0.1:$Port"

# ---------- 异步状态机（全部由 UI 计时器驱动，绝不阻塞消息循环） ----------
# State: idle | delay | wait | done | fail
$script:State        = 'idle'   # delay=等端口释放后拉起；wait=已拉起等 HTTP 就绪
$script:ActionAt     = $null    # delay 状态的执行时刻
$script:Deadline     = $null    # wait 状态的超时时刻
$script:ChildPid     = $null    # 本次由我们拉起的 node 进程
$script:Attach       = $false   # 本次是接管已在运行的服务（非自己拉起）
$script:Exiting      = $false
$script:OpenWhenReady= $true    # 服务就绪后自动打开 WebUI
$script:PortPidCachePort = $null
$script:PortPidCacheAt = [datetime]::MinValue
$script:PortPidCacheValue = $null

# 自动化测试开关：置 1 时不真正打开浏览器（正常运行不受影响）
$TestNoBrowser = ($env:DSH_TRAY_NOBROWSER -eq '1')

# 单实例：已有托盘在跑就直接退出
$mutex = New-Object System.Threading.Mutex($false, 'DSHWebTray')
if (-not $mutex.WaitOne(0)) { exit }

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# ---------- 服务管理 ----------
function Clear-PortPidCache {
    $script:PortPidCachePort = $null
    $script:PortPidCacheAt = [datetime]::MinValue
    $script:PortPidCacheValue = $null
}
function Get-PortPid {
    param([switch]$Refresh)
    $now = Get-Date
    if (-not $Refresh -and
        $script:PortPidCachePort -eq $Port -and
        (($now - $script:PortPidCacheAt).TotalMilliseconds -lt 150)) {
        return $script:PortPidCacheValue
    }
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    $owner = $null
    if ($c) { $owner = [int]$c[0].OwningProcess }
    $script:PortPidCachePort = $Port
    $script:PortPidCacheAt = $now
    $script:PortPidCacheValue = $owner
    return $owner
}
function Test-Running {
    $owner = Get-PortPid
    return ($null -ne $owner)
}
function Test-OwnerIsDsh {          # 占用端口的是不是我们这套 dsh web（避免误杀外部服务）
    param([Nullable[int]]$OwnerPid = $null)
    $owner = $OwnerPid
    if (-not $owner) { $owner = Get-PortPid }
    if (-not $owner) { return $false }
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -and $cmd -like '*bin.js*') { return $true }
    return $false
}
function Stop-PortOwner {           # 杀掉占用当前端口的整个进程树
    $owner = Get-PortPid -Refresh
    if (-not $owner) { return }
    & taskkill.exe /PID $owner /T /F 2>$null | Out-Null
    Clear-PortPidCache
}
function Start-DshSpawn {           # 后台隐藏启动 node（带日志重定向），记录 pid
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { $node = 'D:\nodejs\node.exe' }
    if (-not (Test-Path $BinPath)) { throw "找不到 dsh 程序: $BinPath" }
    $p = Start-Process -FilePath $node `
        -ArgumentList @($BinPath, '--profile', 'web', '--port', "$Port", '--no-open') `
        -WindowStyle Hidden `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog `
        -PassThru
    $script:ChildPid = $p.Id
    $p.Id | Set-Content $PidFile
    Clear-PortPidCache
}
function Stop-DshService {          # 停掉“我们的进程 + 端口占用者”（退出/重启用）
    if ($script:ChildPid) {
        & taskkill.exe /PID $script:ChildPid /T /F 2>$null | Out-Null
        $script:ChildPid = $null
    }
    Stop-PortOwner
    Clear-PortPidCache
}
function Test-HttpReady {           # 服务真正应答（任意状态码，含 401/302）才算就绪
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/")
        $req.Timeout = 1000
        $req.ReadWriteTimeout = 1000
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $_.Exception.Response.Close(); return $true }
        return $false
    } catch {
        return $false
    }
}
function Open-WebBrowser {          # 尽力打开浏览器，打不开不影响服务
    if ($TestNoBrowser) { return }
    try { [System.Diagnostics.Process]::Start($script:WebUrl) | Out-Null } catch { }
}
function Enter-Wait([double]$waitSeconds) {   # 进入“等 HTTP 就绪”，就绪后由计时器开浏览器
    $script:State = 'wait'
    $script:Deadline = (Get-Date).AddSeconds($waitSeconds)
    $script:Timer.Start()
}
function Start-AsyncService {       # 冷启动：端口空闲 -> 直接拉起
    Start-DshSpawn
    Enter-Wait 45
}
function Restart-AsyncService {     # 杀旧 -> 延迟 800ms 再拉起（避开 Windows 端口复用竞态）
    Stop-DshService
    $script:Attach = $false
    $script:State = 'delay'
    $script:ActionAt = (Get-Date).AddMilliseconds(800)
    $script:Deadline = (Get-Date).AddSeconds(45)
    $script:Timer.Start()
}
function Ensure-WebUp {             # 双击托盘：运行中就开 UI；否则异步启动，就绪自动开
    if (Test-Running) {
        if (Test-HttpReady) { Open-WebBrowser }
        else { $script:Attach = $true; Enter-Wait 10 }
        return
    }
    if ($script:State -eq 'wait' -or $script:State -eq 'delay') { return }  # 正在启动中，就绪会自动开
    Start-AsyncService
}
function Attach-Or-Restart {        # 托盘启动时：同端口已是 dsh -> 直接接管；否则重启接管
    $owner = Get-PortPid -Refresh
    if ($owner) {
        if (Test-OwnerIsDsh -OwnerPid $owner) {
            $owner | Set-Content $PidFile
            $script:Attach = $true
            if (Test-HttpReady) { $script:State = 'done'; Open-WebBrowser }
            else { Enter-Wait 10 }   # 正在启动中，等就绪自动开
            return
        }
        Restart-AsyncService        # 端口被别的东西占用 -> 停掉并用我们的服务接管
    } else {
        Start-AsyncService
    }
}
# ---------- 开机自启（注册表开关，不放启动文件夹） ----------
function Get-AutoStart {
    return (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue) -ne $null
}
function Set-AutoStart([bool]$on) {
    if ($on) { Set-ItemProperty -Path $RunKey -Name $RunName -Value ('wscript.exe "{0}"' -f $VbsPath) }
    else     { Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue }
}

# ---------- 托盘图标：固定用黑鲸鱼，不显示运行中/已停止 ----------
$ctx  = New-Object System.Windows.Forms.ApplicationContext
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Visible = $true
$icon.Text = 'DSH Web'
try {
    $img = [System.Drawing.Image]::FromFile($IconFile)   # 64px PNG -> 托盘图标
    $hic = $img.GetHicon()
    $icon.Icon = [System.Drawing.Icon]::FromHandle($hic)
} catch {
    $icon.Icon = [System.Drawing.SystemIcons]::Application   # 图标文件缺失时的兜底
}

# ---------- 右键菜单 ----------
$menu = New-Object System.Windows.Forms.ContextMenu
$miRestart = New-Object System.Windows.Forms.MenuItem('重启服务')
$autoText  = $(if (Get-AutoStart) { '开机自启 √' } else { '开机自启' })
$miAuto    = New-Object System.Windows.Forms.MenuItem($autoText)
$miQuit    = New-Object System.Windows.Forms.MenuItem('退出')
$null = $menu.MenuItems.Add($miRestart)
$null = $menu.MenuItems.Add($miAuto)
$null = $menu.MenuItems.Add('-')
$null = $menu.MenuItems.Add($miQuit)
$icon.ContextMenu = $menu

# ---------- 异步状态机计时器（服务启停在后台轮询，UI 全程不阻塞） ----------
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 100
$script:Timer.Add_Tick({
    if ($script:Exiting) { $script:Timer.Stop(); return }
    try {
        switch ($script:State) {
            'delay' {                                  # 等端口释放后拉起
                if ((Get-Date) -ge $script:ActionAt) {
                    Start-DshSpawn
                    Enter-Wait 45
                }
            }
            'wait' {                                   # 轮询直到 HTTP 就绪
                if (Test-Running) {
                    if (Test-HttpReady) {
                        $script:Timer.Stop()
                        $script:State = 'done'
                        if ($script:OpenWhenReady) { Open-WebBrowser }
                    } elseif ((Get-Date) -ge $script:Deadline) {
                        if ($script:Attach) {
                            Restart-AsyncService      # 接管超时（不响应/外部服务）-> 停掉重启
                        } else {
                            $script:Timer.Stop(); $script:State = 'fail'
                            $icon.ShowBalloonTip(5000, 'DSH Web', ('服务启动超时（45秒），日志见：' + $script:StateDir), [System.Windows.Forms.ToolTipIcon]::Error)
                        }
                    }
                } else {
                    $childDead = $script:ChildPid -and -not (Get-Process -Id $script:ChildPid -ErrorAction SilentlyContinue)
                    if ($childDead -and -not $script:Attach) {
                        $script:Timer.Stop(); $script:State = 'fail'
                        $icon.ShowBalloonTip(5000, 'DSH Web', ('服务进程已退出，日志见：' + $script:StateDir), [System.Windows.Forms.ToolTipIcon]::Error)
                    } elseif ((Get-Date) -ge $script:Deadline) {
                        $script:Timer.Stop(); $script:State = 'fail'
                        $icon.ShowBalloonTip(5000, 'DSH Web', ('服务启动超时（端口未就绪），日志见：' + $script:StateDir), [System.Windows.Forms.ToolTipIcon]::Error)
                    }
                }
            }
        }
    } catch {
        $script:Timer.Stop(); $script:State = 'fail'
        try { $icon.ShowBalloonTip(5000, 'DSH Web', '启动失败：' + $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error) } catch { }
    }
})

# ---------- 菜单动作 ----------
$miRestart.Add_Click({ Restart-AsyncService })
$miAuto.Add_Click({ Set-AutoStart (-not (Get-AutoStart)); Update-AutoLabel })
$miQuit.Add_Click({ $script:Exiting = $true; $script:Timer.Stop(); Stop-DshService; $ctx.ExitThread() })

function Update-AutoLabel {          # 开机自启开关：开启加“√”，关闭时不再显示“×”
    $miAuto.Text = $(if (Get-AutoStart) { '开机自启 √' } else { '开机自启' })
}

# 双击托盘图标：服务未运行则启动，运行中直接打开 WebUI（等效原“启动服务”入口）
$icon.Add_DoubleClick({ Ensure-WebUp })

# ---------- 启动：托盘先就绪，服务在后台异步启动/接管（全程不阻塞消息循环） ----------
try {
    Attach-Or-Restart
} catch {
    $script:State = 'fail'
    try { $icon.ShowBalloonTip(5000, 'DSH Web', '启动失败：' + $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error) } catch { }
}

# 进入消息循环，托盘常驻（全程无任何窗口）
[System.Windows.Forms.Application]::Run($ctx)

# 退出清理
$script:Timer.Stop()
$icon.Visible = $false
$icon.Dispose()
$mutex.ReleaseMutex()
