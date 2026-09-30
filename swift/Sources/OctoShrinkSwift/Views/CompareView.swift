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

/// 独立对比窗口。缩放 / 平移 / 分割的交互模型与 Tauri 线（compare_viewer.js）逐步对齐：
/// - 滚轮（无修饰键）= 以光标为锚点缩放 ×1.12 / ×0.89；⌘+滚轮 = 上/下一张
/// - 在图上拖动 = 平移；单击（未拖动）= 适合窗口 ↔ 100% 互相切换（点击点为锚点）
/// - 分割线跟着鼠标走（悬停即跟随；正在平移图片时不抢手势），**没有**额外的底部滑条
/// - 「重置」= 重新适配窗口；窗口 resize 时只有处于「适合窗口」才跟着重新适配
/// - 缩放下限 min(0.02, fit×0.5)，上限 20；适合窗口不放大超过 100%
struct CompareView: View {
    let appState: AppState
    @State private var results: [CompressResult]
    @State private var currentIndex: Int

    /// 分割位置（0–100，**视口百分比**，与 Direct `compareSplitPercent` 同义）。
    @State private var splitPercent: Double = 50
    /// 变换状态：屏幕位置 = 画布偏移 + scale × 图像坐标（transform-origin 左上）。
    @State private var scale: CGFloat = 1
    @State private var fitScale: CGFloat = 1
    @State private var tx: CGFloat = 0
    @State private var ty: CGFloat = 0
    @State private var isFit = true
    @State private var panStart: (tx: CGFloat, ty: CGFloat)?
    @State private var panMoved = false
    @State private var containerSize: CGSize = .zero
    @State private var containerFrameInWindow: CGRect = .zero

