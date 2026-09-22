import SwiftUI
import AppKit

// MARK: - 历史页文案（与 frontend/app.js 的 historyRow 逐项对齐）

func historyParentDir(_ path: String) -> String {
    (path as NSString).deletingLastPathComponent
}

func historyTimeText(_ millis: Int64) -> String {
    guard millis > 0 else { return "" }
    let date = Date(timeIntervalSince1970: Double(millis) / 1000.0)
    let calendar = Calendar.current
    let clock = String(
        format: "%02d:%02d",
        calendar.component(.hour, from: date),
        calendar.component(.minute, from: date)
    )
    if calendar.isDateInToday(date) { return "今天 \(clock)" }
    if calendar.isDateInYesterday(date) { return "昨天 \(clock)" }
    return String(
        format: "%04d-%02d-%02d %@",
        calendar.component(.year, from: date),
        calendar.component(.month, from: date),
        calendar.component(.day, from: date),
        clock
    )
}

func historyStatusText(_ entry: HistoryEntry) -> String {
    if entry.status == .restored {
        guard let restoredAt = entry.restoredAt else { return "已恢复" }
        return "已恢复 · \(historyTimeText(restoredAt))"
    }
    if entry.status == .recoveryAvailable {
        return entry.backupExists ? "检测到可恢复的原图备份" : "原图备份已清理"
    }
    if entry.outputMode != "replace" { return "原图未覆盖" }
    if !entry.sourceExists { return "原文件位置不存在" }
    if !entry.backupExists { return "原图备份已清理" }
    return "已压缩"
}

/// 重建条目没有这次压缩的明细，报一个算出来的 0.0% 节省率是假数字。
func historySavingsText(_ entry: HistoryEntry) -> String {
    entry.status == .recoveryAvailable ? "明细已丢失" : "节省 \(String(format: "%.1f", abs(entry.savings)))%"
}

/// 算法位上写的是"这条记录怎么来的"：重建条目不是任何一次真实压缩。
func historyAlgorithmText(_ entry: HistoryEntry) -> String {
    entry.status == .recoveryAvailable ? "按备份重建" : (entry.algorithm.isEmpty ? entry.outType : entry.algorithm)
}

// MARK: - 历史记录页（主窗口内部视图：切过来不影响队列，也不打断压缩）

struct HistoryPageView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            ViewHeaderView(title: "历史记录", systemImage: "clock.arrow.circlepath") {
                Text("\(appState.historyEntries.count) 条")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 2)
                Button {
                    appState.clearHistory()
                } label: {
                    Label("清空历史", systemImage: "trash").labelIconToTextSpacing(3)
                }
                .buttonStyle(GhostButtonStyle())
                // 清空 = 连原图备份一起删。压缩进行中禁用；真正的判据在后端
                // （clearHistory 还会看有没有挂着的事务）。
                .disabled(appState.historyEntries.isEmpty || appState.scheduler.isBatchActive)
                .help("清空历史记录，以及 OctoShrink 保存的原图备份")
            }

            if appState.historyEntries.isEmpty {
                HairlineDivider()
                Text("还没有压缩记录")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ForEach(appState.historyEntries) { entry in
                    HairlineDivider()
                    HistoryRowView(entry: entry)
                }
            }
        }
        .cardStyle()
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))
        // 每次进入都重新读一遍：压缩、恢复可能刚刚改过历史。
        .onAppear { appState.refreshHistory() }
    }
}

// MARK: - 历史行（.history-item：min-height 40，11px，与队列行同密度）

struct HistoryRowView: View {
    @EnvironmentObject var appState: AppState
    let entry: HistoryEntry

    private var isRecovery: Bool { entry.status == .recoveryAvailable }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color(nsColor: .separatorColor).opacity(0.35))
                Image(systemName: rowIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(rowIconColor)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.sourcePath)
                Text("\(historyParentDir(entry.sourcePath)) · \(historyStatusText(entry))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(CompressResult.formatBytesJS(entry.originalSize)) → \(CompressResult.formatBytesJS(entry.compressedSize))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                Text(historySavingsText(entry))
                    .font(.system(size: 10))
                    .foregroundColor(isRecovery ? .secondary : (entry.savings >= 0 ? .green : .orange))
            }
            .frame(width: 132, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(historyTimeText(entry.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Text(historyAlgorithmText(entry))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .trailing)

            HStack(spacing: 2) {
                // 与队列「压缩完成」那一行同一套按钮，按这条记录真实能做到的事给。
                // 判据在服务层（historyRowActions），视图只负责摆 —— 前端 app.js 是同一份顺序。
                ForEach(historyRowActions(entry), id: \.self) { action in
                    Button { perform(action) } label: {
                        Image(systemName: action.symbol)
                    }
                    .buttonStyle(RowActionButtonStyle())
                    .help(action.title)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, AppMetrics.sectionHPadding)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .opacity(entry.status == .restored || isRecovery ? 0.55 : 1)
    }

    private func perform(_ action: HistoryRowAction) {
        switch action {
        case .saveAs: appState.saveHistoryOutput(entry)
        case .compare: appState.compareHistoryEntry(entry)
        case .restore: appState.restoreHistoryEntry(id: entry.id)
        case .deleteOutput: appState.deleteHistoryOutput(entry)
        case .finder: appState.openInFinder(path: finderTarget(entry))
        case .copyLog: appState.copyHistoryLog(entry)
        }
    }

    /// 重建条目用警告图标而不是对勾：它不是一次成功的压缩，是一次数据抢救。
    private var rowIcon: String {
        if isRecovery { return "exclamationmark.triangle" }
        return entry.status == .restored ? "arrow.uturn.backward" : "checkmark"
    }

    private var rowIconColor: Color {
        if isRecovery { return .orange }
        return entry.status == .restored ? .secondary : .green
    }

    /// 压缩结果与源文件不是同一个时优先跳到结果，否则回到源路径。
    private func finderTarget(_ entry: HistoryEntry) -> String {
        if let output = entry.outputPath,
           output != entry.sourcePath,
           entry.status == .compressed,
           FileManager.default.fileExists(atPath: output) {
            return output
        }
        return entry.sourcePath
    }
}
