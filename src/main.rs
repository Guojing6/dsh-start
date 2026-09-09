#![windows_subsystem = "windows"]

use std::{
    env,
    ffi::OsStr,
    fs::{self, File},
    net::{TcpStream, ToSocketAddrs},
    os::raw::c_void,
    os::windows::{ffi::OsStrExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Mutex, OnceLock},
    thread,
    time::{Duration, Instant},
};

use windows::{
    core::PCWSTR,
    Win32::{
        Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM},
        System::LibraryLoader::GetModuleHandleW,
        UI::{
            Shell::{
                Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE,
                NOTIFYICONDATAW,
            },
            WindowsAndMessaging::{
                AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu,
                DispatchMessageW, GetCursorPos, GetMessageW, LoadImageW, MessageBoxW,
                PostQuitMessage, RegisterClassW, SetForegroundWindow, TrackPopupMenu,
                TranslateMessage, CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, HICON, IMAGE_ICON,
                LR_DEFAULTSIZE, LR_LOADFROMFILE, MB_ICONERROR, MB_OK, MF_SEPARATOR, MF_STRING, MSG,
                TPM_BOTTOMALIGN, TPM_LEFTALIGN, WM_APP, WM_COMMAND, WM_DESTROY, WM_LBUTTONDBLCLK,
                WM_RBUTTONUP, WNDCLASSW, WS_OVERLAPPEDWINDOW,
            },
        },
    },
};

const PORT: u16 = 3080;
const WM_TRAYICON: u32 = WM_APP + 1;
const MENU_RESTART: usize = 1001;
const MENU_AUTOSTART: usize = 1002;
const MENU_QUIT: usize = 1003;
const CREATE_NO_WINDOW: u32 = 0x08000000;

static APP: OnceLock<Mutex<AppState>> = OnceLock::new();

struct AppState {
    hwnd: isize,
    state_dir: PathBuf,
    child: Option<Child>,
}

fn main() {
    if let Err(error) = run() {
        show_error(&format!("启动失败：{error}"));
    }
}

fn run() -> Result<(), String> {
    let base_dir = env::current_exe()
        .map_err(|e| e.to_string())?
        .parent()
        .ok_or("无法定位程序目录")?
        .to_path_buf();
    let state_dir = base_dir.join(".dsh-tray");
    fs::create_dir_all(&state_dir).map_err(|e| e.to_string())?;

    unsafe {
        let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let class_name = wide("DshStartTrayWindow");
        let wc = WNDCLASSW {
            hInstance: HINSTANCE(instance.0),
            lpszClassName: PCWSTR(class_name.as_ptr()),
            lpfnWndProc: Some(window_proc),
            style: CS_HREDRAW | CS_VREDRAW,
            ..Default::default()
        };
        RegisterClassW(&wc);

        let hwnd = CreateWindowExW(
            Default::default(),
            PCWSTR(class_name.as_ptr()),
            PCWSTR(wide("DSH Web").as_ptr()),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            None,
            None,
            HINSTANCE(instance.0),
            None,
        )
        .map_err(|e| e.to_string())?;

        APP.set(Mutex::new(AppState {
            hwnd: hwnd.0 as isize,
            state_dir,
            child: None,
        }))
        .map_err(|_| "初始化状态失败".to_string())?;

        add_tray_icon(hwnd, &base_dir)?;
    }

    ensure_web_up(true);

    unsafe {
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).into() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        remove_tray_icon();
    }

    Ok(())
}

extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_TRAYICON => match lparam.0 as u32 {
            WM_LBUTTONDBLCLK => {
                ensure_web_up(true);
                LRESULT(0)
            }
            WM_RBUTTONUP => {
                show_menu(hwnd);
                LRESULT(0)
            }
            _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
        },
        WM_COMMAND => {
            match wparam.0 & 0xffff {
                MENU_RESTART => restart_service(),
                MENU_AUTOSTART => toggle_autostart(),
                MENU_QUIT => unsafe {
                    stop_service();
                    PostQuitMessage(0);
                },
                _ => {}
            }
            LRESULT(0)
        }
        WM_DESTROY => unsafe {
            stop_service();
            PostQuitMessage(0);
            LRESULT(0)
        },
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

fn ensure_web_up(open_when_ready: bool) {
    if http_ready() {
        if open_when_ready {
            open_browser();
        }
        return;
    }

    if let Err(error) = start_service() {
        show_error(&format!("启动 DSH Web 失败：{error}"));
        return;
    }

    thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(45);
        while Instant::now() < deadline {
            if http_ready() {
                if open_when_ready {
                    open_browser();
                }
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
        show_error("服务启动超时，日志见 .dsh-tray 目录。");
    });
}

fn restart_service() {
    stop_service();
    thread::sleep(Duration::from_millis(800));
    ensure_web_up(true);
}

