import SwiftUI
import UIKit

// MARK: - Agent identity
//
// P1: every live session is Claude Code (the agent host today). The `agentKind`
// here is a stub that always returns `.claude`; P2 populates a real `agent`
// field on `Session` from the agent host and this becomes a stored-property read,
// at which point the rail fills with the other agents automatically.

enum AgentKind: String, CaseIterable, Identifiable {
    case claude, til, codex, cursor, gemini
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .til:    return "TIL"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        }
    }
    var short: String {
        switch self {
        case .claude: return "Claude"
        case .til:    return "TIL"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        }
    }
    /// Launch binary — matches the agent the host spawns (`claude`, `til`, …).
    var command: String { rawValue == "claude" ? "claude" : rawValue }
    /// Brand identity color — fixed, NOT theme-derived.
    var tile: Color {
        switch self {
        case .claude: return Color(hex: 0xD97757)
        case .til:    return Color(hex: 0x7C5CFF)
        case .codex:  return Color(hex: 0x10A37F)
        case .cursor: return Color(hex: 0xEDEDED)
        case .gemini: return Color(hex: 0x4285F4)
        }
    }
    /// Cursor's near-white tile needs a dark glyph + a hairline ring.
    var lightTile: Bool { self == .cursor }

    /// Map the wire `agent` string → kind (unknown/absent ⇒ Claude Code).
    static func from(_ raw: String?) -> AgentKind {
        switch raw?.lowercased() {
        case "til":    return .til
        case "codex":  return .codex
        case "cursor": return .cursor
        case "gemini": return .gemini
        default:       return .claude
        }
    }
}

// MARK: - Drawer

