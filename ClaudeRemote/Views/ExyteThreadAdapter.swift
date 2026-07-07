import SwiftUI
import Combine
import ExyteChat

/// Bridges ThreadModel's timeline to exyte/Chat with a hard split between
/// MEMBERSHIP and CONTENT:
///
/// - `messages` (+ `rev`) change only when rows are added/removed — the ONLY thing
///   the UITableView is asked to animate. Content-only reparse ticks don't touch
///   the table at all (row reloads mid-stream caused visible text ghosting as the
///   old and new cell overlapped during the height change).
/// - `itemsById` is @Published: each visible `MessageCell` observes the adapter and
///   redraws its OWN content in place; UIHostingConfiguration self-sizes the cell.
///   Streaming growth therefore renders like SwiftUI, not like table reloads.
/// - O(1) row lookup for the message builder (was O(n) per cell).
@MainActor
final class ExyteThreadAdapter: ObservableObject {
    @Published private(set) var messages: [ExyteChat.Message] = []
    private static let epoch = Date(timeIntervalSince1970: 1_600_000_000)
    private var assignedAt: [String: TimeInterval] = [:]
    private var minAssigned: TimeInterval = 0
    private var maxAssigned: TimeInterval = 0
    @Published private(set) var rev = 0
    /// Row content by id — @Published so on-screen cells re-render in place.
    @Published private(set) var itemsById: [String: TimelineItem] = [:]
    /// Snapshot of the optimistic echo text (read by its cell — self-contained so
    /// the cell never renders empty while the row removal is still in flight).
    private(set) var optimisticText: String?
    /// The id appended at the TAIL by the latest membership change (+ when) — lets
    /// only the newest cell pop in with a spring; history load & cell reuse stay inert.
    private(set) var lastAppendedId: String?
    private(set) var lastAppendAt = Date.distantPast
    private var didInitialLoad = false
    /// Exact-height pipeline (P1): rows measured off-screen before the list
    /// sees them. Configured by the pane with theme+agent for twin parity.
    let oracle = HeightOracle()
    private var twinTheme: Theme?
    private var twinAgent: AgentKind = .claude

    func configureTwin(theme: Theme, agent: AgentKind) {
        twinTheme = theme
        twinAgent = agent
    }

    private let meUser: ExyteChat.User
    private let agentUser: ExyteChat.User
    private let systemUser: ExyteChat.User

    private var lastIds: [String] = []
    private var bag = Set<AnyCancellable>()

    init(model: ThreadModel, session: Session) {
        meUser = .init(id: "me", name: "You", avatarURL: nil, isCurrentUser: true)
        agentUser = .init(id: "agent", name: session.agent.short, avatarURL: nil, isCurrentUser: false)
        systemUser = .init(id: "system", name: "System", avatarURL: nil, type: .system)
        model.$items
            .combineLatest(model.$optimisticUser)
            .sink { [weak self] items, optimistic in
                self?.rebuild(items, optimistic: optimistic)
            }
            .store(in: &bag)
    }

    private func user(for item: TimelineItem) -> ExyteChat.User {
        switch item {
        case .user: return meUser
        case .assistant: return agentUser
        case .system, .dateDivider: return systemUser
        }
    }

    private func rebuild(_ items: [TimelineItem], optimistic: String?) {
        let spid = Perf.begin("adapterRebuild")
        var dict = [String: TimelineItem](minimumCapacity: items.count)
        var ids: [String] = []
        ids.reserveCapacity(items.count + 1)
        // Streaming mutates the TAIL rows' content under their cached heights —
        // drop the last few so they re-measure (or self-size) with fresh content.
        for tail in items.suffix(4) { oracle.invalidate(id: tail.id) }
        if let theme = twinTheme {
            let width = UIScreen.main.bounds.width
            for item in items {
                oracle.measure(id: item.id, width: width) {
                    TimelineItemView(item: item, agent: twinAgent)
                        .environment(\.theme, theme)
                }
            }
        }
        for item in items {
            dict[item.id] = item
            ids.append(item.id)
        }
        optimisticText = optimistic
        itemsById = dict   // content channel: on-screen cells observe + redraw in place

        if let opt = optimistic, !opt.isEmpty { ids.append("cr-optimistic") }

        // Membership channel: touch `messages`/`rev` (→ table diff) only when rows
        // were actually added or removed.
        guard ids != lastIds else {
            Perf.end("adapterRebuild", spid, "content n=\(items.count)")
            return
        }
        // Tail-append detection for the pop-in: exactly one new id at the end,
        // after the initial load (a freshly opened thread must NOT ripple).
        if didInitialLoad, ids.count == lastIds.count + 1, ids.dropLast().elementsEqual(lastIds) {
            lastAppendedId = ids.last
            lastAppendAt = Date()
        }
        didInitialLoad = true
        lastIds = ids

        // createdAt orders exyte's list (real record times are unreliable), but
        // it must be STABLE per id: synthesizing from display index meant any
        // prepend shifted every row's index → createdAt → exyte saw "every row
        // changed" and re-rendered the whole table. Assign each id a time ONCE
        // and reuse it forever; history ids grow downward from the earliest,
        // new ids upward from the latest — either side grows with ZERO churn
        // to already-rendered rows.
        var out: [ExyteChat.Message] = []
        out.reserveCapacity(items.count + 1)
        let firstSeenIdx = items.firstIndex { assignedAt[$0.id] != nil }
        for (i, item) in items.enumerated() {
            let t: TimeInterval
            if let cached = assignedAt[item.id] {
                t = cached
            } else if let f = firstSeenIdx, i < f {
                t = minAssigned - Double(f - i)          // prepended history
            } else {
                maxAssigned += 1; t = maxAssigned        // appended (or first load)
            }
            assignedAt[item.id] = t
            minAssigned = min(minAssigned, t)
            out.append(ExyteChat.Message(id: item.id, user: user(for: item),
                                         createdAt: Self.epoch.addingTimeInterval(t)))
        }
        if let opt = optimistic, !opt.isEmpty {
            // Always strictly newest — never cached, so appends can't pass it.
            out.append(ExyteChat.Message(id: "cr-optimistic", user: meUser,
                                         createdAt: Self.epoch.addingTimeInterval(maxAssigned + 1)))
        }
        // Belt-and-braces: exyte hard-crashes on duplicate message ids
        // (WrappingMessages fatalError). Stable per-record ids should make
        // duplicates impossible; if a race still produces one, keep the
        // LAST occurrence instead of killing the app.
        var seen = Set<String>()
        var deduped: [ExyteChat.Message] = []
        for m in out.reversed() where seen.insert(m.id).inserted { deduped.append(m) }
        if deduped.count != out.count {
            Perf.event("adapter", "DEDUPED \(out.count - deduped.count) duplicate ids")
        }
        messages = deduped.reversed()
        rev += 1
        Perf.end("adapterRebuild", spid, "rows n=\(out.count)")
    }
}
