import SwiftUI

/// "Claude is working…" — a breathing Claude spark, a shimmer sweeping the label,
/// and a live turn-elapsed readout (fed by vibTTY's hook clock). Shown from send
/// until the agent's Stop hook actually ends the turn.
struct WorkingIndicator: View {
    @Environment(\.theme) private var theme
    var label: String = "Claude"
    var startedAt: Date? = nil
    @State private var animating = false

    /// One quip per TURN: seeded by the turn's start time, so it stays stable
    /// while this turn runs and rolls a fresh one next turn.
    private static let quips = [
        "Still working on it… the bits are sweating.",
        "Working on it… tiny robots are arguing in the background.",
        "Almost there… convincing the electrons to cooperate.",
        "Crunching away… this one is being dramatic.",
        "Working on it… giving the hamsters more coffee.",
        "Trying my best… and bribing the servers with snacks.",
        "Working very hard on this. Like, suspiciously hard.",
        "Working overtime in the digital mines.",
        "Working hard… please admire the effort.",
    ]
    private var quip: String {
        let seed = Int((startedAt ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)
        return Self.quips[abs(seed) % Self.quips.count]
    }

    var body: some View {
        HStack(spacing: 9) {
            ClaudeAvatar(size: 17)
                .scaleEffect(animating ? 1.1 : 0.9)
                .shadow(color: theme.claude.opacity(animating ? 0.55 : 0.15), radius: animating ? 6 : 2)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: animating)
            shimmerLabel
            Spacer(minLength: 0)
            if let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.elapsed(from: startedAt, to: ctx.date))
                        .contentTransition(.numericText(countsDown: false))
                        .animation(Motion.snap, value: Self.elapsed(from: startedAt, to: ctx.date))
                        .font(AppFont.mono(11))
                        .monospacedDigit()
                        .foregroundStyle(theme.faint)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .onAppear { animating = true }
    }

    /// Muted label with a soft highlight sweeping across the glyphs: a WHITE copy
    /// of the text clipped by a moving gradient window. (Masking the gradient BY
    /// the text displaced the glyph mask with the offset — garbled double text.)
    private var shimmerLabel: some View {
        let text = Text(quip).font(AppFont.sans(13))
        return text
            .foregroundStyle(theme.muted)
            .overlay {
                text
                    .foregroundStyle(theme.white.opacity(0.95))
                    .mask {
                        LinearGradient(colors: [.clear, .white, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 52)
                            .offset(x: animating ? 150 : -150)
                    }
                    .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: animating)
                    .allowsHitTesting(false)
            }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The gold "Permission required" card — Claude is blocked on a mutating tool,
/// waiting for the phone to Allow/Deny (matches the design's approval embed).
struct PermissionCard: View {
    @Environment(\.theme) private var theme
    let req: PermissionRequest
    var onAllow: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.gold)
                Text("Permission required")
                    .font(AppFont.sans(13, .bold))
                    .foregroundStyle(theme.white)
            }

            Text(title)
                .font(AppFont.sans(13.5))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)

            if let preview = req.preview, !preview.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(preview.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : String(line))
                                .foregroundStyle(color(for: String(line)))
                        }
                    }
                    .font(AppFont.mono(11.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 170)
                .background(theme.codebg)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            HStack(spacing: 8) {
                Button(action: onAllow) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                        Text("Allow")
                    }
                    .font(AppFont.sans(13.5, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(theme.green, in: RoundedRectangle(cornerRadius: 5))
                }
                Button(action: onDeny) {
                    Text("Deny")
                        .font(AppFont.sans(13.5, .semibold))
                        .foregroundStyle(theme.btnSecondaryInk)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(theme.btnSecondary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .clipShape(.rect(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 8, topTrailingRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(theme.gold).frame(width: 4) }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var title: String {
        let file = req.path.map { ($0 as NSString).lastPathComponent }
        switch req.tool {
        case "Bash": return "Claude wants to run a command"
        case "Write": return "Claude wants to create \(file ?? "a file")"
        case "Edit", "MultiEdit": return "Claude wants to edit \(file ?? "a file")"
        case "NotebookEdit": return "Claude wants to edit \(file ?? "a notebook")"
        default: return "Claude wants to use \(req.tool)"
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return theme.addText }
        if line.hasPrefix("-") { return theme.delText }
        return theme.sub
    }
}

/// A thin top banner shown when the relay link is down / reconnecting.
struct ConnectionBanner: View {
    @Environment(\.theme) private var theme
    let connecting: Bool
    var error: String = ""
    var retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if connecting && error.isEmpty {
                ProgressView().controlSize(.mini).tint(.white)
            } else {
                Image(systemName: "wifi.slash").font(.system(size: 12, weight: .bold))
            }
            Text(text)
                .font(AppFont.sans(12, .semibold))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background((connecting && error.isEmpty ? theme.gold : theme.red).opacity(0.96))
        .contentShape(Rectangle())
        .onTapGesture { retry() }
    }

    private var text: String {
        if !error.isEmpty { return "\(error) · tap to retry" }
        return connecting ? "Reconnecting…" : "Offline — tap to retry"
    }
}

extension Notification.Name {
    /// Posted with userInfo["id"] to navigate to another session's thread.
    static let crJumpSession = Notification.Name("cr.jumpSession")
}

/// The one takeover/newer-session banner — identical treatment in both variants so
/// the pattern reads instantly: icon capsule, two-line copy, chevron affordance.
struct SessionJumpBanner: View {
    @Environment(\.theme) private var theme
    let hint: ThreadModel.JumpHint
    let ready: Bool          // target session present in the list yet?
    let onJump: () -> Void

    private var title: String {
        hint.reason == .redirected ? "Sent to a newer session" : "A newer session is active"
    }
    private var subtitle: String {
        ready ? "Tap to follow the conversation" : "Syncing session list…"
    }
    private var icon: String {
        hint.reason == .redirected ? "arrow.uturn.right" : "sparkles"
    }

    var body: some View {
        Button { if ready { onJump() } } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(theme.blurple.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.blurple)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(title)
                        .font(AppFont.sans(13, .semibold))
                        .foregroundStyle(theme.ink)
                    Text(subtitle)
                        .font(AppFont.mono(10.5))
                        .foregroundStyle(ready ? theme.blurple : theme.faint)
                }
                Spacer(minLength: 8)
                if ready {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.blurple, theme.blurple.opacity(0.18))
                } else {
                    ProgressView().controlSize(.mini).tint(theme.faint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(theme.blurple.opacity(0.45), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
