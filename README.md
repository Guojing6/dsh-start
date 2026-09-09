# DSH Start

一个用于启动 DeepSeek Harness Web 的 Windows 托盘启动器。

## 功能

- 双击 `start-dsh.vbs` 后静默启动托盘程序，不弹出 PowerShell 控制台。
- 托盘程序后台启动 DSH Web，默认地址为 `http://127.0.0.1:3080`。
- 双击托盘图标可打开 Web UI。
- 右键菜单支持重启服务、设置开机自启和退出。
- 日志写入 `.dsh-tray` 目录，便于排查启动问题。

## 文件

- `start-dsh.vbs`：隐藏窗口启动入口。
- `dsh-tray.ps1`：托盘控制器主脚本。
- `harness-logo.png` / `harness-logo.ico`：托盘和窗口图标。

## 使用

1. 确保已经安装 Node.js 和 `@deepseek-ai/dsh`。
2. 双击 `start-dsh.vbs` 启动。
3. 在系统托盘中找到 `DSH Web` 图标，双击打开 Web UI。

## 注意

`dsh-tray.ps1` 包含中文注释，请使用 UTF-8 with BOM 保存，以兼容 Windows PowerShell 5.1。
