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

/// 只有真正被覆盖过、且备份还在的记录才谈得上「恢复原图」。
func historyCanRestore(_ entry: HistoryEntry) -> Bool {
    entry.status == .compressed
        && entry.outputMode == "replace"
        && entry.backupExists
        && entry.sourceExists
}

func historyStatusText(_ entry: HistoryEntry) -> String {
    if entry.status == .restored {
        guard let restoredAt = entry.restoredAt else { return "已恢复" }
        return "已恢复 · \(historyTimeText(restoredAt))"
    }
    if entry.outputMode != "replace" { return "原图未覆盖" }
    if !entry.sourceExists { return "原文件位置不存在" }
    if !entry.backupExists { return "原图备份已清理" }
    return "已压缩"
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
                .disabled(appState.historyEntries.isEmpty)
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

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color(nsColor: .separatorColor).opacity(0.35))
                Image(systemName: entry.status == .restored ? "arrow.uturn.backward" : "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(entry.status == .restored ? .secondary : .green)
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
                Text("节省 \(String(format: "%.1f", abs(entry.savings)))%")
                    .font(.system(size: 10))
                    .foregroundColor(entry.savings >= 0 ? .green : .orange)
            }
            .frame(width: 132, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(historyTimeText(entry.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Text(entry.algorithm.isEmpty ? entry.outType : entry.algorithm)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .trailing)

            HStack(spacing: 4) {
                if historyCanRestore(entry) {
                    Button {
                        appState.restoreHistoryEntry(id: entry.id)
                    } label: {
                        Label("恢复原图", systemImage: "arrow.uturn.backward")
                            .labelIconToTextSpacing(3)
                    }
                    .buttonStyle(SmallButtonStyle())
                    .help("用 OctoShrink 保存的备份换回原图")
                }
                Button {
                    appState.openInFinder(path: finderTarget(entry))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(RowActionButtonStyle())
                .help("在访达中显示")
            }
        }
        .padding(.horizontal, AppMetrics.sectionHPadding)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .opacity(entry.status == .restored ? 0.55 : 1)
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