struct SessionsDrawerView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var themeController: ThemeController
    @EnvironmentObject private var relay: RelayHub

    /// nil == the "All" / home slot (every agent merged).
    @State private var railScope: RailScope = .all

    /// The rail scopes the list along one of two axes: by agent (Claude/TIL/Codex)
    /// or by connected host (each paired Mac running vibTTY).
    enum RailScope: Equatable {
        case all
        case agent(AgentKind)
        case host(String)
    }
    @State private var collapsed: Set<String> = []
    @State private var chip: Chip = .all
    @Namespace private var segNS
    @Namespace private var chipNS
    @State private var searchText = ""
    @ObservedObject private var profile = ProfileStore.shared
    @FocusState private var searchFocused: Bool
    @AppStorage("cr.grouping") private var groupingRaw = Grouping.recent.rawValue
    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .recent }
    private var railScopeKey: String {
        switch railScope {
        case .all: return "all"
        case let .agent(a): return "a-\(a.rawValue)"
        case let .host(h): return "h-\(h)"
        }
    }

    /// How the session list is arranged. Time buckets (mobile-chat launcher style)
    /// or project folders (the classic dev grouping).
    enum Grouping: String { case recent, project }

    /// Horizontally-scrollable status filters above the list.
    enum Chip: String, CaseIterable {
        case all = "All", active = "Active", needs = "Needs", drivable = "Drivable", preview = "Preview", today = "Today"
    }
    @State private var sheet: ActiveSheet?
    @State private var showLock = false
    @State private var railVisible = false   // logical open state (shell animates to it)
    /// Per-frame drag events flow through this box straight into DrawerShell —
    /// the drawer body itself never re-evaluates during a drag.
    @State private var dragBox = RailDragBox()
    private var railWidth: CGFloat { 292 }
    @AppStorage("cr.lastSessionId") private var lastSessionId = ""

    private enum ActiveSheet: Int, Identifiable {
        case new, pairing, profile
        var id: Int { rawValue }
    }

    // MARK: data

    private var displayed: [Session] {
        relay.anyEnabled ? relay.sessions : store.sessions
    }
    private var presentAgents: [AgentKind] {
        let s = Set(displayed.map { $0.agent })
        return AgentKind.allCases.filter { s.contains($0) }
    }
    private var scoped: [Session] {
        switch railScope {
        case .all: return displayed
        case let .agent(a): return displayed.filter { $0.agent == a }
        case let .host(h): return displayed.filter { $0.host == h }
        }
    }

    /// Paired Macs are PERSISTENT entities: a host you've connected to stays
    /// on the rail after a disconnect — with its state — instead of vanishing
    /// the moment its sessions drop out of the list.
    enum HostState { case online, connecting, offline, paused }
    struct RailHost: Identifiable {
        let id: String       // room id
        let name: String     // last-known hostname (Device.label)
        let state: HostState
        let sessions: Int
    }
    private var railHosts: [RailHost] {
        relay.devices.map { d in
            let name = d.label.isEmpty ? String(d.id.prefix(6)) : d.label
            let state: HostState
            if !d.enabled { state = .paused }
            else if let c = d.client {
                switch c.state {
                case .online: state = .online
                case .connecting: state = .connecting
                case .offline: state = .offline
                }
            } else { state = .paused }
            return RailHost(id: d.id, name: name, state: state,
                            sessions: displayed.filter { $0.host == name }.count)
        }
    }

    /// Final list = agent rail scope ∩ chip filter ∩ search terms.
    private var visible: [Session] {
        var out = scoped
        if chip != .all { out = out.filter { chipMatch($0, chip) } }
        let terms = searchText.lowercased().split(separator: " ").map(String.init)
        if !terms.isEmpty {
            out = out.filter { s in
                let hay = "\(s.name) \(s.path) \(s.host) \(s.agent.short) \(s.model ?? "") \(s.snippet)".lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
        }
        return out
    }

    private func busyState(_ s: Session) -> RelayClient.AgentStateInfo? {
        guard s.isRemote, let st = relay.liveStates[s.path] else { return nil }
        // Attribute to the EXACT session when the hook told us which one; on older
        // vibTTY (no session id) fall back to the newest session in that cwd, so
        // siblings sharing the project never all light up.
        if let sid = st.sessionId { return sid == s.id ? st : nil }
        let newest = relay.sessions
            .filter { $0.path == s.path && $0.host == s.host }
            .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        return newest?.id == s.id ? st : nil
    }

    private func isBusy(_ s: Session) -> Bool {
        ["thinking", "tool", "compacting"].contains(busyState(s)?.state ?? "")
    }

    private func chipMatch(_ s: Session, _ c: Chip) -> Bool {
        switch c {
        case .all: return true
        case .active: return isBusy(s)
        case .needs: return busyState(s)?.state == "needsPermission" || s.status == .needs
        case .drivable: return s.isRemote && s.canDrive
        case .preview: return s.isRemote && !s.canDrive
        case .today: return s.lastActivity.map { Calendar.current.isDateInToday($0) } ?? false
        }
    }

    var body: some View {
        // Rail overlays the full-bleed panel (Discord-style). All per-frame motion
        // lives in DrawerShell — panel/rail are built ONCE here and reused.
        // parallax 0: the panel stays PUT while the rail slides over it —
        // the 24pt push-aside read as unwanted movement, not depth.
        DrawerShell(railVisible: $railVisible, railWidth: railWidth, parallax: 0,
                    box: dragBox, onMotion: { relay.holdUpdates($0) },
                    panel: panel, rail: rail)
        .background(theme.codebg.ignoresSafeArea())
        .navigationBarHidden(true)
        .navigationDestination(for: Session.self) { s in
            // Route the thread to the client that OWNS this session (multi-Mac).
            ExyteThreadView(session: s, relay: relay.client(for: s) ?? relay.devices.first?.client ?? RelayClient())
        }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .new: NewSessionView()
                case .pairing: PairingView()
                case .profile: ProfileSheet()
                }
            }
            .environment(\.theme, theme)
            .environmentObject(store)
            .environmentObject(relay)
            .environmentObject(themeController)
        }
        .fullScreenCover(isPresented: $showLock) { LockView().environment(\.theme, theme) }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                switch ProcessInfo.processInfo.environment["CR_SHEET"] {
                case "new": sheet = .new
                case "pair": sheet = .pairing
                default: break
                }
                if ProcessInfo.processInfo.environment["CR_LOCK"] != nil { showLock = true }
            }
        }
    }

    // MARK: rail (agents + hosts)

    private var rail: some View {
        VStack(alignment: .leading, spacing: 6) {
            railSlot(title: "All sessions", subtitle: "\(displayed.count) total",
                     active: railScope == .all, indicator: railScope == .all ? .full : .none) {
                railScope = .all
            } content: {
                tileBox(bg: theme.blurple) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            Rectangle().fill(theme.divider).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    railSectionLabel("AGENTS")
                    ForEach(presentAgents) { a in
                        let on = railScope == .agent(a)
                        let n = displayed.filter { $0.agent == a }.count
                        railSlot(title: a.displayName, subtitle: "\(n) session\(n == 1 ? "" : "s")",
                                 active: on, indicator: on ? .full : .stub) {
                            railScope = .agent(a)
                        } content: {
                            AgentTile(kind: a)
                        }
                    }

                    if !railHosts.isEmpty {
                        railSectionLabel("HOSTS")
                        ForEach(railHosts) { h in
                            let on = railScope == .host(h.name)
                            railSlot(title: h.name, subtitle: hostSubtitle(h),
                                     active: on, indicator: on ? .full : .stub) {
                                railScope = .host(h.name)
                            } content: {
                                hostTile(state: h.state)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            Rectangle().fill(theme.divider).frame(height: 1).padding(.horizontal, 14).padding(.top, 4)
            railBottomBar
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 292)
        .frame(maxHeight: .infinity)
        .background(theme.codebg.ignoresSafeArea())
    }

    private enum Indicator { case none, stub, full }

    private func railSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(AppFont.mono(9.5, .semibold))
            .foregroundStyle(theme.faint)
            .tracking(1.2)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 1)
    }

    /// A paired-Mac tile: neutral machine glyph with a live/offline status dot.
    private func hostSubtitle(_ h: RailHost) -> String {
        switch h.state {
        case .online: return "\(h.sessions) session\(h.sessions == 1 ? "" : "s")"
        case .connecting: return "connecting…"
        case .offline: return "offline"
        case .paused: return "paused"
        }
    }

    private func hostTile(state: HostState) -> some View {
        let dot: Color
        switch state {
        case .online: dot = theme.greenText
        case .connecting: dot = theme.gold
        case .offline: dot = theme.red.opacity(0.85)
        case .paused: dot = theme.faint
        }
        return tileBox(bg: theme.card) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(state == .online ? theme.greenText : theme.sub)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(dot)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(theme.codebg, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
    }

    private func railSlot<C: View>(title: String, subtitle: String,
                                   active: Bool, indicator: Indicator,
                                   action: @escaping () -> Void,
                                   @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(active ? theme.white : theme.faint)
                .frame(width: 4, height: indicator == .full ? 36 : 8)
                .opacity(indicator == .none ? 0 : 1)
            Button(action: action) {
                HStack(spacing: 10) {
                    content()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(AppFont.sans(13.5, active ? .bold : .semibold))
                            .foregroundStyle(active ? theme.white : theme.sub)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(AppFont.mono(9.5))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .background(active ? theme.card.opacity(0.85) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .padding(.trailing, 8)
        }
        .frame(height: 56)
    }

    private func tileBox<C: View>(bg: Color, ring: Bool = false, ringColor: Color = .black.opacity(0.12),
                                  @ViewBuilder content: () -> C) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(bg)
            .frame(width: 48, height: 48)
            .overlay { content() }
            .overlay {
                if ring {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(ringColor, lineWidth: 1)
                }
            }
    }

    // MARK: panel

    private var panel: some View {
        VStack(spacing: 0) {
            panelHeader
            chipsBar
            searchBar
            groupToggle
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.card.ignoresSafeArea())   // full-bleed: header/status-bar area included
    }

    private var headerTitle: String {
        switch railScope {
        case .all: return "All sessions"
        case let .agent(a): return a.displayName
        case let .host(h): return h
        }
    }
    private var headerMeta: String {
        let n = scoped.count
        let plural = n == 1 ? "" : "s"
        switch railScope {
        case .all:
            let agents = Set(scoped.map { $0.agent }).count
            return "\(agents) agent\(agents == 1 ? "" : "s") · \(n) session\(plural)"
        case .host:
            let st = railHosts.first { $0.name == headerTitle }?.state
            return st == .online ? "Connected · \(n) session\(plural)"
                 : st == .offline ? "Offline · last known sessions" : "\(n) session\(plural)"
        case .agent:
            let hosts = Set(scoped.map { $0.host })
            if hosts.count > 1 { return "\(hosts.count) hosts · \(n) session\(plural)" }
            return "\(hosts.first ?? "—") · \(n) session\(plural)"
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 10) {
            // Always-visible rail toggle — the one fixed affordance for the sidebar.
            Button { railVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(railVisible ? theme.blurple : theme.sub)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(AppFont.sans(16, .bold))
                    .foregroundStyle(theme.white)
                    .lineLimit(1)
                Text(headerMeta)
                    .font(AppFont.mono(10))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 18) {
                Button { sheet = .new } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(theme.sub)
                }
                Menu {
                    Button { themeController.toggle() } label: {
                        Label(themeController.mode == .dark ? "Light theme" : "Dark theme",
                              systemImage: "circle.lefthalf.filled")
                    }
                    Button { sheet = .pairing } label: {
                        Label(relay.paired ? "Connection · re-pair" : "Pair a Mac", systemImage: "qrcode")
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.sub)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 1) }
    }

    /// Status chips — scrolls horizontally, live counts, stacks with rail + search.
    private var chipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Chip.allCases, id: \.self) { c in
                    let n = c == .all ? scoped.count : scoped.filter { chipMatch($0, c) }.count
                    if c == .all || n > 0 || chip == c {
                        Button {
                            guard chip != c else { return }
                            Haptics.selection()
                            withAnimation(Motion.snap) { chip = c }
                        } label: {
                            HStack(spacing: 5) {
                                if c == .active && n > 0 { PulseDot(color: chip == c ? .white : theme.claude, size: 5) }
                                Text(c.rawValue).font(AppFont.sans(12, .semibold))
                                Text("\(n)").font(AppFont.mono(10)).opacity(0.75)
                            }
                            .foregroundStyle(chip == c ? .white : theme.sub)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background {
                                ZStack {
                                    Capsule().fill(theme.codebg)
                                    if chip == c {
                                        Capsule().fill(theme.blurple)
                                            .matchedGeometryEffect(id: "chip-active", in: chipNS)
                                    }
                                }
                                // Light mode lifts controls off the white
                                // ground with a soft drop; invisible in dark.
                                .shadow(color: .black.opacity(theme.isDark ? 0 : 0.10),
                                        radius: 2.5, y: 1)
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 9)
    }

    /// Recent (time buckets) ⇄ Projects (folder groups) — persisted. The active
    /// pill SLIDES between segments (matched geometry), content crossfades.
    private var groupToggle: some View {
        HStack(spacing: 0) {
            ForEach([Grouping.recent, .project], id: \.self) { g in
                let on = grouping == g
                Button {
                    guard !on else { return }
                    Haptics.selection()
                    withAnimation(Motion.snap) { groupingRaw = g.rawValue }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: g == .recent ? "clock" : "folder")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(g == .recent ? "Recent" : "Projects")
                            .font(AppFont.sans(12, .semibold))
                    }
                    .foregroundStyle(on ? theme.white : theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(theme.card)
                                .matchedGeometryEffect(id: "seg-active", in: segNS)
                        }
                    }
                    // The WHOLE segment is the tap target — transparent padding
                    // around the label must hit too, not just the glyphs.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.codebg, in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(theme.isDark ? 0 : 0.10), radius: 2.5, y: 1)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.faint)
            TextField("", text: $searchText, prompt: Text("Search sessions").foregroundColor(theme.faint))
                .font(AppFont.sans(13))
                .foregroundStyle(theme.ink)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit { searchFocused = false }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(theme.codebg, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(theme.isDark ? 0 : 0.10), radius: 2.5, y: 1)
        // Tapping ANYWHERE on the pill focuses the field — not just the text glyphs.
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if visible.isEmpty {
            if relay.anyEnabled && relay.state != .online && scoped.isEmpty {
                skeletonList   // connecting: shimmer placeholder rows, not a bare spinner
            } else if !searchText.isEmpty || chip != .all {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(theme.faint)
                    Text("No matches").font(AppFont.sans(13.5, .semibold)).foregroundStyle(theme.muted)
                    Button("Clear filters") { searchText = ""; chip = .all }
                        .font(AppFont.sans(12.5, .semibold)).foregroundStyle(theme.blurple)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                emptyState
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(buildRows()) { row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                // 行级动效:session 卡片保持稳定身份(s.id),切换 chips/分组/
                // scope 时以弹簧"飞"到新位置;分组头随差量淡入淡出。
                .animation(Motion.fade, value: chip)
                .animation(Motion.snap, value: groupingRaw)
                .animation(Motion.snap, value: railScopeKey)
                // While the search keyboard is up, rows go inert: the first tap
                // anywhere just dismisses the keyboard instead of opening a session.
                .disabled(searchFocused)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)   // scrolling the list tucks the search keyboard away
            .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
            // Direction-locked rail swipe (UIKit require-to-fail): the drag STREAMS
            // into railProgress so the drawer follows the finger; release settles.
            .background(HorizontalSwipeCatcher(
                onBegin: { dragBox.begin() },
                onTrack: { dragBox.track($0) },
                onRelease: { dragBox.release($0, $1) }
            ))
            .refreshable {
                if relay.paired { relay.requestSessions() } else { store.refresh() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: relay.paired ? "tray" : "qrcode.viewfinder")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.faint)
            Text(relay.paired ? "No sessions yet" : "Pair a Mac to begin")
                .font(AppFont.sans(14, .semibold))
                .foregroundStyle(theme.muted)
            if !relay.paired {
                Button { sheet = .pairing } label: {
                    Text("Scan pairing code")
                        .font(AppFont.sans(13, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(theme.blurple, in: Capsule())
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: DrawerRow) -> some View {
        switch row {
        case let .bucket(label):
            Text(label)
                .font(AppFont.sans(13, .semibold))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 6)

        case let .projectHeader(key, label, host, count):
            Button { toggle(key) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.muted)
                        .rotationEffect(.degrees(collapsed.contains(key) ? -90 : 0))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.faint)
                    Text(host.map { "\($0) / \(label)" } ?? label)
                        .font(AppFont.sans(12.5, .bold))
                        .foregroundStyle(theme.sub)
                        .lineLimit(1)
                    Text("\(count)")
                        .font(AppFont.mono(9.5))
                        .foregroundStyle(theme.faint)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 15)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case let .session(s):
            NavigationLink(value: s) {
                ChannelRow(session: s, live: busyState(s), isLastOpened: s.id == lastSessionId)
            }
            .buttonStyle(PressableStyle(scale: 0.98))
        }
    }

    /// Connecting placeholder — shimmering skeleton rows where sessions will land.
    private var skeletonList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0 ..< 6, id: \.self) { i in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(theme.codebg).frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(theme.codebg)
                            .frame(width: i % 2 == 0 ? 210 : 150, height: 11)
                        RoundedRectangle(cornerRadius: 3).fill(theme.codebg.opacity(0.6))
                            .frame(width: 110, height: 8)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
            }
            Spacer()
        }
        .padding(.top, 8)
        .shimmering()
    }

    private func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    // MARK: footer + diagnostic

    /// Rail bottom: user identity on the left, pair-a-Mac on the right — one row.
    private var railBottomBar: some View {
        HStack(spacing: 9) {
            Button { Haptics.selection(); sheet = .profile } label: {
                HStack(spacing: 9) {
                    ZStack(alignment: .bottomTrailing) {
                        UserAvatar(size: 32)
                        Circle().fill(footerColor).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(theme.codebg, lineWidth: 2.5))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(profile.nickname).font(AppFont.sans(13, .semibold))
                            .foregroundStyle(theme.white).lineLimit(1)
                        Text(footerStatus).font(AppFont.mono(10)).foregroundStyle(theme.muted).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            Spacer(minLength: 4)
            Button { sheet = .pairing } label: {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(theme.codebg)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.greenText)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var footerColor: Color {
        switch relay.state {
        case .online: return theme.greenText
        case .connecting: return theme.gold
        case .offline: return theme.red
        }
    }
    private var footerStatus: String {
        if !relay.paired { return store.isLive ? "local · live" : "not paired" }
        switch relay.state {
        case .online: return "online"
        case .connecting: return "connecting…"
        case .offline: return "offline"
        }
    }

    // Temporary connection diagnostic (kept while build 7 reliability is verified).
    private var stateTag: String {
        switch relay.state {
        case .online: return "on"
        case .connecting: return "..."
        case .offline: return "off"
        }
    }

    // MARK: row model
    //
    // host band (only when an agent spans >1 host) → project header → sessions.
    // With a single host the band is omitted, so it reads exactly like the mockup.

    /// Time-bucketed flat list (Today / Yesterday / This week / Earlier) — busy
    /// sessions bubble into "now" naturally via their fresh mtimes; host/project
    /// context moved INTO each card's subline.
    private func buildRows() -> [DrawerRow] {
        grouping == .project ? buildProjectRows() : buildRecentRows()
    }

    private func buildRecentRows() -> [DrawerRow] {
        let mine = visible.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        var out: [DrawerRow] = []
        var current: String?
        for s in mine {
            let b = bucketLabel(s.lastActivity)
            if b != current { out.append(.bucket(b)); current = b }
            out.append(.session(s))
        }
        return out
    }

    /// Grouped by project (host|path), projects ordered by recency, each collapsible.
    /// Host prefix shown on the header only when more than one machine is present.
    private func buildProjectRows() -> [DrawerRow] {
        let byHost = Dictionary(grouping: visible, by: { $0.host })
        let multiHost = byHost.count > 1
        let byProject = Dictionary(grouping: visible, by: { $0.host + "\u{1}" + $0.path })
        let keys = byProject.keys.sorted {
            recency(byProject[$0] ?? []) > recency(byProject[$1] ?? [])
        }
        var out: [DrawerRow] = []
        for key in keys {
            let group = (byProject[key] ?? []).sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            guard let first = group.first else { continue }
            out.append(.projectHeader(key: key, label: projectLabel(first.path),
                                      host: multiHost ? first.host : nil, count: group.count))
            if !collapsed.contains(key) {
                out.append(contentsOf: group.map { .session($0) })
            }
        }
        return out
    }

    private func bucketLabel(_ d: Date?) -> String {
        guard let d else { return "Earlier" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let wk = cal.date(byAdding: .day, value: -7, to: Date()), d > wk { return "This week" }
        return "Earlier"
    }

    private func projectLabel(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? (trimmed.isEmpty ? "—" : trimmed)
    }
    private func recency(_ sessions: [Session]) -> Date {
        sessions.compactMap { $0.lastActivity }.max() ?? .distantPast
    }
    private func sessionOrder(_ a: Session, _ b: Session) -> Bool {
        if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
        return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
    }
    private func rank(_ s: SessionStatus) -> Int {
        switch s { case .needs: return 0; case .running: return 1; case .idle: return 2; case .done: return 3 }
    }
}

private enum DrawerRow: Identifiable {
    case bucket(String)                                              // time-bucket header
    case projectHeader(key: String, label: String, host: String?, count: Int)
    case session(Session)

    var id: String {
        switch self {
        case let .bucket(label): return "b:" + label
        case let .projectHeader(key, _, _, _): return "p:" + key
        case let .session(s): return "s:" + s.id
        }
    }
}

// MARK: - Channel row (# session)

/// Card-style session row (reference: mobile chat launchers): agent tile on the
/// left, title + relative time, then a status line — live "working · 1:24" in
/// brand orange while mid-turn, else host · project · model. The last-opened
/// session keeps a blurple ring so you can jump back in one glance.
private struct ChannelRow: View {
    @Environment(\.theme) private var theme
    let session: Session
    var live: RelayClient.AgentStateInfo? = nil   // hook truth for this cwd (multi-Mac merged)
    var isLastOpened = false

    private var busy: Bool { ["thinking", "tool", "compacting"].contains(live?.state ?? "") }
    private var needsPerm: Bool { live?.state == "needsPermission" }
    private var unread: Bool { session.status == .needs || busy || needsPerm }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            AgentTile(kind: session.agent, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(AppFont.sans(14.5, unread ? .bold : .semibold))
                        .foregroundStyle(unread || isLastOpened ? theme.white : theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if busy {
                        MiniWorkingDots()
                    } else if needsPerm {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.gold)
                    } else if session.status == .needs {
                        Text("1")
                            .font(AppFont.sans(10.5, .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 17, minHeight: 17)
                            .padding(.horizontal, 4)
                            .background(theme.red, in: Capsule())
                    } else {
                        Text(TimeFormat.relative(session.lastActivity))
                            .font(AppFont.mono(10))
                            .foregroundStyle(theme.faint)
                    }
                }
                statusLine
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(theme.codebg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isLastOpened ? theme.blurple : theme.border.opacity(0.7),
                        lineWidth: isLastOpened ? 1.5 : 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 5) {
            if busy {
                Text(workingLabel)
                    .font(AppFont.mono(10.5))
                    .foregroundStyle(theme.claude)
            } else if session.isRemote && session.canDrive {
                Circle().fill(theme.greenText).frame(width: 6, height: 6)
                Text("Connected")
                    .font(AppFont.sans(11, .semibold))
                    .foregroundStyle(theme.greenText)
            } else if session.isRemote && session.cwdLive && !session.agentAlive {
                // Pane is open but the agent EXITED (bare shell) — distinct from
                // both Connected and Preview so it's obvious why send is off.
                Image(systemName: "terminal")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.faint)
                Text("Shell")
                    .font(AppFont.sans(11))
                    .foregroundStyle(theme.faint)
            } else if session.isRemote {
                Image(systemName: session.isSupersededPreview ? "clock.arrow.circlepath" : "eye")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.faint)
                Text(session.isSupersededPreview ? "Past session" : "Preview")
                    .font(AppFont.sans(11))
                    .foregroundStyle(theme.faint)
            }
            Text(metaTrail)
                .font(AppFont.mono(10))
                .foregroundStyle(theme.faint)
                .lineLimit(1)
        }
    }

    private var workingLabel: String {
        guard let since = live?.since else { return "working…" }
        let s = max(0, Int(Date().timeIntervalSince(since)))
        return String(format: "working · %d:%02d", s / 60, s % 60)
    }

    private var metaTrail: String {
        var parts: [String] = []
        let proj = session.path.split(separator: "/").last.map(String.init) ?? ""
        if !session.host.isEmpty && session.host != "remote" { parts.append("\(session.host)/\(proj)") }
        else if !proj.isEmpty { parts.append(proj) }
        if let m = shortModel(session.model) { parts.append(m) }
        if let b = session.gitBranch, !b.isEmpty { parts.append(b) }
        return (parts.isEmpty ? "" : "· ") + parts.joined(separator: " · ")
    }
}

/// Tiny three-dot wave in the agent brand color — the in-list "task running" pulse.
private struct MiniWorkingDots: View {
    @Environment(\.theme) private var theme
    @State private var on = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(theme.claude)
                    .frame(width: 4.5, height: 4.5)
                    .offset(y: on ? -2.5 : 1.5)
                    .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.13), value: on)
            }
        }
        .padding(.trailing, 1)
        .onAppear { on = true }
    }
}

/// Slow opacity breathe for skeleton placeholders.
private struct Shimmer: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// Condense a model id for the row subline: "claude-sonnet-4-5-20250…" → "Sonnet 4.5".
private func shortModel(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let low = raw.lowercased()
    let family = low.contains("opus") ? "Opus" : low.contains("sonnet") ? "Sonnet" : low.contains("haiku") ? "Haiku" : nil
    if let family {
        if let r = low.range(of: #"(\d+)[-.](\d+)"#, options: .regularExpression) {
            return "\(family) \(low[r].replacingOccurrences(of: "-", with: "."))"
        }
        return family
    }
    if low.hasPrefix("gpt") {
        if let r = low.range(of: #"\d+([.-]\d+)?"#, options: .regularExpression) {
            return "GPT-" + low[r].replacingOccurrences(of: "-", with: ".")
        }
        return "GPT"
    }
    return raw.count > 18 ? String(raw.prefix(18)) + "…" : raw
}

// MARK: - Bits

private struct PulseDot: View {
    let color: Color
    var size: CGFloat = 7
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(on ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Rail / picker tile for an agent. Codex ships a full-color mark (with its own
/// background), so it's used as the whole tile; the others are a brand-color rounded
/// square + a glyph.
struct AgentTile: View {
    let kind: AgentKind
    var size: CGFloat = 48
    var body: some View {
        let radius = size / 3
        if kind == .codex {
            Image("CodexMark")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else if kind == .claude {
            // Official Claude spark on its brand terracotta — the real logo asset.
            Image("ClaudeMark")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(kind.tile)
                .frame(width: size, height: size)
                .overlay { AgentGlyph(kind: kind, size: size * 0.5) }
                .overlay {
                    if kind.lightTile {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    }
                }
        }
    }
}

/// Per-agent rail glyph. Claude is the 8-line asterisk from the design; the others
/// approximate the design's marks until P2 brings real per-agent sessions.
struct AgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 24

    var body: some View {
        let stroke = kind.lightTile ? Color(hex: 0x15110D) : Color.white
        switch kind {
        case .claude:
            AsteriskMark(color: stroke, line: max(1.7, size * 0.085))
                .frame(width: size, height: size)
        case .til:
            Text("T").font(.system(size: size * 0.92, weight: .heavy, design: .rounded)).foregroundStyle(stroke)
        case .codex:
            Image(systemName: "hexagon").font(.system(size: size, weight: .semibold)).foregroundStyle(stroke)
        case .cursor:
            Image(systemName: "triangle.fill").font(.system(size: size * 0.8)).foregroundStyle(stroke)
        case .gemini:
            Image(systemName: "sparkles").font(.system(size: size * 0.92)).foregroundStyle(stroke)
        }
    }
}

private struct AsteriskMark: View {
    let color: Color
    var line: CGFloat = 2
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                p.move(to: CGPoint(x: w * 0.5, y: h * 0.08)); p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.92))
                p.move(to: CGPoint(x: w * 0.08, y: h * 0.5)); p.addLine(to: CGPoint(x: w * 0.92, y: h * 0.5))
                p.move(to: CGPoint(x: w * 0.2, y: h * 0.2)); p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.8))
                p.move(to: CGPoint(x: w * 0.8, y: h * 0.2)); p.addLine(to: CGPoint(x: w * 0.2, y: h * 0.8))
            }
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
        }
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = 14
    var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
