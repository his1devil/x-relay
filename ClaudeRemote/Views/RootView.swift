import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var themeController: ThemeController
    @EnvironmentObject private var relay: RelayHub
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()

    @State private var showSplash = true
    @State private var bannerVisible = false
    @State private var bannerWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            NavigationStack(path: $path) {
                SessionsDrawerView()
            }
            .environment(\.theme, themeController.mode.theme)
            .tint(themeController.mode.theme.blurple)
            .preferredColorScheme(themeController.mode == .dark ? .dark : .light)
            .safeAreaInset(edge: .top, spacing: 0) {
                if relay.anyEnabled, bannerVisible {
                    ConnectionBanner(connecting: relay.state == .connecting, error: relay.lastError) { relay.connect() }
                        .environment(\.theme, themeController.mode.theme)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: bannerVisible)

            if showSplash {
                SplashView()
                    .environment(\.theme, themeController.mode.theme)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["CR_MOCK"] != nil {
                store.loadMock()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                    withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
                }
                return
            }
            #endif
            store.load()
            // Screenshot/dev hook: SIMCTL_CHILD_CR_PAIRING=<base64>[,<base64>…]
            // auto-pairs one or more devices (ephemeral).
            if let p = ProcessInfo.processInfo.environment["CR_PAIRING"], !relay.paired {
                for s in p.split(separator: ",") { relay.add(String(s), persist: false, connectImmediately: true) }
            } else {
                relay.loadPersisted()   // restores devices; only switched-on ones connect
            }
            // Hold the splash a beat so first paint + initial connect settle, then
            // cross-fade into the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
            }
        }
        .onChange(of: relay.state) { _, _ in evaluateBanner() }
        .onChange(of: relay.paired) { _, _ in evaluateBanner() }
        .onReceive(NotificationCenter.default.publisher(for: .crJumpSession)) { note in
            // Jump banner tapped in a thread → navigate to the newer session.
            guard let id = note.userInfo?["id"] as? String,
                  let target = relay.sessions.first(where: { $0.id == id }) else { return }
            path.append(target)
        }
        .onChange(of: scenePhase) { old, new in
            if new == .active, old != .active {
                if !store.sessions.isEmpty { store.refresh() }
                // Probe liveness, not just state: a half-open socket still reports
                // .online but is dead after backgrounding / a network switch. Also
                // re-pull the session list — it may have moved while backgrounded.
                if relay.anyEnabled {
                    relay.ensureLive()
                    relay.requestSessions()
                }
            }
        }
        .onChange(of: store.sessions) { _, sessions in
            // Screenshot/dev hook: SIMCTL_CHILD_CR_AUTOPUSH=<idx> opens the nth
            // session straight away so the channel view can be captured headless.
            if !relay.paired { autopush(sessions) }
        }
        .onChange(of: relay.sessions) { _, sessions in
            if relay.paired { autopush(sessions) }
        }
    }

    /// Show the offline/reconnecting banner only after the link has actually been
    /// down for a couple seconds — a normal quick (re)connect on launch shouldn't
    /// flash a red bar.
    private func evaluateBanner() {
        bannerWork?.cancel()
        if !relay.anyEnabled || relay.state == .online {
            if bannerVisible { withAnimation(.easeInOut(duration: 0.25)) { bannerVisible = false } }
            return
        }
        let work = DispatchWorkItem {
            if relay.anyEnabled, relay.state != .online {
                withAnimation(.easeInOut(duration: 0.25)) { bannerVisible = true }
            }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func autopush(_ sessions: [Session]) {
        guard path.isEmpty, !sessions.isEmpty else { return }
        let env = ProcessInfo.processInfo.environment
        if let id = env["CR_AUTOPUSH_ID"], let s = sessions.first(where: { $0.id == id }) {
            path.append(s); return
        }
        if let v = env["CR_AUTOPUSH"] {
            path.append(sessions[max(0, min(Int(v) ?? 0, sessions.count - 1))])
        }
    }
}

/// Launch placeholder — the HALX mark springs in over the app surface, then the
/// whole splash cross-fades away to reveal the session list.
struct SplashView: View {
    @Environment(\.theme) private var theme
    @State private var appear = false

    var body: some View {
        ZStack {
            theme.screen.ignoresSafeArea()
            VStack(spacing: 16) {
                SignalLogoTile(size: 88)
                    .scaleEffect(appear ? 1 : 0.82)
                    .opacity(appear ? 1 : 0)
                Text("HALX")
                    .font(AppFont.sans(26, .bold))
                    .tracking(4)
                    .foregroundStyle(theme.white)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 6)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { appear = true }
        }
    }
}
