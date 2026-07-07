import SwiftUI

enum SessionStatus {
    case running, idle, done, needs

    var presence: SessionPresence {
        switch self {
        case .running: return .green
        case .idle: return .faint
        case .done, .needs: return .none
        }
    }
}

enum SessionPresence { case green, faint, none }

struct Session: Identifiable, Hashable {
    static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: String
    let name: String
    let path: String          // display path (tilde-shortened cwd)
    let host: String
    let gitBranch: String?
    let lastActivity: Date?
    let snippet: String
    let status: SessionStatus
    /// Source transcript on disk — the thread is parsed lazily from here (and
    /// live-tailed when reading this machine's real `~/.claude/projects`); the
    /// list only reads cheap metadata, never the full timeline.
    var fileURL: URL?
    var isLive: Bool = false
    /// True when this session comes from the relay (Mac agent) rather than a
    /// local file — the thread is streamed over the network instead of tailed.
    var isRemote: Bool = false
    /// Which coding agent owns this session (Claude Code, TIL, …). Local sessions
    /// can't tell them apart (identical transcripts) so default to Claude; remote
    /// sessions carry the agent host's spawn-time tag.
    var agent: AgentKind = .claude
    /// Model id from the transcript (e.g. "claude-sonnet-4-5-…"), for the row subline.
    var model: String? = nil
    /// Whether the agent host can actually DRIVE this session (there's a live vibTTY
    /// pane hosting it). False for sessions started outside vibTTY or pure history —
    /// still readable, but the composer is disabled (preview-only). Default true so
    /// an older agent (no `canDrive` field) keeps its previous behavior.
    var canDrive: Bool = true
    /// The pane's agent process is actually running (vs. the pane sitting at a
    /// bare shell after the agent exited). Old vibTTY doesn't send it → true.
    var agentAlive: Bool = true
    /// Claude-side global defaults (settings.json) — preselect pickers.
    var defaultModel: String? = nil
    var defaultEffort: String? = nil

    /// The session's project dir HAS a live vibTTY pane, but this specific session
    /// isn't the one loaded in it (an older session in the same directory). Lets the
    /// composer explain "a newer session is active here" instead of "not open".
    var cwdLive: Bool = false

    /// Read-only (composer disabled): a local session, or a remote one with no live
    /// pane to inject into.
    var isPreview: Bool { !(isRemote && canDrive) }

    /// Preview because a *newer* session owns this project's live pane (vs. the
    /// project simply not being open in vibTTY at all).
    var isSupersededPreview: Bool { isPreview && isRemote && cwdLive }

    var initial: String { String(name.first ?? "?").uppercased() }

    /// Stable avatar color from the design palette.
    var avatarColor: Color {
        let palette: [UInt32] = [0x5865f2, 0x3ba55d, 0xe0a032, 0xeb459e, 0x9b59b6, 0xe08a66]
        let h = abs(id.hashValue)
        return Color(hex: palette[h % palette.count])
    }
}
