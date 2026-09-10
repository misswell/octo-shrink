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
                HairlineDivider()

                // Tauri .container：整体可滚动，padding 12/16，卡片间距 12
                ScrollView {
                    VStack(spacing: AppMetrics.cardSpacing) {
                        if appState.items.isEmpty {
                            DropZoneView(isDragOver: $isDragOver)
                                .onDrop(of: [.fileURL], isTargeted: $isDragOver) { handleDrop(providers: $0) }
                            if appState.hasImported {
                                SettingsPanelView(showSystemInfo: $showSystemInfo)
                            }
                        } else {
                            QueuePanelView()
                                .onDrop(of: [.fileURL], isTargeted: $isDragOver) { handleDrop(providers: $0) }
                            SettingsPanelView(showSystemInfo: $showSystemInfo)
                        }
                    }
                    .padding(AppMetrics.containerPadding)
                }
                .scrollContentBackground(.hidden)
            }

            // Toast（.toast：bottom 20px，bg black 0.8，12px，radius 6）
            if appState.toastVisible, let msg = appState.toastMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.8))
                            .shadow(color: Color.black.opacity(0.2), radius: 6, y: 2)
                    )
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }

            // System conversion info modal
            if showSystemInfo {
                SystemInfoModal(isPresented: $showSystemInfo)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: appState.toastVisible)
        .onAppear {
            appState.detectVersion()
            if let win = NSApp.windows.first(where: { $0.isVisible && $0.title == "OctoShrink" })
                ?? NSApp.windows.first(where: { $0.isVisible }) {
                win.identifier = NSUserInterfaceItemIdentifier("main")
                win.isMovableByWindowBackground = true
            }
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("MainRestoreFile"),
                object: nil,
                queue: .main
            ) { notification in
                if let path = notification.userInfo?["filePath"] as? String {
                    Task { @MainActor in
                        appState.markRestored(path: path)
                    }
                }
            }
        }
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

// MARK: - Title Bar（.titlebar：42px，底部发丝线，图标+标题居中，右侧 26pt 按钮）

