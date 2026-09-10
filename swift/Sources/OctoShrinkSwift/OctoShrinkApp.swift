import SwiftUI

@available(macOS 13.0, *)
@main
struct OctoShrinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 640, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 启动时清掉上次崩溃残留的临时目录（正常退出时也清理一次）
        cleanupTempDirs()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupTempDirs()
    }

    /// 删除所有临时目录：原图备份、重压缩对比文件、压缩中间产物。
    /// 恢复原图仅限当前会话，退出后备份无从引用，直接删除。
    private func cleanupTempDirs() {
        let fm = FileManager.default
        for name in ["octoshrink-backups", "octoshrink-display", "octoshrink-work"] {
            try? fm.removeItem(atPath: NSTemporaryDirectory() + name)
        }
    }
}
