import SwiftUI

// MARK: - 设计规范（对齐 frontend/style.css 的 Tauri 设计基准）

enum AppMetrics {
    /// Tauri --titlebar-height: 42px
    static let titleBarHeight: CGFloat = 42
    /// Tauri --radius: 8px（卡片圆角）
    static let cardRadius: CGFloat = 8
    /// Tauri --radius-sm: 6px（按钮/行圆角）
    static let smallRadius: CGFloat = 6
    /// Tauri .container: padding 12px 16px 16px
    static let containerPadding = EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
    /// 卡片内水平留白（.settings-header / .queue-header 等的 14px）
    static let sectionHPadding: CGFloat = 14
    /// Tauri 卡片间距（.settings-panel/.queue-panel 的 margin-bottom: 12px）
    static let cardSpacing: CGFloat = 12
    /// Tauri .file-queue-list: max-height 260px
    static let queueListMaxHeight: CGFloat = 260
}

// MARK: - 卡片容器（.settings-panel / .queue-panel 底板）

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = AppMetrics.cardRadius

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.07), radius: 1.5, y: 1)
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = AppMetrics.cardRadius) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - 半透明发丝分隔线（0.5px border-light）

struct HairlineDivider: View {
    var body: some View {
        Divider()
            .opacity(0.5)
    }
}

// MARK: - 按钮样式

/// 标题栏右侧 26pt 小按钮（.tb-btn）
struct TitleBarButtonStyle: ButtonStyle {
    /// 当前页高亮（历史 / 设置入口与 .tb-btn.active 对齐）
    var active = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(active ? .accentColor : (hovering ? .primary : .secondary))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                    .fill(Color.primary.opacity(active ? 0.10 : (hovering ? 0.08 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

/// 队列行内 22pt 图标按钮（.queue-action-btn）
struct RowActionButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .foregroundColor(hovering ? .primary : .secondary)
            .onHover { hovering = $0 }
    }
}

/// 主按钮（.btn-primary：12px/500，padding 6×16，radius 6）
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .foregroundColor(.white)
    }
}

/// 次按钮（.btn-secondary）
struct SecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.7 : (hovering ? 1.0 : 0.95))
            .onHover { hovering = $0 }
    }
}

/// 幽灵按钮（.btn-ghost + .btn-small：强调色文字，透明底，padding 4×10，11px）
struct GhostButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .onHover { hovering = $0 }
    }
}

/// 小号带边框按钮（.btn.btn-small：11px，padding 4×10，与列表行同密度）
struct SmallButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(hovering ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

// MARK: - 页面头（.view-header：返回 + 标题 + 右侧操作，与 .queue-header 同密度）

struct ViewHeaderView<Trailing: View>: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let systemImage: String
    let trailing: Trailing

    init(title: String, systemImage: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                appState.showPage(.main)
            } label: {
                Label("返回", systemImage: "chevron.left").labelIconToTextSpacing(3)
            }
            .buttonStyle(GhostButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("返回主页面（Esc）")

            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 13))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.primary)

            Spacer()
            trailing
        }
        .padding(.horizontal, AppMetrics.sectionHPadding)
        .padding(.vertical, 10)
    }
}

extension ViewHeaderView where Trailing == EmptyView {
    init(title: String, systemImage: String) {
        self.init(title: title, systemImage: systemImage, trailing: { EmptyView() })
    }
}

// MARK: - 设置行（.settings-row：label 12px/500 min-width 72，行内边距 8px，底部发丝线）

struct SettingsRow<Content: View>: View {
    let label: String
    var showSeparator = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                // Tauri label 为 min-width: 72px，长标签自然撑开不换行
                .frame(minWidth: 72, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if showSeparator { HairlineDivider() }
        }
    }
}
