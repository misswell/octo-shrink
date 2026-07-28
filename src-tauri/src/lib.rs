mod commands;
pub mod engine;
#[cfg(target_os = "macos")]
mod system_image;

use commands::AppState;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

const STARTUP_THEME_FILE: &str = "startup-theme";

static UPDATE_CANCELLED: AtomicBool = AtomicBool::new(false);
static UPDATE_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn supported_theme(theme: &str) -> Option<&'static str> {
    match theme.trim() {
        "light" => Some("light"),
        "dark" => Some("dark"),
        _ => None,
    }
}

#[cfg(target_os = "macos")]
fn startup_theme_path() -> PathBuf {
    use objc2_foundation::NSHomeDirectory;

    PathBuf::from(NSHomeDirectory().to_string())
        .join("Library/Application Support/OctoShrink")
        .join(STARTUP_THEME_FILE)
}

#[cfg(not(target_os = "macos"))]
fn startup_theme_path() -> PathBuf {
    std::env::temp_dir()
        .join("OctoShrink")
        .join(STARTUP_THEME_FILE)
}

fn read_startup_theme_file(path: &Path) -> Option<&'static str> {
    supported_theme(&std::fs::read_to_string(path).ok()?)
}

fn read_startup_theme() -> Option<&'static str> {
    read_startup_theme_file(&startup_theme_path())
}

fn persist_startup_theme(theme: &str) -> Result<(), String> {
    let theme = supported_theme(theme).ok_or_else(|| "invalid theme".to_string())?;
    let path = startup_theme_path();
    let parent = path
        .parent()
        .ok_or_else(|| "invalid startup theme path".to_string())?;
    std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    std::fs::write(path, theme).map_err(|error| error.to_string())
}

#[cfg(target_os = "macos")]
fn system_theme() -> &'static str {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSApplication;
    use objc2_foundation::{NSArray, NSString};

    let Some(main_thread) = MainThreadMarker::new() else {
        return "light";
    };
    let app = NSApplication::sharedApplication(main_thread);
    let appearance = app.effectiveAppearance();
    let names = [
        NSString::from_str("NSAppearanceNameAqua"),
        NSString::from_str("NSAppearanceNameDarkAqua"),
    ];
    let names = NSArray::from_retained_slice(&names);
    match appearance.bestMatchFromAppearancesWithNames(&names) {
        Some(name) if name.to_string() == "NSAppearanceNameDarkAqua" => "dark",
        _ => "light",
    }
}

#[cfg(not(target_os = "macos"))]
fn system_theme() -> &'static str {
    "light"
}

fn startup_background(theme: &str) -> tauri::webview::Color {
    match theme {
        "dark" => tauri::webview::Color(28, 28, 30, 255),
        _ => tauri::webview::Color(236, 236, 237, 255),
    }
}

#[cfg(test)]
mod startup_theme_tests {
    use super::*;

    #[test]
    fn reads_only_supported_persisted_themes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(STARTUP_THEME_FILE);

        std::fs::write(&path, "dark\n").unwrap();
        assert_eq!(read_startup_theme_file(&path), Some("dark"));

        std::fs::write(&path, "invalid").unwrap();
        assert_eq!(read_startup_theme_file(&path), None);
    }

    #[test]
    fn dark_startup_background_matches_the_web_theme() {
        let tauri::webview::Color(red, green, blue, alpha) = startup_background("dark");
        assert_eq!((red, green, blue, alpha), (28, 28, 30, 255));
    }
}

#[tauri::command]
fn set_startup_theme(theme: String) -> Result<(), String> {
    persist_startup_theme(&theme)
}

#[derive(serde::Serialize)]
struct DirectUpdateInfo {
    version: String,
    notes: Option<String>,
}

#[cfg(all(
    target_os = "macos",
    feature = "cli-backends",
    not(feature = "inproc-backends")
))]
#[tauri::command]
async fn check_for_update(app: tauri::AppHandle) -> Result<Option<DirectUpdateInfo>, String> {
    use tauri_plugin_updater::UpdaterExt;

    let update = app
        .updater_builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|error| error.to_string())?
        .check()
        .await
        .map_err(|error| error.to_string())?;
    Ok(update.map(|update| DirectUpdateInfo {
        version: update.version,
        notes: update.body,
    }))
}

