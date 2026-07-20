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
            // App Store 沙盒版：tauri:// 被沙盒阻止，导航到 file://
            #[cfg(feature = "inproc-backends")]
            {
                let res_dir = app.path().resource_dir()
                    .map_err(|e| {
                        eprintln!("[OctoShrink] resource_dir: {e}");
                        e
                    })?;
                let index_path = res_dir.join("index.html");
                let url_str = format!("file://{}", index_path.to_string_lossy());
                let url: tauri::Url = url_str.parse()
                    .expect("invalid file URL");
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.navigate(url);
                } else {
                    tauri::WebviewWindowBuilder::new(
                        app,
                        "main",
                        tauri::WebviewUrl::External(url),
                    )
                    .title("OctoShrink")
                    .inner_size(760.0, 680.0)
                    .min_inner_size(640.0, 600.0)
                    .resizable(true)
                    .fullscreen(false)
                    .build()?;
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running OctoShrink");
}
