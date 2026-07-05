import SwiftUI

/// Claude's sunburst mark on a terracotta disc — the avatar Claude posts under
/// in the channel (matches the `#C15F3C` circle + cream burst in the design).
struct ClaudeAvatar: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0xc15f3c))
            ClaudeBurst()
                .stroke(Color(hex: 0xf7f4ec),
                        style: StrokeStyle(lineWidth: max(1.4, size * 0.085), lineCap: .round))
                .frame(width: size * 0.66, height: size * 0.66)
        }
        .frame(width: size, height: size)
    }
}

private struct ClaudeBurst: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let rays = 12
        for i in 0 ..< rays {
            let a = Double(i) / Double(rays) * 2 * .pi
            let inner = 0.16 * r
            p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * inner, y: c.y + CGFloat(sin(a)) * inner))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
        }
        return p
    }
}

/// A flat colored disc with a centered monospace initial (sessions list + user).
struct InitialAvatar: View {
    let text: String
    var color: Color
    var size: CGFloat = 44
    var textColor: Color = .white

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Text(text)
                    .font(AppFont.mono(size * 0.38, .semibold))
                    .foregroundStyle(textColor)
            )
    }
}