#[cfg(not(all(
    target_os = "macos",
    feature = "cli-backends",
    not(feature = "inproc-backends")
)))]
#[tauri::command]
async fn check_for_update(_app: tauri::AppHandle) -> Result<Option<DirectUpdateInfo>, String> {
    Ok(None)
}

#[cfg(all(
    target_os = "macos",
    feature = "cli-backends",
    not(feature = "inproc-backends")
))]
#[tauri::command]
async fn install_update(app: tauri::AppHandle) -> Result<bool, String> {
    use tauri_plugin_updater::UpdaterExt;

    UPDATE_CANCELLED.store(false, Ordering::SeqCst);
    let my_gen = UPDATE_GENERATION.fetch_add(1, Ordering::SeqCst);

    let Some(update) = app
        .updater_builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|error| error.to_string())?
        .check()
        .await
        .map_err(|error| error.to_string())?
    else {
        return Ok(false);
    };
    let total = std::sync::Arc::new(AtomicU64::new(0));
    let downloaded = std::sync::Arc::new(AtomicU64::new(0));
    let app_clone = app.clone();
    let total_clone = total.clone();
    let downloaded_clone = downloaded.clone();
    let result = update
        .download_and_install(
            move |chunk_len: usize, total: Option<u64>| {
                if UPDATE_CANCELLED.load(Ordering::SeqCst) {
                    return;
                }
                if let Some(t) = total {
                    total_clone.store(t, Ordering::Relaxed);
                }
                let dl = downloaded_clone.fetch_add(chunk_len as u64, Ordering::Relaxed)
                    + chunk_len as u64;
                let t = total_clone.load(Ordering::Relaxed);
                let pct: u8 = if t > 0 {
                    ((dl as f64 / t as f64) * 100.0).min(100.0) as u8
                } else {
                    0
                };
                let _ = app_clone.emit("update-progress", pct);
            },
            || {},
        )
        .await;

    if UPDATE_CANCELLED.load(Ordering::SeqCst) {
        return Err("已取消".into());
    }
    if UPDATE_GENERATION.load(Ordering::SeqCst) != my_gen + 1 {
        return Err("已取消".into());
    }

    result.map_err(|error| error.to_string())?;
    app.restart();
}

#[cfg(not(all(
    target_os = "macos",
    feature = "cli-backends",
    not(feature = "inproc-backends")
)))]
#[tauri::command]
async fn install_update(_app: tauri::AppHandle) -> Result<bool, String> {
    Ok(false)
}

#[cfg(all(
    target_os = "macos",
    feature = "cli-backends",
    not(feature = "inproc-backends")
))]
#[tauri::command]
async fn cancel_update() -> Result<(), String> {
    UPDATE_CANCELLED.store(true, Ordering::SeqCst);
    Ok(())
}

