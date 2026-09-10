import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDragOver = false
    @State private var showSystemInfo = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                TitleBarView(showSystemInfo: $showSystemInfo)
                Divider()

                if appState.items.isEmpty {
                    Spacer()
                    DropZoneView(isDragOver: $isDragOver)
                        .frame(height: 220)
                        .padding(.horizontal, 24)
                        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { handleDrop(providers: $0) }
                    Spacer()
                    SettingsPanelView(showSystemInfo: $showSystemInfo)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                } else {
                    VStack(spacing: 0) {
                        QueuePanelView()
                            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { handleDrop(providers: $0) }
                        Divider()
                        SettingsPanelView(showSystemInfo: $showSystemInfo)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        Spacer(minLength: 0)
                    }
                }
            }

            // Toast
            if appState.toastVisible, let msg = appState.toastMessage {
                Text(msg)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .transition(.opacity)
                    .padding(.bottom, 20)
            }

            // System conversion info modal
            if showSystemInfo {
                SystemInfoModal(isPresented: $showSystemInfo)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { appState.detectVersion() }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async { urls.append(url) }
                } else if let url = item as? URL {
                    DispatchQueue.main.async { urls.append(url) }
                }
            }
        }
        group.notify(queue: .main) { appState.addFiles(paths: urls.map(\.path)) }
        return true
    }
}

// MARK: - Title Bar