struct TitleBarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSystemInfo: Bool

    var body: some View {
        ZStack {
            // 居中的图标 + 标题（.titlebar-drag）
            HStack(spacing: 5) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                Text("OctoShrink (Swift)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // 左侧红绿灯占位 + 右侧操作按钮（.titlebar-actions）
            HStack(spacing: 2) {
                Color.clear.frame(width: 70, height: 1)
                Spacer()
                Button {
                    appState.showAbout.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(TitleBarButtonStyle())
                .help("关于")

                Button {
                    appState.cycleTheme()
                } label: {
                    Image(systemName: appState.theme.iconName)
                }
                .buttonStyle(TitleBarButtonStyle())
                .help("当前: \(appState.theme.label) · 点击切换")

                Text("v\(appState.appVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.trailing, 10)
            }
        }
        .frame(height: AppMetrics.titleBarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
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
            Text("v\(appState.appVersion) Swift")
                .font(.system(size: 12, design: .monospaced))
            HairlineDivider()
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

// MARK: - Drop Zone（.dropzone：虚线卡片，48pt 图标圆盘，18px 内边距）

struct DropZoneView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isDragOver: Bool

    var body: some View {
        VStack(spacing: 0) {
            // .dropzone-icon-disc：48px，radius 12，强调色 32px 字形
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 48, height: 48)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .padding(.bottom, 8)
            .offset(y: isDragOver ? -1 : 0)

            Text(isDragOver ? "松开以添加" : "拖拽图片或文件夹到此处")
                .font(.system(size: 14, weight: .medium))
                .padding(.bottom, 3)

            Text("支持 PNG、JPG、GIF、WebP、BMP 格式 · 自动批量压缩")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                Button {
                    appState.addFilesPanel()
                } label: {
                    Label("选择文件", systemImage: "photo.badge.plus")
                        .labelIconToTextSpacing(4)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    appState.addFolder()
                } label: {
                    Label("选择文件夹", systemImage: "folder.badge.plus")
                        .labelIconToTextSpacing(4)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .contentShape(Rectangle())
        .onTapGesture { appState.addFilesPanel() }
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous)
                .fill(isDragOver ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous)
                .strokeBorder(
                    isDragOver ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .shadow(color: Color.black.opacity(0.07), radius: 1.5, y: 1)
        .animation(.easeOut(duration: 0.15), value: isDragOver)
    }
}

// MARK: - Queue Panel（.queue-panel 卡片：头部/统计/视图控制/列表/操作五段）

struct QueuePanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            if showStats {
                HairlineDivider()
                statsBar
            }
            HairlineDivider()
            viewControls
            HairlineDivider()
            fileList
            HairlineDivider()
            actions
        }
        .cardStyle()
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))
    }

    private var showStats: Bool {
        appState.isCompressing || appState.items.contains(where: { $0.result != nil })
    }

    // .queue-header：padding 10×14
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
            Text("文件队列")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(queueSummaryText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.trailing, 2)
            Button {
                appState.clearQueue()
            } label: {
                Label("清除全部", systemImage: "trash")
                    .labelIconToTextSpacing(3)
            }
            .buttonStyle(GhostButtonStyle())
            .help("清空列表")
        }
        .padding(.horizontal, AppMetrics.sectionHPadding)
        .padding(.vertical, 10)
    }

    // .queue-stats：bg-secondary，padding 8×14，gap 20；值 14px/700
    private var statsBar: some View {
        HStack(spacing: 20) {
            statItem("原始大小", CompressResult.formatBytesJS(appState.totalOriginal), .primary)
            statItem("压缩后", CompressResult.formatBytesJS(appState.totalCompressed), .accentColor)
            statItem("已节省", CompressResult.formatBytesJS(appState.totalSaved), .green)
            statItem("压缩率", String(format: "%.1f%%", appState.totalSavingsPct), .green)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppMetrics.sectionHPadding)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    private func statItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
                .kerning(0.3)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(color)
        }
    }

    // .queue-view-controls：padding 8×14，11px
    private var viewControls: some View {
        HStack(spacing: 8) {
            Toggle("只显示失败", isOn: $appState.onlyShowFailed)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Picker("排序", selection: $appState.sortKey) {
                ForEach(SortKey.allCases, id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 116)
            .font(.system(size: 11))
            Button {
                appState.sortAscending.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: appState.sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text(appState.sortAscending ? "升序" : "降序")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(GhostButtonStyle())
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, AppMetrics.sectionHPadding)
        .padding(.vertical, 8)
    }

    // .file-queue-list：padding 6×10，gap 2，max-height 260px 内部滚动
    private var fileList: some View {
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
        }
        .frame(maxHeight: AppMetrics.queueListMaxHeight)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // .queue-actions：padding 8×14，gap 6
    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                appState.addFilesPanel()
            } label: {
                Label("追加文件", systemImage: "photo.badge.plus")
                    .labelIconToTextSpacing(4)
            }
            .buttonStyle(SecondaryButtonStyle())

            if appState.hasRestorable {
                Button {
                    appState.restoreAll()
                } label: {
                    Label("恢复全部原图", systemImage: "arrow.uturn.backward")
                        .labelIconToTextSpacing(4)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Spacer(minLength: 8)

            CompressButton()
        }
        .padding(.horizontal, AppMetrics.sectionHPadding)
        .padding(.vertical, 8)
    }

    private var queueSummaryText: String {
        if appState.isCompressing || appState.doneCount > 0 {
            return "\(appState.doneCount) / \(appState.items.count) 已完成"
        }
        return "\(appState.items.count) 个文件"
    }
}

// MARK: - File Row（.file-queue-item：min-height 40，icon 24pt 圆盘，name 11px）

struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let item: QueueItem

    var body: some View {
        HStack(spacing: 8) {
            iconDisc

            Text(item.fileName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(sizeText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(item.status == .done ? .secondary : Color(nsColor: .tertiaryLabelColor))
                .fixedSize()

            HStack(spacing: 2) {
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
                if let err = item.result?.error, !err.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.yellow)
                        .help(err)
                }
            }
            .frame(minWidth: 44, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)

            actions

            if item.status == .waiting {
                Button {
                    appState.removeItem(path: item.path)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(RowActionButtonStyle())
                .help("移除")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                .fill(rowBackground)
        )
        .opacity(rowOpacity)
    }

    // .queue-item-icon：24px 圆盘 radius 4，bg-secondary
    @ViewBuilder
    private var iconDisc: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 24, height: 24)
            switch item.status {
            case .waiting:
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            case .compressing:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 24, height: 24)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.red)
            case .removed, .cancelled:
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            case .restored:
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var sizeText: String {
        if item.status == .done, let r = item.result {
            return "\(r.originalSizeFormatted) → \(r.compressedSizeFormatted)"
        }
        return CompressResult.formatBytesJS(item.fileSize)
    }

    @ViewBuilder
    private var actions: some View {
        switch item.status {
        case .done:
            HStack(spacing: 2) {
                if let r = item.result, r.success {
                    Button { appState.saveResult(path: item.path) } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(RowActionButtonStyle())
                    .help("另存为")

                    Button {
                        CompareWindowController.show(
                            appState: appState,
                            originalPath: item.path,
                            result: r,
                            allResults: appState.comparableResults
                        )
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .buttonStyle(RowActionButtonStyle())
                    .help("对比查看")

                    Button { appState.restoreFile(path: item.path) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(RowActionButtonStyle())
                    .help("恢复原图")

                    Button {
                        appState.openInFinder(path: r.outputPath ?? item.path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(RowActionButtonStyle())
                    .help("在访达中显示")
                }
                Button { appState.copyLog(path: item.path) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(RowActionButtonStyle())
                .help("复制日志")
            }
        case .failed:
            HStack(spacing: 2) {
                Button { appState.retryFile(path: item.path) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(RowActionButtonStyle())
                .help("重试")

                Button { appState.copyLog(path: item.path) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(RowActionButtonStyle())
                .help("复制日志")
            }
        case .restored:
            Button { appState.retryFile(path: item.path) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(RowActionButtonStyle())
            .help("重新压缩")
        default:
            EmptyView()
        }
    }

    // .file-queue-item 状态底色
    private var rowBackground: Color {
        switch item.status {
        case .compressing: return Color.accentColor.opacity(0.12)
        case .done: return Color.green.opacity(0.08)
        case .failed: return Color.red.opacity(0.08)
        default: return Color.clear
        }
    }

    // waiting 0.8 / cancelled·removed 0.4 / restored 0.7
    private var rowOpacity: Double {
        switch item.status {
        case .waiting: return 0.8
        case .removed, .cancelled: return 0.4
        case .restored: return 0.7
        default: return 1
        }
    }

    private var statusText: String {
        switch item.status {
        case .waiting: return "等待中"
        case .compressing: return appState.options.processingMode == .system ? "转换中…" : "压缩中…"
        case .done:
            if let r = item.result { return r.savingsSignedText }
            return "完成"
        case .failed: return "失败"
        case .removed: return "已移除"
        case .cancelled: return "已跳过"
        case .restored: return "已恢复"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting, .removed, .cancelled, .restored: return Color(nsColor: .tertiaryLabelColor)
        case .compressing: return .accentColor
        case .done: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Compress Button（.btn-full + .compress-progress-btn：13px/600，padding 8×20）

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
        if appState.isCompressing { return "arrow.triangle.2.circlepath" }
        if !appState.compressDoneText.isEmpty { return "checkmark" }
        return "arrow.down.circle.fill"
    }

    var body: some View {
        Button {
            appState.startCompress()
        } label: {
            ZStack(alignment: .leading) {
                // .compress-btn-fill：压缩中蓝色 35% 脉冲 / 完成时绿色 35%
                GeometryReader { geo in
                    Rectangle()
                        .fill(fillColor)
                        .frame(width: appState.isCompressing || !appState.compressDoneText.isEmpty
                               ? geo.size.width * appState.compressProgress
                               : 0)
                        .animation(.easeOut(duration: 0.3), value: appState.compressProgress)
                }
                HStack(spacing: 6) {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 12))
                    Text(buttonText)
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                    .fill(Color.accentColor)
            )
            .foregroundColor(isDone ? .green : .white)
            .opacity(appState.pendingCount == 0 && !appState.isCompressing ? 0.4 : 1)
            .contentShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isCompressing || appState.pendingCount == 0)
        .animation(.easeOut(duration: 0.2), value: appState.compressDoneText)
    }

    private var isDone: Bool { !appState.compressDoneText.isEmpty }

    private var fillColor: Color {
        if isDone { return Color.green.opacity(0.35) }
        return Color.white.opacity(0.18)
    }
}

// MARK: - Settings Panel（.settings-panel 卡片：header 10×14 + 行分区）

struct SettingsPanelView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSystemInfo: Bool

    var body: some View {
        VStack(spacing: 0) {
            // .settings-header：padding 10×14，收起时显示摘要
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { appState.settingsExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    Text("压缩设置")
                        .font(.system(size: 13, weight: .semibold))
                    if !appState.settingsExpanded {
                        Text(appState.settingsSummary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .padding(.leading, 1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .rotationEffect(.degrees(appState.settingsExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppMetrics.sectionHPadding)
            .padding(.vertical, 10)

            if appState.settingsExpanded {
                HairlineDivider()
                VStack(spacing: 0) {
                    processingModeRow
                    rowSeparator
                    autoRow
                    if appState.options.processingMode == .system {
                        systemModeSettings
                    } else {
                        advancedModeSettings
                    }
                }
                .padding(.horizontal, AppMetrics.sectionHPadding)
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))
    }

    private var rowSeparator: some View {
        HairlineDivider()
    }

    private var processingModeRow: some View {
        SettingsRow(label: "处理方式") {
            Picker("", selection: $appState.options.processingMode) {
                Text("系统转换").tag(ProcessingMode.system)
                Text("高级压缩").tag(ProcessingMode.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 170)
            .onChange(of: appState.options.processingMode) { _ in appState.saveSettings() }
            Button {
                showSystemInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(RowActionButtonStyle())
            .help("系统转换说明")
        }
    }

    private var autoRow: some View {
        SettingsRow(label: "自动处理", showSeparator: false) {
            Toggle(appState.options.processingMode == .system ? "拖入或选择后自动转换" : "拖入或选择后自动压缩",
                   isOn: $appState.autoCompress)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .onChange(of: appState.autoCompress) { _ in appState.saveSettings() }
        }
    }

    // 与 index.html 的 DOM 顺序一致：输出模式插在 系统参数 / 压缩质量 与 智能模式 之间
    var systemModeSettings: some View {
        Group {
            SettingsRow(label: "格式") {
                Picker("", selection: $appState.options.outputFormat) {
                    Text("原格式").tag(OutputFormat.original)
                    Text("JPEG").tag(OutputFormat.jpg)
                    Text("PNG").tag(OutputFormat.png)
                    Text("HEIF").tag(OutputFormat.heic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: appState.options.outputFormat) { _ in appState.saveSettings() }
            }
            SettingsRow(label: "图像大小") {
                Picker("", selection: $appState.options.systemImageSize) {
                    ForEach(SystemImageSize.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 170, alignment: .leading)
                .onChange(of: appState.options.systemImageSize) { _ in appState.saveSettings() }
            }
            SettingsRow(label: "元数据") {
                Toggle("保留元数据", isOn: $appState.options.preserveMetadata)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .onChange(of: appState.options.preserveMetadata) { _ in appState.saveSettings() }
            }
            outputModeSection
        }
    }

    var advancedModeSettings: some View {
        Group {
            SettingsRow(label: "压缩质量") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(appState.options.quality) },
                        set: { appState.options.quality = Int($0); appState.saveSettings() }
                    ), in: 10...100, step: 1)
                    .controlSize(.small)
                    Text("\(appState.options.quality)%")
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            outputModeSection
            SettingsRow(label: "智能模式") {
                Toggle("自动选择最佳算法和参数", isOn: $appState.options.smartMode)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .onChange(of: appState.options.smartMode) { _ in appState.saveSettings() }
            }
            SettingsRow(label: "转换为 WebP") {
                Toggle("输出为 WebP 格式（更小体积）", isOn: $appState.options.convertToWebp)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .onChange(of: appState.options.convertToWebp) { _ in appState.saveSettings() }
            }
            SettingsRow(label: "输出格式") {
                Picker("", selection: $appState.options.outputFormat) {
                    Text("保持原格式").tag(OutputFormat.original)
                    Text("JPEG").tag(OutputFormat.jpg)
                    Text("PNG").tag(OutputFormat.png)
                    Text("WebP").tag(OutputFormat.webp)
                    Text("AVIF").tag(OutputFormat.avif)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130, alignment: .leading)
                .onChange(of: appState.options.outputFormat) { _ in appState.saveSettings() }
            }
            SettingsRow(label: "压缩引擎") {
                Picker("", selection: $appState.options.backend) {
                    ForEach(CompressionBackend.allCases, id: \.self) { b in
                        Text(b.label).tag(b)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160, alignment: .leading)
                .onChange(of: appState.options.backend) { _ in appState.saveSettings() }
            }
            SettingsRow(label: "压缩力度") {
                Picker("", selection: $appState.options.effort) {
                    ForEach(CompressionEffort.allCases, id: \.self) { e in
                        Text(e.label).tag(e)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150, alignment: .leading)
                .onChange(of: appState.options.effort) { _ in appState.saveSettings() }
            }
        }
    }

    var outputModeSection: some View {
        Group {
            SettingsRow(label: "输出模式") {
                Picker("", selection: $appState.options.outputMode) {
                    Text("覆盖原文件").tag(OutputMode.replace)
                    Text("添加自定义后缀").tag(OutputMode.suffix)
                    Text("输出到指定文件夹").tag(OutputMode.folder)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .font(.system(size: 11))
                .onChange(of: appState.options.outputMode) { _ in appState.saveSettings() }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if appState.options.outputMode == .suffix {
                SettingsRow(label: "文件名后缀") {
                    HStack(spacing: 8) {
                        TextField("_compressed", text: $appState.options.outputSuffix)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 160)
                            .onChange(of: appState.options.outputSuffix) { _ in appState.saveSettings() }
                        Text("例如 _small")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    }
                }
            }
            if appState.options.outputMode == .folder {
                SettingsRow(label: "输出目录", showSeparator: false) {
                    HStack(spacing: 8) {
                        Text(appState.options.outputDir ?? "未选择")
                            .font(.system(size: 11))
                            .foregroundColor(appState.options.outputDir == nil
                                             ? Color(nsColor: .tertiaryLabelColor) : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .leading)
                        Button("浏览") { _ = appState.pickOutputDir() }
                            .buttonStyle(SecondaryButtonStyle())
                            .font(.system(size: 11))
                    }
                }
            } else {
                // 折叠：最后可见行不画分隔线
                LastRowHider()
            }
        }
    }
}

/// 输出模式为 folder 以外时，隐藏前一行残留分隔线的空实现（分隔线逻辑集中在 SettingsRow）
private struct LastRowHider: View {
    var body: some View { EmptyView() }
}

// MARK: - System Info Modal

struct SystemInfoModal: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                    Text("系统转换说明")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
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
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.top, 2)
            }
            .padding(16)
            .frame(width: 400)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 16, y: 4)
            .padding(24)
        }
    }
}

// MARK: - 小工具：Label 图标与文字间距

extension Label {
    /// 精确控制图标与文字间距（对应 .btn 的 gap: 5px）
    func labelIconToTextSpacing(_ spacing: CGFloat) -> some View {
        environment(\.symbolRenderingMode, .monochrome)
            // SwiftUI Label 原生间距约为 4-6，这里通过字体微调保持紧凑
            .font(.system(size: 12, weight: .medium))
    }
}
