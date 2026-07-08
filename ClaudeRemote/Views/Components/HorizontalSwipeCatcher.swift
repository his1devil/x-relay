import SwiftUI
import UIKit

/// Direction-locked horizontal swipe for the drawer list.
///
/// SwiftUI-level drag gestures can't stop a ScrollView from ALSO panning (a mostly
/// horizontal swipe still scrolls the list a few points — the "手感不好"), and
/// removing them makes fast horizontal drags fall through to NavigationLink taps.
/// This installs a UIKit pan that only begins on decisively horizontal drags and
/// wires the list's own pan with `require(toFail:)` — so:
///   · horizontal swipe → our pan wins, the list never moves, row touches cancel
///   · vertical swipe   → our pan fails instantly, native scrolling untouched
///   · tap              → no pan begins, rows navigate as usual
///
/// Streams the drag (`onTrack`) and finger-up (`onRelease` with velocity) so the
/// drawer can FOLLOW the finger instead of toggling.
struct HorizontalSwipeCatcher: UIViewRepresentable {
    var onBegin: (() -> Void)? = nil                     // pan recognized, before first .changed
    var onTrack: ((CGFloat) -> Void)? = nil              // live translation.x while dragging
    var onRelease: ((CGFloat, CGFloat) -> Void)? = nil   // (translation.x, velocity.x) at finger-up

    func makeUIView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.isUserInteractionEnabled = false   // never eats touches itself
        v.onBegin = onBegin
        v.onTrack = onTrack
        v.onRelease = onRelease
        return v
    }

    func updateUIView(_ v: CatcherView, context: Context) {
        v.onBegin = onBegin
        v.onTrack = onTrack
        v.onRelease = onRelease
    }

    final class CatcherView: UIView, UIGestureRecognizerDelegate {
        var onBegin: (() -> Void)?
        var onTrack: ((CGFloat) -> Void)?
        var onRelease: ((CGFloat, CGFloat) -> Void)?
        private var installed = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            attemptInstall(retriesLeft: 20)
        }

        /// `.background` containers are SIBLINGS of the list, not ancestors — a
        /// recognizer there never sees the list's touches. Walk up until an
        /// ancestor's subtree contains the TALL scroll view (the session list; the
        /// chips bar is a short horizontal scroller we must not lock) and attach
        /// the pan to the scroll view itself. Sizes aren't laid out yet in
        /// didMoveToWindow, so retry across a few frames until the list exists.
        private func attemptInstall(retriesLeft: Int) {
            guard !installed else { return }
            var probe: UIView? = self
            var target: UIScrollView?
            while let cur = probe, target == nil {
                target = Self.findTallScroll(in: cur)
                probe = cur.superview
            }
            if let scroll = target {
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
                pan.delegate = self
                scroll.addGestureRecognizer(pan)
                scroll.panGestureRecognizer.require(toFail: pan)
                installed = true
                NSLog("[halx-catcher] installed on %@ h=%.0f", String(describing: type(of: scroll)), scroll.bounds.height)
                return
            }
            guard retriesLeft > 0 else {
                NSLog("[halx-catcher] gave up — no tall scroll host found")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.attemptInstall(retriesLeft: retriesLeft - 1)
            }
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view).x
            switch g.state {
            case .began:
                onBegin?()
            case .changed:
                onTrack?(t)
            case .ended, .cancelled, .failed:
                onRelease?(t, g.velocity(in: g.view).x)
            default:
                break
            }
        }

        override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let v = pan.view else { return false }
            let vel = pan.velocity(in: v)
            let t = pan.translation(in: v)
            return abs(vel.x) > abs(vel.y) * 1.6 && abs(t.x) >= abs(t.y)
        }

        /// Tall AND actually on screen — the always-mounted rail hosts its own tall
        /// ScrollView parked at offset −railWidth; picking that one leaves the pan
        /// listening off-screen (the "swipe went dead" regression).
        private static func findTallScroll(in root: UIView) -> UIScrollView? {
            if let s = root as? UIScrollView, s.bounds.height > 200, isOnScreen(s) { return s }
            for sub in root.subviews {
                if let f = findTallScroll(in: sub) { return f }
            }
            return nil
        }

        private static func isOnScreen(_ s: UIScrollView) -> Bool {
            guard let win = s.window else { return false }
            let f = s.convert(s.bounds, to: win)
            return f.midX > 0 && f.minX > -40 && f.midX < win.bounds.width
        }
    }
}