struct TitleBarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSystemInfo: Bool

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 70, height: 20)
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("OctoShrink (Swift)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()

            // 关于按钮
            Button {
                appState.showAbout.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("关于")

            // 主题切换
            Button {
                appState.cycleTheme()
            } label: {
                Image(systemName: appState.theme.iconName)
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("当前: \(appState.theme.label) · 点击切换")

            Text("v\(appState.appVersion)")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.trailing, 8)
        }
        .frame(height: 36)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
        .popover(isPresented: $appState.showAbout, arrowEdge: .bottom) {
            AboutView()
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("v\(appState.appVersion) Swift Native")
                .font(.system(size: 12, design: .monospaced))
            Divider()
            Button("还原默认设置") {
                appState.resetSettings()
                appState.showAbout = false
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(12)
        .frame(width: 200)
    }
}

// MARK: - Drop Zone

struct DropZoneView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isDragOver: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(isDragOver ? .accentColor : .secondary.opacity(0.4))
            Text(isDragOver ? "松开以添加" : "拖拽图片或文件夹到此处")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
            Text("支持 PNG、JPG、GIF、WebP、BMP 格式 · 自动批量压缩")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.5))
            HStack(spacing: 12) {
                Button {
                    appState.addFilesPanel()
                } label: {
                    Label("选择文件", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    appState.addFolder()
                } label: {
                    Label("选择文件夹", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { appState.addFilesPanel() }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDragOver ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDragOver ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
        )
    }
}

// MARK: - Queue Panel（统一队列：等待+压缩中+完成+统计+排序）

struct QueuePanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("文件队列")
                    .font(.system(size: 13, weight: .semibold))
                Text(queueSummaryText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    appState.clearQueue()
                } label: {
                    Label("清除全部", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(appState.isCompressing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 统计条
            if appState.doneCount > 0 {
                Divider()
                HStack(spacing: 0) {
                    statItem("原始大小", CompressResult.formatBytes(appState.totalOriginal))
                    Spacer()
                    statItem("压缩后", CompressResult.formatBytes(appState.totalCompressed))
                    Spacer()
                    statItem("已节省", CompressResult.formatBytes(appState.totalSaved))
                    Spacer()
                    statItem("压缩率", String(format: "%.1f%%", appState.totalSavingsPct))
                    Spacer()
                    HStack(spacing: 8) {
                        Text("完成 \(appState.doneCount)").foregroundColor(.green)
                        if appState.failedCount > 0 {
                            Text("失败 \(appState.failedCount)").foregroundColor(.red)
                        }
                    }
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            }

            // 排序 + 过滤
            Divider()
            HStack(spacing: 12) {
                Toggle("只显示失败", isOn: $appState.onlyShowFailed)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Picker("排序", selection: $appState.sortKey) {
                    ForEach(SortKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .font(.system(size: 11))
                Button {
                    appState.sortAscending.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: appState.sortAscending ? "arrow.up" : "arrow.down")
                        Text(appState.sortAscending ? "升序" : "降序")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // 文件列表
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    if appState.displayItems.isEmpty && appState.onlyShowFailed {
                        Text("没有失败的文件")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(appState.displayItems) { item in
                            FileRowView(item: item)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            // 底部操作
            Divider()
            HStack(spacing: 10) {
                Button {
                    appState.addFilesPanel()
                } label: {
                    Label("追加文件", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(appState.isCompressing)

                if appState.hasRestorable {
                    Button {
                        appState.restoreAll()
                    } label: {
                        Label("恢复全部原图", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isCompressing)
                }

                Spacer()

                CompressButton()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var queueSummaryText: String {
        if appState.isCompressing || appState.doneCount > 0 {
            return "\(appState.doneCount) / \(appState.items.count) 已完成"
        }
        return "\(appState.items.count) 个文件"
    }

    private func statItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}

// MARK: - File Row

struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let item: QueueItem

    var body: some View {
        HStack(spacing: 8) {
            statusIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 大小信息
            if item.status == .done, let r = item.result {
                Text("\(r.originalSizeFormatted) → \(r.compressedSizeFormatted)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if item.status == .waiting || item.status == .compressing {
                Text(CompressResult.formatBytes(item.fileSize))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // 压缩率
            if item.status == .done, let r = item.result, r.savings > 0 {
                Text("↓\(r.savingsFormatted)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.green)
            }

            // 错误提示图标
            if let r = item.result, let err = r.error, !err.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                    .help(err)
            }

            // 操作按钮
            if item.status == .done {
                rowActions
            } else if item.status == .failed {
                rowFailedActions
            } else if item.status == .restored {
                Button {
                    appState.retryFile(path: item.path)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新压缩")
            }

            // 移除/取消
            if item.status == .waiting || item.status == .compressing {
                Button {
                    appState.cancelFile(path: item.path)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help("移除")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowBackground))
    }

    private var rowActions: some View {
        HStack(spacing: 2) {
            Button { appState.saveResult(path: item.path) } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("另存为")

            if let r = item.result, r.outputPath != nil || r.backupPath != nil {
                Button {
                    CompareWindowController.show(originalPath: item.path, result: r, allResults: appState.items.compactMap(\.result))
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .help("对比查看")
            }

            if item.result?.backupPath != nil {
                Button { appState.restoreFile(path: item.path) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("恢复原图")
            }

            Button {
                appState.openInFinder(path: item.result?.outputPath ?? item.path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在访达中显示")

            Button { appState.copyLog(path: item.path) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制日志")
        }
    }

    private var rowFailedActions: some View {
        HStack(spacing: 2) {
            Button { appState.retryFile(path: item.path) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重试")

            Button { appState.copyLog(path: item.path) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制日志")
        }
    }

    private var rowBackground: Color {
        switch item.status {
        case .compressing: return Color.accentColor.opacity(0.06)
        case .done: return Color.green.opacity(0.03)
        case .failed: return Color.red.opacity(0.04)
        default: return Color.clear
        }
    }

    private var statusText: String {
        switch item.status {
        case .waiting: return "等待中"
        case .compressing: return appState.options.processingMode == .system ? "转换中…" : "压缩中…"
        case .done:
            if let r = item.result {
                return "\(r.savings >= 0 ? "-" : "+")\(String(format: "%.1f", abs(r.savings)))%"
            }
            return "完成"
        case .failed: return "失败"
        case .cancelled: return "已移除"
        case .skipped:
            return item.result?.error ?? "无优化空间"
        case .restored: return "已恢复"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting: return .secondary
        case .compressing: return .secondary
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .skipped: return .yellow
        case .restored: return .blue
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "circle.dotted").foregroundColor(.secondary).font(.system(size: 10))
        case .compressing:
            ProgressView().scaleEffect(0.45).frame(width: 16, height: 16)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 12))
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.system(size: 12))
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundColor(.orange).font(.system(size: 12))
        case .skipped:
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.yellow).font(.system(size: 12))
        case .restored:
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundColor(.blue).font(.system(size: 12))
        }
    }
}

// MARK: - Compress Button

struct CompressButton: View {
    @EnvironmentObject var appState: AppState

    private var buttonText: String {
        if appState.isCompressing {
            return appState.options.processingMode == .system ? "转换中…" : "压缩中…"
        }
        if !appState.compressDoneText.isEmpty {
            return appState.compressDoneText
        }
        return appState.options.processingMode == .system ? "开始转换" : "开始压缩"
    }

    private var buttonIcon: String {
        if appState.isCompressing { return "stop.fill" }
        if !appState.compressDoneText.isEmpty { return "checkmark" }
        return "arrow.down.circle.fill"
    }

    var body: some View {
        Button {
            if appState.isCompressing {
                appState.cancelAll()
            } else {
                appState.startCompress()
            }
        } label: {
            ZStack(alignment: .leading) {
                if appState.isCompressing {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.25))
                            .frame(width: geo.size.width * appState.compressProgress)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: buttonIcon)
                    Text(buttonText)
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!appState.isCompressing && appState.pendingCount == 0)
    }
}

// MARK: - Settings Panel

struct SettingsPanelView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSystemInfo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { appState.settingsExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("压缩设置")
                        .font(.system(size: 13, weight: .semibold))
                    Text(appState.settingsSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: appState.settingsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if appState.settingsExpanded {
                // 处理方式
                HStack {
                    Text("处理方式").font(.system(size: 12)).frame(width: 70, alignment: .leading)
                    Picker("", selection: $appState.options.processingMode) {
                        Text("系统转换").tag(ProcessingMode.system)
                        Text("高级压缩").tag(ProcessingMode.advanced)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: appState.options.processingMode) { _ in appState.saveSettings() }
                    Button {
                        showSystemInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .help("系统转换说明")
                }

                // 自动处理
                HStack {
                    Text("自动处理").font(.system(size: 12)).frame(width: 70, alignment: .leading)
                    Toggle(appState.options.processingMode == .system ? "拖入或选择后自动转换" : "拖入或选择后自动压缩",
                           isOn: $appState.autoCompress)
                        .toggleStyle(.switch)
                        .font(.system(size: 11))
                        .onChange(of: appState.autoCompress) { _ in appState.saveSettings() }
                }

                if appState.options.processingMode == .system {
                    systemModeSettings
                } else {
                    advancedModeSettings
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    var systemModeSettings: some View {
        Group {
            settingsRow("格式") {
                Picker("", selection: $appState.options.outputFormat) {
                    Text("原格式").tag(OutputFormat.original)
                    Text("JPEG").tag(OutputFormat.jpg)
                    Text("PNG").tag(OutputFormat.png)
                    Text("HEIF").tag(OutputFormat.heic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: appState.options.outputFormat) { _ in appState.saveSettings() }
            }
            settingsRow("图像大小") {
                Picker("", selection: $appState.options.systemImageSize) {
                    ForEach(SystemImageSize.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: appState.options.systemImageSize) { _ in appState.saveSettings() }
            }
            settingsRow("元数据") {
                Toggle("保留元数据", isOn: $appState.options.preserveMetadata)
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
                    .onChange(of: appState.options.preserveMetadata) { _ in appState.saveSettings() }
            }
        }
    }

    var advancedModeSettings: some View {
        Group {
            settingsRow("压缩质量") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(appState.options.quality) },
                        set: { appState.options.quality = Int($0); appState.saveSettings() }
                    ), in: 10...100, step: 1)
                    Text("\(appState.options.quality)%")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 40)
                }
            }

            settingsRow("智能模式") {
                Toggle("自动选择最佳算法和参数", isOn: $appState.options.smartMode)
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
                    .onChange(of: appState.options.smartMode) { _ in appState.saveSettings() }
            }

            settingsRow("转换为 WebP") {
                Toggle("输出为 WebP 格式（更小体积）", isOn: $appState.options.convertToWebp)
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
                    .onChange(of: appState.options.convertToWebp) { _ in appState.saveSettings() }
            }

            settingsRow("输出格式") {
                Picker("", selection: $appState.options.outputFormat) {
                    Text("保持原格式").tag(OutputFormat.original)
                    Text("JPEG").tag(OutputFormat.jpg)
                    Text("PNG").tag(OutputFormat.png)
                    Text("WebP").tag(OutputFormat.webp)
                    Text("AVIF").tag(OutputFormat.avif)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: appState.options.outputFormat) { _ in appState.saveSettings() }
            }

            settingsRow("压缩引擎") {
                Picker("", selection: $appState.options.backend) {
                    ForEach(CompressionBackend.allCases, id: \.self) { b in
                        Text(b.label).tag(b)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: appState.options.backend) { _ in appState.saveSettings() }
            }

            settingsRow("压缩力度") {
                Picker("", selection: $appState.options.effort) {
                    ForEach(CompressionEffort.allCases, id: \.self) { e in
                        Text(e.label).tag(e)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: appState.options.effort) { _ in appState.saveSettings() }
            }
        }

        // 输出模式（两种模式共用）
        settingsRow("输出模式") {
            Picker("", selection: $appState.options.outputMode) {
                Text("覆盖原文件").tag(OutputMode.replace)
                Text("添加自定义后缀").tag(OutputMode.suffix)
                Text("输出到指定文件夹").tag(OutputMode.folder)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: appState.options.outputMode) { _ in appState.saveSettings() }
        }

        if appState.options.outputMode == .suffix {
            settingsRow("文件名后缀") {
                HStack {
                    TextField("_compressed", text: $appState.options.outputSuffix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onChange(of: appState.options.outputSuffix) { _ in appState.saveSettings() }
                    Text("例如 _small")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
        }

        if appState.options.outputMode == .folder {
            settingsRow("输出目录") {
                HStack {
                    Text(appState.options.outputDir ?? "未选择")
                        .font(.system(size: 11))
                        .foregroundColor(appState.options.outputDir == nil ? .secondary.opacity(0.5) : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                    Button("浏览") { appState.pickOutputDir() }
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 70, alignment: .leading)
            content()
            Spacer()
        }
    }
}

// MARK: - System Info Modal

struct SystemInfoModal: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.accentColor)
                    Text("系统转换说明")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }

                Text("系统转换使用 macOS 自带的图像转换能力，行为对齐 Finder 中选中图片后右键「快速操作 → 转换图像」的默认方式。")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)

                Text("可选择输出格式、图像大小和是否保留元数据；不会调用第三方压缩工具。此模式仅在 macOS 上可用。")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("知道了") { isPresented = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 20)
        }
    }
}
