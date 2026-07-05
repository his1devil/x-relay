import SwiftUI

/// Channels the list-pan's drag events into the shell without making the heavy
/// drawer body observe per-frame state. The drawer wires its catcher to call
/// these; the shell installs the implementations on appear.
final class RailDragBox {
    var track: (CGFloat) -> Void = { _ in }
    var release: (CGFloat, CGFloat) -> Void = { _, _ in }
}

/// The drawer's motion layer, isolated for 120Hz drags: `progress` lives HERE, so
/// each drag frame re-evaluates only this ZStack's transforms — the panel and rail
/// view trees are built once by the parent and reused untouched. (Keeping progress
/// in the drawer's @State re-ran buildRows()+50 row constructions per frame — the
/// visible hitch when the drawer first moved.)
struct DrawerShell<Panel: View, Rail: View>: View {
    @Binding var railVisible: Bool
    let railWidth: CGFloat
    let parallax: CGFloat
    let box: RailDragBox
    let panel: Panel
    let rail: Rail

    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            panel
                .offset(x: parallax * progress)
            Color.black
                .opacity(0.38 * progress)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { setRail(open: false) }
                // Close by dragging left on the scrim — finger-tracked, same feel
                // as opening. Lives on the scrim (hit-testable only while open) so
                // it can never contest the list's UIKit open-pan when closed.
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { v in
                            progress = clamp(1 + min(0, v.translation.width) / railWidth)
                        }
                        .onEnded { v in
                            settle(velocity: (v.predictedEndTranslation.width - v.translation.width) * 4)
                        }
                )
                .allowsHitTesting(progress > 0.02)
            rail
                .offset(x: -railWidth * (1 - progress))
                .zIndex(1)
                .allowsHitTesting(progress > 0.6)
        }
        .onAppear {
            box.track = { dx in
                guard !railVisible else { return }
                progress = clamp(dx / railWidth)
            }
            box.release = { _, vel in
                guard !railVisible else { return }
                settle(velocity: vel)
            }
        }
        .onChange(of: railVisible) { _, open in
            // External toggles (header button) drive the binding; animate to match.
            withAnimation(Motion.drawer) { progress = open ? 1 : 0 }
        }
    }

    /// Rubber-band past the edges so overdrag feels physical, not clipped.
    private func clamp(_ p: CGFloat) -> CGFloat {
        if p < 0 { return p / 6 }
        if p > 1 { return 1 + (p - 1) / 6 }
        return p
    }

    private func setRail(open: Bool) {
        railVisible = open
        withAnimation(Motion.drawer) { progress = open ? 1 : 0 }
    }

    /// Finger up: project velocity to pick a side (fast flicks win over position).
    private func settle(velocity: CGFloat) {
        let projected = progress + velocity / railWidth * 0.12
        setRail(open: projected > 0.5)
    }
}