    @State private var originalImage: NSImage?
    @State private var compressedImage: NSImage?
    @State private var imagePixelSize: CGSize = .zero
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var recompressQuality: Double = 75
    @State private var isRecompressing = false
    @State private var toastMessage: String?
    @State private var eventMonitor: Any?

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
        .onDisappear {
            removeEventMonitor()
            NSCursor.arrow.set()
        }
        .onChange(of: currentIndex) { _ in
            splitPercent = 50
            loadImages()
        }
    }

    // MARK: - Toolbar（按钮集合与顺序对齐 compare.html）

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                navigate(-1)
            } label: {
                OctoIcon(name: OctoIconName.chevronLeft, size: 15)
            }
            .buttonStyle(.borderless)
            .disabled(currentIndex <= 0)
            .help("上一个（⌘+滚轮）")

            Button {
                navigate(1)
            } label: {
                OctoIcon(name: OctoIconName.chevronRight, size: 15)
            }
            .buttonStyle(.borderless)
            .disabled(currentIndex >= results.count - 1)
            .help("下一个（⌘+滚轮）")

            Text("\(currentIndex + 1) / \(results.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)

            Spacer()

            Button {
                stepZoom(-0.25)
            } label: {
                OctoIcon(name: OctoIconName.zoomOut, size: 15)
            }
            .buttonStyle(.borderless)
            .help("缩小")

            Slider(
                value: Binding(
                    get: { Double(min(max(scale, 0.02), 20)) },
                    set: { zoomTo(CGFloat($0), anchor: viewportCenter()) }
                ),
                in: 0.02...20
            )
            .frame(width: 140)

            Button {
                stepZoom(0.25)
            } label: {
                OctoIcon(name: OctoIconName.zoomIn, size: 15)
            }
            .buttonStyle(.borderless)
            .help("放大")

            Text("\(Int((scale * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 48)

            Button {
                fitToWindow()
            } label: {
                OctoIcon(name: OctoIconName.resetView, size: 15)
            }
            .buttonStyle(.borderless)
            .help("重置为适合窗口")

            Button {
                CompareWindowController.close()
            } label: {
                OctoIcon(name: OctoIconName.close, size: 16)
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
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)

                if let original = originalImage, let compressed = compressedImage {
                    let w = imagePixelSize.width
                    let h = imagePixelSize.height
                    let lineX = containerSize.width * splitPercent / 100
                    // 原图裁剪宽度（图像坐标系）：视口分割线换算回图像空间
                    let overlayWidth = max(0, min(w, (lineX - tx) / max(scale, 0.0001)))

                    ZStack(alignment: .topLeading) {
                        Image(nsImage: compressed)
                            .resizable()
                            .frame(width: w, height: h)
                        Image(nsImage: original)
                            .resizable()
                            .frame(width: w, height: h)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: overlayWidth, height: h)
                            }
                    }
                    .frame(width: w, height: h, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: tx, y: ty)

                    // 分割线 + 手柄（视口坐标；线贯穿整个视口高度，与 Direct 一致）
                    handle(lineX: lineX, viewportHeight: containerSize.height)

                    // 角标
                    HStack {
                        imageLabel("原图")
                        Spacer()
                        imageLabel("压缩后")
                    }
                    .padding(8)
                    .frame(width: containerSize.width, alignment: .topLeading)
                } else {
                    VStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                            Text("加载中…").foregroundColor(.secondary)
                        } else {
                            OctoIcon(name: OctoIconName.addImages, size: 32, color: .secondary)
                            Text(loadError ?? "暂无可对比的内容")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(panOrTapGesture)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // 分割线跟着鼠标走；正在平移图片时不抢手势（与 Direct mousemove 守卫一致）
                    guard panStart == nil else { return }
                    if abs(scale - fitScale) < 0.001 {
                        // zoomIn 光标是 macOS 15 才有的 API（Direct 的 zoom-in 光标同义）；
                        // 构建目标 13，旧系统退回 crosshair（对准星，语义接近）。
                        if #available(macOS 15.0, *) {
                            NSCursor.zoomIn.set()
                        } else {
                            NSCursor.crosshair.set()
                        }
                    } else {
                        NSCursor.openHand.set()
                    }
                    splitPercent = min(100, max(0, Double(location.x / max(containerSize.width, 1)) * 100))
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .onAppear {
                containerSize = geo.size
                containerFrameInWindow = geo.frame(in: .global)
                fitToWindow()
            }
            .onChange(of: geo.size) { newSize in
                containerSize = newSize
                containerFrameInWindow = geo.frame(in: .global)
                // 用户手动缩放过就不打断其视角（Direct: compareUserZoomed 时 resize 不重适配）
                if isFit { fitToWindow() }
            }
        }
    }

    private var panOrTapGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if panStart == nil {
                    panStart = (tx, ty)
                    panMoved = false
                }
                let dx = value.translation.width
                let dy = value.translation.height
                if !panMoved && hypot(dx, dy) < 4 { return }
                if !panMoved { NSCursor.closedHand.set() }
                panMoved = true
                tx = (panStart?.tx ?? tx) + dx
                ty = (panStart?.ty ?? ty) + dy
                isFit = false
            }
            .onEnded { value in
                let moved = panMoved
                panStart = nil
                panMoved = false
                if moved { return }
                // 单击（未拖动）：适合窗口 ↔ 100%（Direct endDrag 语义）
                let point = value.startLocation
                if isFit {
                    withAnimation(.easeOut(duration: 0.16)) {
                        zoomTo(1, anchor: point)
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        fitToWindow()
                    }
                }
            }
    }

    private func handle(lineX: CGFloat, viewportHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: viewportHeight)
                .shadow(color: .black.opacity(0.25), radius: 3)
                .offset(x: lineX - 1)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                OctoIcon(
                    name: OctoIconName.splitGrip,
                    size: 16,
                    color: Color(red: 0.227, green: 0.227, blue: 0.235)
                )
            }
            .offset(x: lineX - 16, y: viewportHeight / 2 - 16)
        }
        .allowsHitTesting(false)
    }

    private func imageLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5)))
    }

    // MARK: - 变换（与 compare_viewer.js 同一套数学）

    private func viewportCenter() -> CGPoint {
        CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    }

    /// Direct fit()：不放大超过 100%，居中；重置按钮 / 首次加载 / resize（未手动缩放时）使用。
    private func fitToWindow() {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return }
        let raw = min(
            containerSize.width / imagePixelSize.width,
            containerSize.height / imagePixelSize.height,
            1
        )
        fitScale = (raw.isFinite && raw > 0) ? raw : 1
        scale = fitScale
        tx = (containerSize.width - imagePixelSize.width * fitScale) / 2
        ty = (containerSize.height - imagePixelSize.height * fitScale) / 2
        isFit = true
    }

    /// Direct zoomTo()：锚点缩放，比例钳制在 [min(0.02, fit×0.5), 20]，回到 fit 时记回 fit 模式。
    private func zoomTo(_ rawScale: CGFloat, anchor: CGPoint) {
        let lower = min(0.02, fitScale * 0.5)
        let next = max(lower, min(20, rawScale))
        guard next > 0, scale > 0 else { return }
        let ratio = next / scale
        tx = anchor.x + (tx - anchor.x) * ratio
        ty = anchor.y + (ty - anchor.y) * ratio
        scale = next
        isFit = abs(next - fitScale) < 0.001
    }

    private func stepZoom(_ delta: CGFloat) {
        zoomTo(scale + delta, anchor: viewportCenter())
    }

    // MARK: - 底部信息 + 重新压缩

    @ViewBuilder
    private func controls(result: CompressResult) -> some View {
        VStack(spacing: 8) {
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
                    HStack(spacing: 6) {
                        OctoIcon(name: OctoIconName.recompress, size: 15)
                        Text("重新压缩")
                    }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
                .disabled(isRecompressing)

                Spacer()

                Button {
                    restore()
                } label: {
                    HStack(spacing: 6) {
                        OctoIcon(name: OctoIconName.restore, size: 16)
                        Text("恢复原图")
                    }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))

                Button {
                    CompareWindowController.close()
                } label: {
                    HStack(spacing: 6) {
                        OctoIcon(name: OctoIconName.close, size: 16)
                        Text("关闭")
                    }
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
        fitToWindow()
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
                // 无修饰键滚轮 = 以光标为锚点缩放（与 Direct viewer wheel 一致）
                guard let window = event.window, let content = window.contentView else { return event }
                let local = content.convert(event.locationInWindow, from: nil)
                let flipped = CGPoint(x: local.x, y: content.bounds.height - local.y)
                let frame = containerFrameInWindow
                guard frame.contains(flipped) else { return event }
                let anchor = CGPoint(x: flipped.x - frame.minX, y: flipped.y - frame.minY)
                zoomTo(scale * (event.scrollingDeltaY > 0 ? 1.12 : 0.89), anchor: anchor)
                return nil
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