#[cfg(not(all(
    target_os = "macos",
    feature = "cli-backends",
    not(feature = "inproc-backends")
)))]
#[tauri::command]
async fn cancel_update() -> Result<(), String> {
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut context = tauri::generate_context!();
    let startup_theme = read_startup_theme().unwrap_or_else(system_theme);
    let _ = persist_startup_theme(startup_theme);
    let startup_background = startup_background(startup_theme);
    for window in &mut context.config_mut().app.windows {
        window.background_color = Some(startup_background);
    }

    let builder = tauri::Builder::default().plugin(tauri_plugin_dialog::init());
    #[cfg(all(
        target_os = "macos",
        feature = "cli-backends",
        not(feature = "inproc-backends")
    ))]
    let builder = builder.plugin(tauri_plugin_updater::Builder::new().build());

    builder
        .manage(AppState {
            cancel_queue: Mutex::new(HashSet::new()),
        })
        .on_page_load(|_webview, _payload| {
            // App Store 版在 HTTP 页面完成加载前隐藏 WebView，避免导航期间露出
            // WKWebView 的默认白色画布。窗口本身始终可见，不使用 visible:false。
            #[cfg(feature = "inproc-backends")]
            if _payload.event() == tauri::webview::PageLoadEvent::Finished
                && _payload.url().host_str() == Some("localhost")
                && matches!(_payload.url().port(), Some(41845 | 41846 | 41847))
            {
                let _ = _webview.show();
            }
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::CloseRequested { .. }) {
                window.app_handle().exit(0);
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::select_files,
            commands::select_folder,
            commands::select_output_dir,
            commands::expand_image_files,
            commands::compress_files,
            commands::compress_smart,
            commands::compress_single,
            commands::cancel_file,
            commands::clear_cancel_queue,
            commands::save_file,
            commands::open_in_finder,
            commands::read_image_dataurl,
            commands::get_app_version,
            commands::restore_original,
            commands::export_all,
            commands::get_file_sizes,
            commands::restore_all,
            set_startup_theme,
            check_for_update,
            install_update,
            cancel_update,
        ])
        .setup(move |app| {
            // 初始化压缩工具资源目录
            if let Ok(res_dir) = app.path().resource_dir() {
                engine::set_resource_dir(res_dir);
            }

            // App Store 沙盒版：tauri:// 自定义协议被沙盒阻止，
            // 启动本地 HTTP 服务器服务前端资源，绕过 WKURLSchemeHandler 限制
            #[cfg(feature = "inproc-backends")]
            {
                use std::io::{BufRead, Write};
                use std::net::TcpListener;
                use std::sync::atomic::{AtomicBool, Ordering};
                use std::sync::Arc;

                let resource_dir = app.path().resource_dir().unwrap_or_default();
                // 固定端口段：remote.urls 须精确匹配带端口的 origin；
                // 用 :0 随机端口会让 origin 不匹配 -> IPC 静默失效（加不了图/拖不进图）
                let listener = [41845u16, 41846, 41847]
                    .iter()
                    .find_map(|p| TcpListener::bind(format!("localhost:{}", p)).ok())
                    .expect("HTTP bind failed: 41845-41847 均被占用");
                let port = listener.local_addr().unwrap().port();
                let dir = resource_dir.clone();

                let ready = Arc::new(AtomicBool::new(false));
                let ready_clone = ready.clone();
                std::thread::spawn(move || {
                    ready_clone.store(true, Ordering::SeqCst);
                    for stream in listener.incoming() {
                        let Ok(mut stream) = stream else { continue };
                        let mut reader = std::io::BufReader::new(&stream);
                        let mut request_line = String::new();
                        if reader.read_line(&mut request_line).is_err() {
                            continue;
                        }
                        let path = request_line.split(' ').nth(1).unwrap_or("/");
                        let path = path.split('?').next().unwrap_or("/");
                        let file = match path {
                            "/" | "/index.html" => "index.html",
                            p => p.trim_start_matches('/'),
                        };
                        let full_path = dir.join(file);
                        if !full_path.starts_with(&dir) {
                            let _ = stream.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                            continue;
                        }
                        if let Ok(data) = std::fs::read(&full_path) {
                            let ct = match full_path.extension().and_then(|e| e.to_str()) {
                                Some("html") => "text/html; charset=utf-8",
                                Some("css") => "text/css",
                                Some("js") => "application/javascript",
                                Some("png") => "image/png",
                                Some("svg") => "image/svg+xml",
                                _ => "application/octet-stream",
                            };
                            let header = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                                ct, data.len()
                            );
                            let _ = stream.write_all(header.as_bytes());
                            let _ = stream.write_all(&data);
                        } else {
                            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                        }
                    }
                });

                // 等 serve 线程进入 accept 循环后再 navigate（避免白屏竞态）
                for _ in 0..50 {
                    if ready.load(Ordering::SeqCst) {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.set_background_color(Some(startup_background));
                    let _ = window.as_ref().hide();

                    let url: tauri::Url = format!("http://localhost:{}/", port).parse().unwrap();
                    let _ = window.navigate(url);
                    let _ = window.show();
                }
            }

            #[cfg(all(debug_assertions, not(feature = "inproc-backends")))]
            {
                if let Some(window) = app.get_webview_window("main") {
                    window.open_devtools();
                }
            }
            Ok(())
        })
        .run(context)
        .expect("error while running OctoShrink");
}