fn start_service() -> Result<(), String> {
    let mut app = APP.get().unwrap().lock().unwrap();
    if let Some(child) = app.child.as_mut() {
        if child.try_wait().map_err(|e| e.to_string())?.is_none() {
            return Ok(());
        }
    }

    let appdata = env::var("APPDATA").map_err(|_| "缺少 APPDATA 环境变量")?;
    let bin = Path::new(&appdata).join("npm/node_modules/@deepseek-ai/dsh/lib/bin.js");
    if !bin.exists() {
        return Err(format!("找不到 dsh 程序：{}", bin.display()));
    }

    let out = File::create(app.state_dir.join("dsh.out.log")).map_err(|e| e.to_string())?;
    let err = File::create(app.state_dir.join("dsh.err.log")).map_err(|e| e.to_string())?;
    let child = Command::new("node")
        .arg(bin)
        .args(["--profile", "web", "--port", &PORT.to_string(), "--no-open"])
        .stdout(Stdio::from(out))
        .stderr(Stdio::from(err))
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;

    fs::write(app.state_dir.join("dsh.pid"), child.id().to_string()).ok();
    app.child = Some(child);
    Ok(())
}

fn stop_service() {
    let mut app = APP.get().unwrap().lock().unwrap();
    if let Some(mut child) = app.child.take() {
        kill_pid(child.id());
        let _ = child.wait();
    } else if let Ok(pid) = fs::read_to_string(app.state_dir.join("dsh.pid")) {
        if let Ok(pid) = pid.trim().parse::<u32>() {
            kill_pid(pid);
        }
    }
}

fn kill_pid(pid: u32) {
    let _ = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn http_ready() -> bool {
    let address = ("127.0.0.1", PORT)
        .to_socket_addrs()
        .ok()
        .and_then(|mut addrs| addrs.next());
    address
        .and_then(|addr| TcpStream::connect_timeout(&addr, Duration::from_millis(700)).ok())
        .is_some()
}

fn open_browser() {
    let _ = Command::new("cmd")
        .args(["/C", "start", "", &format!("http://127.0.0.1:{PORT}")])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn toggle_autostart() {
    if autostart_enabled() {
        let _ = Command::new("reg")
            .args([
                "delete",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                "/v",
                "DSH Web Tray",
                "/f",
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .status();
    } else if let Ok(exe) = env::current_exe() {
        let value = format!("\"{}\"", exe.display());
        let _ = Command::new("reg")
            .args([
                "add",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                "/v",
                "DSH Web Tray",
                "/t",
                "REG_SZ",
                "/d",
                &value,
                "/f",
            ])
            .creation_flags(CREATE_NO_WINDOW)
            .status();
    }
}

fn autostart_enabled() -> bool {
    Command::new("reg")
        .args([
            "query",
            r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run",
            "/v",
            "DSH Web Tray",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

unsafe fn add_tray_icon(hwnd: HWND, base_dir: &Path) -> Result<(), String> {
    let icon_path = wide_path(&base_dir.join("harness-logo.ico"));
    let hicon = LoadImageW(
        None,
        PCWSTR(icon_path.as_ptr()),
        IMAGE_ICON,
        0,
        0,
        LR_LOADFROMFILE | LR_DEFAULTSIZE,
    )
    .ok();
    let mut nid = NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        uFlags: NIF_MESSAGE | NIF_TIP,
        uCallbackMessage: WM_TRAYICON,
        ..Default::default()
    };
    if let Some(hicon) = hicon {
        nid.uFlags |= NIF_ICON;
        nid.hIcon = HICON(hicon.0);
    }
    write_wide_fixed(&mut nid.szTip, "DSH Web");
    Shell_NotifyIconW(NIM_ADD, &nid)
        .ok()
        .map_err(|e| e.to_string())
}

unsafe fn remove_tray_icon() {
    if let Some(app) = APP.get() {
        let app = app.lock().unwrap();
        let mut nid = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: HWND(app.hwnd as *mut c_void),
            uID: 1,
            ..Default::default()
        };
        let _ = Shell_NotifyIconW(NIM_DELETE, &mut nid);
    }
}

fn show_menu(hwnd: HWND) {
    unsafe {
        let Ok(menu) = CreatePopupMenu() else {
            return;
        };
        let restart = wide("重启服务");
        let autostart = if autostart_enabled() {
            wide("开机自启 √")
        } else {
            wide("开机自启")
        };
        let quit = wide("退出");
        let _ = AppendMenuW(menu, MF_STRING, MENU_RESTART, PCWSTR(restart.as_ptr()));
        let _ = AppendMenuW(menu, MF_STRING, MENU_AUTOSTART, PCWSTR(autostart.as_ptr()));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let _ = AppendMenuW(menu, MF_STRING, MENU_QUIT, PCWSTR(quit.as_ptr()));
        let mut point = POINT::default();
        let _ = GetCursorPos(&mut point);
        let _ = SetForegroundWindow(hwnd);
        let _ = TrackPopupMenu(
            menu,
            TPM_LEFTALIGN | TPM_BOTTOMALIGN,
            point.x,
            point.y,
            0,
            hwnd,
            None,
        );
        let _ = DestroyMenu(menu);
    }
}

fn show_error(message: &str) {
    unsafe {
        let title = wide("DSH Web");
        let message = wide(message);
        let _ = MessageBoxW(
            None,
            PCWSTR(message.as_ptr()),
            PCWSTR(title.as_ptr()),
            MB_OK | MB_ICONERROR,
        );
    }
}

fn write_wide_fixed(target: &mut [u16], value: &str) {
    let wide = wide(value);
    let len = wide.len().min(target.len());
    target[..len].copy_from_slice(&wide[..len]);
}

fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value).encode_wide().chain(Some(0)).collect()
}

fn wide_path(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}
