import SwiftUI
import UIKit

/// The app's single motion vocabulary — restrained springs (slight overshoot,
/// settles fast) plus a soft crossfade for every content swap. Use THESE, never
/// ad-hoc curves, so the whole app moves like one material.
enum Motion {
    /// Press feedback, toggles, chips — quick with a whisper of bounce.
    static let snap = Animation.spring(response: 0.32, dampingFraction: 0.85)
    /// The drawer/rail — heavier surface, settles with authority.
    /// Discord-feel drawer: FAST launch with a soft landing — snappy overall
    /// (~0.26s) with a whisper of overshoot so it reads as velocity, not lag.
    static let drawer = Animation.spring(response: 0.26, dampingFraction: 0.82)
    /// Elements popping into existence (badges, bubbles, banners).
    static let pop = Animation.spring(response: 0.30, dampingFraction: 0.78)
    /// 渐进渐变 — the default crossfade for content/state swaps.
    static let fade = Animation.easeOut(duration: 0.22)
}

/// Prepared haptic generators — motion and touch land together.
enum Haptics {
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectGen = UISelectionFeedbackGenerator()
    private static let notifyGen = UINotificationFeedbackGenerator()

    static func light() { lightGen.impactOccurred() }
    static func soft() { softGen.impactOccurred() }
    static func rigid() { rigidGen.impactOccurred() }
    static func selection() { selectGen.selectionChanged() }
    static func success() { notifyGen.notificationOccurred(.success) }
}

/// Pop-in for a NEWLY appended message cell: rises 6pt with a fade and a whisper
/// of scale, springs into place. Inert (`active == false`) for history loads and
/// cell reuse — the guard lives in the adapter's tail-append detection.
struct NewMessagePop: ViewModifier {
    let active: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(!active || shown ? 1 : 0)
            .scaleEffect(!active || shown || reduceMotion ? 1 : 0.97, anchor: .bottom)
            .offset(y: !active || shown || reduceMotion ? 0 : 6)
            .onAppear {
                guard active, !shown else { shown = true; return }
                withAnimation(reduceMotion ? Motion.fade : Motion.pop) { shown = true }
            }
    }
}

/// Press feedback for cards/slots/chips: a 3% sink + slight lift in brightness,
/// spring-released. (Static surfaces answering the finger is most of "手感".)
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? 0.05 : 0)
            .animation(Motion.snap, value: configuration.isPressed)
    }
}
