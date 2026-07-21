mod commands;
pub mod engine;

use commands::AppState;
use std::collections::HashSet;
use std::sync::Mutex;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState {
            cancel_queue: Mutex::new(HashSet::new()),
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
        ])
        .setup(|app| {
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

                let resource_dir = app.path().resource_dir().unwrap_or_default();
                // 固定端口段：remote.urls 须精确匹配带端口的 origin；
                // 用 :0 随机端口会让 origin 不匹配 -> IPC 静默失效（加不了图/拖不进图）
                let listener = [41845u16, 41846, 41847]
                    .iter()
                    .find_map(|p| TcpListener::bind(format!("localhost:{}", p)).ok())
                    .expect("HTTP bind failed: 41845-41847 均被占用");
                let port = listener.local_addr().unwrap().port();
                let dir = resource_dir.clone();

                std::thread::spawn(move || {
                    for stream in listener.incoming() {
                        let Ok(mut stream) = stream else { continue };
                        let mut reader = std::io::BufReader::new(&stream);
                        let mut request_line = String::new();
                        if reader.read_line(&mut request_line).is_err() { continue; }
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
                                "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                ct, data.len()
                            );
                            let _ = stream.write_all(header.as_bytes());
                            let _ = stream.write_all(&data);
                        } else {
                            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                        }
                    }
                });

                if let Some(window) = app.get_webview_window("main") {
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
        .run(tauri::generate_context!())
        .expect("error while running OctoShrink");
}
