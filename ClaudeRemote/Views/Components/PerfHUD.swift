#if DEBUG
import SwiftUI
import UIKit

/// Tiny DEBUG-only fps + hitch readout (e.g. "120 · 0h"), driven by a CADisplayLink.
/// A hitch = a frame that took over ~2.2× the display's nominal frame time. The
/// counter is cumulative per screen visit, so "scroll hard, watch the h number"
/// is a direct smoothness measurement on device.
final class HitchMonitor: ObservableObject {
    @Published var fps: Int = 0
    @Published var hitches: Int = 0

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var windowFrames = 0

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        windowStart = 0
        windowFrames = 0
    }

    @objc private func tick(_ l: CADisplayLink) {
        defer { lastTimestamp = l.timestamp }
        guard lastTimestamp > 0 else { windowStart = l.timestamp; return }

        let dt = l.timestamp - lastTimestamp
        let nominal = max(l.targetTimestamp - l.timestamp, 1.0 / 120.0)
        if dt > nominal * 2.2 { hitches += 1 }

        windowFrames += 1
        let elapsed = l.timestamp - windowStart
        if elapsed >= 0.5 {
            fps = Int((Double(windowFrames) / elapsed).rounded())
            windowFrames = 0
            windowStart = l.timestamp
        }
    }
}

struct PerfHUD: View {
    @Environment(\.theme) private var theme
    @StateObject private var monitor = HitchMonitor()

    var body: some View {
        Text("\(monitor.fps) · \(monitor.hitches)h")
            .font(AppFont.mono(9))
            .foregroundStyle(monitor.hitches > 0 ? theme.gold : theme.faint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(theme.card.opacity(0.7), in: Capsule())
            .onAppear { monitor.start() }
            .onDisappear { monitor.stop() }
    }
}
#endif
