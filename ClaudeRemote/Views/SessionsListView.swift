import SwiftUI

struct SessionsListView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var themeController: ThemeController
    @EnvironmentObject private var relay: RelayClient
    @State private var sheet: ActiveSheet?
    @State private var showLock = false

    private enum ActiveSheet: Int, Identifiable {
        case new, pairing
        var id: Int { rawValue }
    }

    private var displayed: [Session] {
        relay.paired ? relay.sessions : store.sessions
    }

    private var stateTag: String {
        switch relay.state {
        case .online: return "on"
        case .connecting: return "..."
        case .offline: return "off"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            diagnostic
            searchBar
            content
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationBarHidden(true)
        .navigationDestination(for: Session.self) { ThreadView(session: $0, relay: relay) }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .new: NewSessionView()
                case .pairing: PairingView()
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

    private var header: some View {
        HStack(spacing: 8) {
            SignalLogoTile(size: 28)
            Text("HALX")
                .font(AppFont.sans(21, .bold))
                .foregroundStyle(theme.white)
                .tracking(1)
            statusPill
            Spacer()
            HStack(spacing: 18) {
                Button { sheet = .pairing } label: {
                    Image(systemName: relay.paired ? "antenna.radiowaves.left.and.right" : "link")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(relay.isOnline ? theme.greenText : theme.sub)
                }
                Button { sheet = .new } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.sub)
                }
                Button { themeController.toggle() } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Circle().fill(theme.blurple).frame(width: 30, height: 30)
                            .overlay(Image(systemName: themeController.mode == .dark ? "moon.fill" : "sun.max.fill")
                                .font(.system(size: 13)).foregroundStyle(.white))
                        Circle().fill(theme.greenText).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(theme.screen, lineWidth: 2.5))
                    }
                }
                .simultaneousGesture(LongPressGesture().onEnded { _ in showLock = true })
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var statusPill: some View {
        if relay.paired {
            switch relay.state {
            case .online: pill("REMOTE", theme.greenText, dot: true)
            case .connecting: pill("CONNECTING", theme.gold, dot: false)
            case .offline: pill("OFFLINE", theme.red, dot: false)
            }
        } else if store.isLive {
            pill("LIVE", theme.greenText, dot: true)
        }
    }

    private func pill(_ text: String, _ color: Color, dot: Bool) -> some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(AppFont.sans(9, .bold)).tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }

    // Temporary on-screen diagnostic: sessions / frames / data-frames / decrypt-fails
    // / last-msg-type / paired / state — to pinpoint where the remote list breaks.
    private var diagnostic: some View {
        Text("s\(relay.sessions.count)  f\(relay.dbgFrames)  d\(relay.dbgData)  x\(relay.dbgDecryptFail)  t:\(relay.dbgLastType)  \(relay.paired ? "P" : "-")\(stateTag)  e:\(relay.lastError.isEmpty ? "-" : relay.lastError)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.yellow)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(theme.faint)
            Text("Search sessions")
                .font(AppFont.sans(14))
                .foregroundStyle(theme.faint)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(theme.codebg, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        if displayed.isEmpty && (store.isLoading || relay.state == .connecting) {
            Spacer()
            ProgressView().tint(theme.blurple)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(SessionGrouping.groups(displayed)) { group in
                        Text("\(group.title) — \(group.sessions.count)")
                            .font(AppFont.sans(11, .bold))
                            .tracking(0.5)
                            .foregroundStyle(theme.faint)
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        ForEach(group.sessions) { session in
                            NavigationLink(value: session) { SessionRow(session: session) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                if relay.paired { relay.requestSessions() } else { store.refresh() }
            }
        }
    }
}

/// Buckets sessions by recency — Today / This Week / Last Week / This Month /
/// then per earlier month — for the grouped DM list.
enum SessionGrouping {
    struct Group: Identifiable { let id: String; let title: String; let sessions: [Session] }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    static func groups(_ sessions: [Session], now: Date = Date()) -> [Group] {
        var cal = Calendar.current
        cal.firstWeekday = 2  // Monday — so "this week" matches the expected Mon–Sun
        let sorted = sessions.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        var order: [String] = []
        var map: [String: [Session]] = [:]
        var titles: [String: String] = [:]

        for s in sorted {
            let (key, title) = bucket(s.lastActivity, cal: cal, now: now)
            if map[key] == nil { order.append(key); titles[key] = title }
            map[key, default: []].append(s)
        }
        return order.map { Group(id: $0, title: titles[$0] ?? "", sessions: map[$0] ?? []) }
    }

    private static func bucket(_ date: Date?, cal: Calendar, now: Date) -> (String, String) {
        guard let date else { return ("none", "NO ACTIVITY") }
        if cal.isDateInToday(date) { return ("today", "TODAY") }
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return ("thisweek", "THIS WEEK") }
        if let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: now),
           cal.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) { return ("lastweek", "LAST WEEK") }
        if cal.isDate(date, equalTo: now, toGranularity: .month) { return ("thismonth", "THIS MONTH") }
        let label = monthFormatter.string(from: date).uppercased()
        return ("m-\(label)", label)
    }
}

private struct SessionRow: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                InitialAvatar(text: session.initial, color: session.avatarColor, size: 44)
                PresenceDot(presence: session.status.presence, ring: theme.screen)
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.name)
                        .font(AppFont.sans(15, .semibold))
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(TimeFormat.relative(session.lastActivity))
                        .font(AppFont.mono(10.5))
                        .foregroundStyle(theme.faint)
                }
                Text(session.snippet)
                    .font(AppFont.sans(12.5))
                    .foregroundStyle(snippetColor)
                    .lineLimit(1)
            }
            if session.status == .needs {
                Text("1")
                    .font(AppFont.sans(11, .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(theme.red, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var nameColor: Color {
        switch session.status {
        case .running, .needs: return theme.white
        case .idle, .done: return theme.muted
        }
    }

    private var snippetColor: Color {
        switch session.status {
        case .needs: return theme.sub
        case .running: return theme.muted
        case .idle, .done: return theme.faint
        }
    }
}
