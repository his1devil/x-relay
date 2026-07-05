import SwiftUI

/// The "Signal" brand mark from the icon system — a clay dot broadcasting three
/// concentric arcs up-and-right. Drawn with `Canvas` (definite size, reliable in
/// stacks/sheets) so it stays crisp at any size and can be tinted; the app icon
/// uses the same geometry on an ink tile.
struct SignalMark: View {
    var dot: Color = Color(hex: 0xd97757)
    var inner: Color = Color(hex: 0xf0e7dc)
    var mid: Color = Color(hex: 0xd2c6ba)
    var outer: Color = Color(hex: 0x8c7e70)

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let lw = 6.5 * s
            let c = CGPoint(x: 31 * s, y: 69 * s)

            func arc(_ r: CGFloat, _ color: Color) {
                var p = Path()
                p.addArc(center: c, radius: r * s,
                         startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
            arc(46, outer)
            arc(34, mid)
            arc(22, inner)

            let dr = 6.5 * s
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - dr, y: c.y - dr, width: dr * 2, height: dr * 2)),
                     with: .color(dot))
        }
    }
}

/// The mark on the rounded ink tile (matches the app icon), for in-app branding.
struct SignalLogoTile: View {
    var size: CGFloat = 64
    var body: some View {
        SignalMark()
            .padding(size * 0.18)
            .frame(width: size, height: size)
            .background(
                RadialGradient(colors: [Color(hex: 0x262019), Color(hex: 0x15110d)],
                               center: .init(x: 0.3, y: 0.22), startRadius: 0, endRadius: size)
            )
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
