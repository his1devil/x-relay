import SwiftUI

/// Channels the list-pan's drag events into the shell without making the heavy
/// drawer body observe per-frame state. The drawer wires its catcher to call
/// these; the shell installs the implementations on appear.
final class RailDragBox {
    var begin: () -> Void = {}
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
    /// Called with true at drag/animation start, false after settle — the
    /// drawer wires this to RelayHub.holdUpdates to keep pushes out of the
    /// animation window.
    var onMotion: ((Bool) -> Void)? = nil
    let panel: Panel
    let rail: Rail

    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            panel
                // Flatten the (heavy) panel into ONE composited layer so the
                // open/close animation moves a texture, not a live tree —
                // the rail animation stuttered while dozens of session rows
                // re-composited every frame.
                .compositingGroup()
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
                .compositingGroup()
                .offset(x: -railWidth * (1 - progress))
                .zIndex(1)
                .allowsHitTesting(progress > 0.6)
        }
        .onAppear {
            box.begin = {
                guard !railVisible else { return }
                // Pre-warm: hold pushes AND nudge the composited layers into
                // existence a few ms before the first .changed — the panel's
                // first-rasterization spike used to land exactly on the first
                // visible frame of a finger drag (buttons never showed it
                // because the spring's slow start hid the same spike).
                onMotion?(true)
                if progress == 0 { progress = 0.001 }
            }
            box.track = { dx in
                guard !railVisible else { return }
                let target = clamp(dx / railWidth)
                if progress <= 0.002 {
                    // First real frame arrives pre-loaded with the recognizer's
                    // ~15pt threshold — melt the jump instead of teleporting.
                    withAnimation(.easeOut(duration: 0.06)) { progress = target }
                } else {
                    progress = target
                }
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
        onMotion?(true)
        withAnimation(Motion.drawer) { progress = open ? 1 : 0 }
        // Release after the spring lands (0.26s response ⇒ ~0.4s tail).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onMotion?(false) }
    }

    /// Finger up: project velocity to pick a side (fast flicks win over position).
    private func settle(velocity: CGFloat) {
        // 0.18: a decisive flick commits earlier — the settle starts from a
        // higher projected progress, so the spring covers less distance and
        // the drawer feels immediate (Discord-like).
        let projected = progress + velocity / railWidth * 0.18
        setRail(open: projected > 0.5)
    }
}
