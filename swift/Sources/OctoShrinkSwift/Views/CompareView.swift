import AppKit
import SwiftUI

final class CompareWindowController {
    private static var window: NSWindow?

    static func show(originalPath: String, result: CompressResult) {
        window?.close()
        let view = CompareView(originalPath: originalPath, result: result)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "对比 — \((originalPath as NSString).lastPathComponent)"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 900, height: 620))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

struct CompareView: View {
    let originalPath: String
    let result: CompressResult
    @State private var showingOriginal = true

    var currentPath: String {
        showingOriginal ? originalPath : (result.outputPath ?? originalPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showingOriginal) {
                    Text("原图").tag(true)
                    Text("压缩后").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Spacer()

                if let out = result.outputPath {
                    Text("输出: \((out as NSString).lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Button("在访达中显示") {
                    NSWorkspace.shared.selectFile(
                        result.outputPath ?? originalPath,
                        inFileViewerRootedAtPath: ""
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            .padding(10)

            Divider()

            if let image = NSImage(contentsOfFile: currentPath) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("无法加载图片")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(spacing: 16) {
                Text("原始: \(result.originalSizeFormatted)")
                    .font(.system(size: 11, design: .monospaced))
                Text("压缩后: \(result.compressedSizeFormatted)")
                    .font(.system(size: 11, design: .monospaced))
                Text("节省: \(result.savingsFormatted)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(result.savings > 0 ? .green : .secondary)
                Text("引擎: \(result.algorithm)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}
