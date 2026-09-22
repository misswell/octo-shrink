import SwiftUI

// MARK: - 设置页（App 级设置，与压缩参数面板分开）

struct AppSettingsPageView: View {
    @EnvironmentObject var appState: AppState
    // 拖动期间只更新本地预览，松手才落盘并通知调度器 ——
    // 与 Tauri 前端 input（预览）/ change（提交）的分工一致，否则每滑一格弹一次提示。
    @State private var draftLimit: Int?

    var body: some View {
        VStack(spacing: 0) {
            ViewHeaderView(title: "设置", systemImage: "gearshape")

            // .view-section-header：卡片内的小节标题
            HStack(spacing: 5) {
                Text("历史记录与原图")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, AppMetrics.sectionHPadding)
            .padding(.vertical, 10)
            HairlineDivider()

            VStack(spacing: 0) {
                SettingsRow(label: "原图备份保留时间", showSeparator: false) {
                    Picker("", selection: Binding(
                        get: { appState.retentionDays },
                        set: { appState.setRetentionDays($0) }
                    )) {
                        ForEach(Retention.options, id: \.self) { days in
                            Text(Retention.label(days)).tag(days)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                }
            }
            .padding(.horizontal, AppMetrics.sectionHPadding)

            // 措辞固定：说的是 OctoShrink 自己的备份副本，不是用户的图片。
            Text(retentionCopyText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppMetrics.sectionHPadding)
                .padding(.top, 8)
                .padding(.bottom, 12)

            HairlineDivider()

            // MARK: 性能（方案 §62：一小节就够，不另起一整个面板）

            HStack(spacing: 5) {
                Text("性能")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, AppMetrics.sectionHPadding)
            .padding(.vertical, 10)
            HairlineDivider()

            VStack(spacing: 0) {
                SettingsRow(label: "当前设备", showSeparator: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CPUStatusText.device(appState.cpuInfo))
                            .font(.system(size: 12, weight: .medium))
                        Text(CPUStatusText.cores(appState.cpuInfo))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                SettingsRow(label: "CPU 使用上限", showSeparator: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { Double(draftLimit ?? appState.effectiveCpuThreadLimit) },
                                    set: { draftLimit = Int($0) }
                                ),
                                in: 1...Double(appState.cpuInfo.budgetCeiling),
                                step: 1,
                                onEditingChanged: { editing in
                                    if !editing, let draftLimit {
                                        appState.setCpuThreadLimit(draftLimit)
                                    }
                                }
                            )
                            .controlSize(.small)
                            .frame(minWidth: 120)

                            Text(limitLabelText)
                                .font(.system(size: 11, design: .rounded).monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 74, alignment: .trailing)

                            Button("自动") { appState.setCpuThreadLimit(nil) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundColor(appState.cpuThreadLimit == nil ? .accentColor : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                                        .fill(Color.primary.opacity(appState.cpuThreadLimit == nil ? 0.10 : 0.06))
                                )
                                .help("不指定，按机器性能自动决定")
                        }
                        HStack {
                            Text("低占用").font(.system(size: 10)).foregroundColor(.secondary)
                            Spacer()
                            Text("高性能").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, AppMetrics.sectionHPadding)
            .onAppear { draftLimit = appState.cpuThreadLimit }
            .onChange(of: appState.cpuThreadLimit) { draftLimit = $0 }

            // 措辞固定：报的是并行预算，不是绑定核心；P/E 调度只对大小核架构成立。
            Text(cpuCopyText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppMetrics.sectionHPadding)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .cardStyle()
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous))
    }

    /// 「不保留」不能说成"保留 0 天"，也不能写得像"原图马上就没救了"：
    /// 覆盖前照旧备份，只是这份备份的寿命到本次退出为止。
    private var retentionCopyText: String {
        var text = "覆盖原文件时，OctoShrink 会先保存一份原图备份。\n"
        text += appState.retentionDays == Retention.noRetain
            ? "原图备份只在这次运行期间保留，关闭应用时清理；期间可以随时恢复原图。"
            : "过期的历史记录和原图备份将在下次启动应用时自动清理。"
        return text
    }

    private var limitLabelText: String {
        let ceiling = appState.cpuInfo.budgetCeiling
        let shown = min(max(draftLimit ?? appState.effectiveCpuThreadLimit, 1), ceiling)
        return CPUStatusText.limitLabel(
            info: appState.cpuInfo, configured: draftLimit, effective: shown)
    }

    private var cpuCopyText: String {
        var text = "限制 OctoShrink 同时使用的 CPU 并行能力。\n"
            + "较低的数值会降低压缩速度，但可为其他应用保留更多性能。"
        if appState.cpuInfo.isAppleSilicon {
            text += "\n系统会自动在性能核与能效核之间调度任务。"
        }
        return text
    }
}
