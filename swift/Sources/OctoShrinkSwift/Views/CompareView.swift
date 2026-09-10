import AppKit
import SwiftUI

final class CompareWindowController {
    private static var window: NSWindow?

    static func show(appState: AppState, originalPath: String, result: CompressResult, allResults: [CompressResult]) {
        window?.close()
        let okResults = allResults.filter { $0.success }
        let list = okResults.isEmpty ? [result] : okResults
        let startIndex = list.firstIndex(where: { $0.file == result.file }) ?? 0
        let view = CompareView(appState: appState, results: list, startIndex: startIndex)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "原图对比"
        win.identifier = NSUserInterfaceItemIdentifier("compare")
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 1080, height: 780))
        win.minSize = NSSize(width: 560, height: 440)
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct CompareView: View {
    let appState: AppState
    @State private var results: [CompressResult]
    @State private var currentIndex: Int

    @State private var splitPercent: Double = 50
    @State private var zoom: CGFloat = 1.0
    @State private var originalImage: NSImage?
    @State private var compressedImage: NSImage?
    @State private var imagePixelSize: CGSize = .zero
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var recompressQuality: Double = 75
    @State private var isRecompressing = false
    @State private var toastMessage: String?
    @State private var eventMonitor: Any?
    @State private var containerSize: CGSize = .zero
    @State private var hasFitted = false

    init(appState: AppState, results: [CompressResult], startIndex: Int) {
        self.appState = appState
        _results = State(initialValue: results)
        _currentIndex = State(initialValue: startIndex)
    }

    private var currentResult: CompressResult? {
        guard currentIndex >= 0 && currentIndex < results.count else { return nil }
        return results[currentIndex]
    }

    private var originalPath: String { currentResult?.backupPath ?? currentResult?.file ?? "" }
    private var compressedPath: String { currentResult?.outputPath ?? currentResult?.file ?? "" }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                toolbar
                Divider()

                if let result = currentResult {
                    compareArea(result: result)
                    Divider()
                    controls(result: result)
                } else {
                    Spacer()
                    Text("暂无可对比的内容")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            if let msg = toastMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear {
            installEventMonitor()
            loadImages()
        }
        .onDisappear { removeEventMonitor() }
        .onChange(of: currentIndex) { _ in
            splitPercent = 50
            hasFitted = false
            loadImages()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                navigate(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentIndex <= 0)
            .help("上一个（⌘+滚轮）")

            Text("\(currentIndex + 1) / \(results.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)

            Button {
                navigate(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(currentIndex >= results.count - 1)
            .help("下一个（⌘+滚轮）")

            Spacer()

            Button {
                zoom = max(0.1, zoom - 0.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("缩小")

            Slider(value: $zoom, in: 0.1...8)
                .frame(width: 140)

            Button {
                zoom = min(8, zoom + 0.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("放大")

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 48)

            Button {
                zoom = 1.0
                splitPercent = 50
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("重置缩放")

            Button {
                CompareWindowController.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Compare Area

    @ViewBuilder
    private func compareArea(result: CompressResult) -> some View {
        GeometryReader { geo in
            ZStack {
                if let original = originalImage, let compressed = compressedImage {
                    let displaySize = CGSize(
                        width: imagePixelSize.width * zoom,
                        height: imagePixelSize.height * zoom
                    )
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: compressed)
                                .resizable()
                                .frame(width: displaySize.width, height: displaySize.height)
                            Image(nsImage: original)
                                .resizable()
                                .frame(width: displaySize.width, height: displaySize.height)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: displaySize.width * splitPercent / 100)
                                }
                            // 分割线与手柄
                            ZStack {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 2)
                                    .shadow(radius: 2)
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 28, height: 28)
                                    .shadow(radius: 3)
                                    .overlay(
                                        Image(systemName: "arrow.left.and.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.gray)
                                    )
                            }
                            .frame(width: 28, height: displaySize.height)
                            .offset(x: displaySize.width * splitPercent / 100 - 14)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let x = value.location.x
                                        splitPercent = max(0, min(100, Double(x / max(displaySize.width, 1)) * 100))
                                    }
                            )
                        }
                        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
                        .overlay(alignment: .topLeading) {
                            HStack {
                                label("原图")
                                Spacer()
                                label("压缩后")
                            }
                            .padding(8)
                            .frame(width: displaySize.width)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                } else {
                    VStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                            Text("加载中…").foregroundColor(.secondary)
                        } else {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text(loadError ?? "暂无可对比的内容")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onAppear {
                containerSize = geo.size
                applyFitIfNeeded()
            }
            .onChange(of: geo.size) { newSize in
                containerSize = newSize
                applyFitIfNeeded()
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
    }

    // MARK: - 底部信息 + 重新压缩

    @ViewBuilder
    private func controls(result: CompressResult) -> some View {
        VStack(spacing: 8) {
            // 分割位置滑杆
            HStack(spacing: 8) {
                Text("对比").font(.system(size: 11)).foregroundColor(.secondary)
                Slider(value: $splitPercent, in: 0...100)
            }

            // 信息行
            HStack(spacing: 16) {
                Text((result.file as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("原图大小 \(result.originalSizeFormatted)")
                    .font(.system(size: 11, design: .monospaced))
                Text("压缩后大小 \(result.compressedSizeFormatted)")
                    .font(.system(size: 11, design: .monospaced))
                Text("节省 \(result.savingsSignedText)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(result.savings > 0 ? .green : .secondary)
                Text("算法 \(result.algorithm.isEmpty ? "?" : result.algorithm)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            // 重新压缩行
            HStack(spacing: 8) {
                Text("重新压缩质量").font(.system(size: 11))
                Slider(value: $recompressQuality, in: 10...100, step: 1)
                    .frame(width: 180)
                Text("\(Int(recompressQuality))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40)
                Button {
                    recompress()
                } label: {
                    Label("重新压缩", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
                .disabled(isRecompressing)

                Spacer()

                Button {
                    restore()
                } label: {
                    Label("恢复原图", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))

                Button {
                    CompareWindowController.close()
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Image loading

    private func loadImages() {
        guard let result = currentResult else { return }
        originalImage = nil
        compressedImage = nil
        loadError = nil
        isLoading = true

        let origPath = result.backupPath ?? result.file
        let compPath = result.outputPath ?? result.file
        let orig = Self.loadImage(origPath)
        let comp = Self.loadImage(compPath)

        if orig == nil {
            loadError = "无法加载原图，文件可能已被移动或恢复"
        } else if comp == nil {
            loadError = "无法加载压缩图，文件可能已被移动或恢复"
        }
        originalImage = orig
        compressedImage = comp
        imagePixelSize = Self.pixelSize(of: orig ?? comp)
        isLoading = false
        applyFitIfNeeded()
    }

    /// 首次载入时按容器大小适配缩放（与 Tauri setCompareZoom(fitZoom) 一致）
    private func applyFitIfNeeded() {
        guard !hasFitted,
              originalImage != nil, compressedImage != nil,
              imagePixelSize.width > 0, imagePixelSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return }
        zoom = fitZoom(in: containerSize)
        hasFitted = true
    }

    nonisolated private static func loadImage(_ path: String) -> NSImage? {
        NSImage(contentsOfFile: path)
    }

    nonisolated private static func pixelSize(of image: NSImage?) -> CGSize {
        guard let image else { return .zero }
        if let rep = image.representations.first as? NSBitmapImageRep {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    private func fitZoom(in container: CGSize) -> CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              container.width > 0, container.height > 0 else { return 1 }
        let fit = min(container.width / imagePixelSize.width, container.height / imagePixelSize.height, 1)
        return (fit.isFinite && fit > 0) ? fit : 1
    }

    // MARK: - Navigation

    private func navigate(_ direction: Int) {
        let newIndex = currentIndex + direction
        guard newIndex >= 0, newIndex < results.count else { return }
        currentIndex = newIndex
    }

    // MARK: - Actions

    private func recompress() {
        guard let result = currentResult else { return }
        isRecompressing = true
        let quality = Int(recompressQuality)
        Task { @MainActor in
            defer { isRecompressing = false }
            guard let updated = appState.recompressForCompare(path: result.file, quality: quality) else {
                showCompareToast("重新压缩失败")
                return
            }
            // 预览输出为临时文件，仅刷新对比图与新尺寸
            if let preview = Self.loadImage(updated.outputPath ?? "") {
                compressedImage = preview
            } else {
                showCompareToast("重新压缩预览加载失败")
                return
            }
            // 信息栏同步新结果（与 Tauri refreshInfo 一致）
            if currentIndex >= 0 && currentIndex < results.count {
                results[currentIndex] = updated
            }
            showCompareToast("重新压缩完成 (质量: \(quality)%)")
        }
    }

    private func restore() {
        guard let result = currentResult else { return }
        if appState.restoreFromCompare(path: result.file) {
            NotificationCenter.default.post(
                name: NSNotification.Name("MainRestoreFile"),
                object: nil,
                userInfo: ["filePath": result.file]
            )
            CompareWindowController.close()
        } else {
            showCompareToast("恢复失败: 未知错误")
        }
    }

    private func showCompareToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toastMessage == message { toastMessage = nil }
        }
    }

    // MARK: - Wheel / keyboard monitor

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { event in
            guard event.window?.identifier?.rawValue == "compare" else { return event }
            if event.type == .scrollWheel {
                if event.modifierFlags.contains(.command) {
                    navigate(event.scrollingDeltaY > 0 ? -1 : 1)
                    return nil
                }
                if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
                    let delta: CGFloat = event.scrollingDeltaY > 0 ? 0.25 : -0.25
                    zoom = min(8, max(0.1, zoom + delta))
                    return nil
                }
                return event
            }
            // keyDown：仅当焦点不在滑杆/输入框时才用方向键切换文件
            // （与 Tauri `e.target === document.body` 的判断一致）
            let responder = event.window?.firstResponder
            let editing = responder is NSTextView || responder is NSTextField || responder is NSSlider
            switch event.keyCode {
            case 53: // Escape
                CompareWindowController.close()
                return nil
            case 123: // Left
                if editing { return event }
                navigate(-1)
                return nil
            case 124: // Right
                if editing { return event }
                navigate(1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// CompareView 本身是值类型，recompress 后需要手动通知刷新
extension CompareView: Equatable {
    static func == (lhs: CompareView, rhs: CompareView) -> Bool { false }
}
