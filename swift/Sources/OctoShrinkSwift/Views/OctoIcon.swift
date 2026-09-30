import SwiftUI

/// Swift 原生线的图标渲染：与前端 sprite 同一套 glyph（24 网格 / 1.8 描边 / 圆头圆角），
/// 路径数据由 `scripts/gen_swift_icons.py` 从 index.html + compare.html 生成
/// （`Views/OctoIconLibrary.swift`）。❌ 别手画近似版本 —— 图标一致性靠同一份数据，
/// 不靠肉眼对齐。
struct OctoIcon: View {
    let name: String
    /// 与前端 `.symbol-icon` 对齐的尺寸档：默认 16（small 15 / hero 32）。
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        let scale = size / 24
        ZStack {
            ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                switch element {
                case .stroke(let ops):
                    Self.path(for: ops, scale: scale)
                        .stroke(
                            color,
                            style: StrokeStyle(
                                lineWidth: 1.8 * scale,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                case .fill(let ops):
                    Self.path(for: ops, scale: scale).fill(color)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var elements: [OctoIconElement] {
        OctoIconLibrary.icons[name] ?? []
    }

    private static func path(for ops: [OctoPathOp], scale: CGFloat) -> Path {
        var path = Path()
        for op in ops {
            switch op {
            case .move(let x, let y):
                path.move(to: CGPoint(x: x * scale, y: y * scale))
            case .line(let x, let y):
                path.addLine(to: CGPoint(x: x * scale, y: y * scale))
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                path.addCurve(
                    to: CGPoint(x: x * scale, y: y * scale),
                    control1: CGPoint(x: x1 * scale, y: y1 * scale),
                    control2: CGPoint(x: x2 * scale, y: y2 * scale)
                )
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}
