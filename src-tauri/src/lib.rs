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
           // 初始化压缩工具资源目录（开箱即用，无需用户安装 CLI 工具）
          if let Ok(res_dir) = app.path().resource_dir() {
              engine::set_resource_dir(res_dir);
           }
            // App Store 沙盒版：tauri:// 自定义协议被 sandbox 阻止导致白屏，
            // 用 file:// 从 Resources 目录直接加载前端绕过。
            // 仅 inproc-backends（appstore）需要，默认版 cli-backends 不受影响。
            #[cfg(feature = "inproc-backends")]
            let app_handle = app.handle().clone();
            #[cfg(feature = "inproc-backends")]
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                if let Some(window) = app_handle.get_webview_window("main") {
                    if let Ok(res_dir) = app_handle.path().resource_dir() {
                        let index_path = res_dir.join("index.html");
                        let url = format!("file://{}", index_path.to_string_lossy());
                        let _ = window.eval(&format!("location.href='{}'", url));
                    }
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running OctoShrink");
}
