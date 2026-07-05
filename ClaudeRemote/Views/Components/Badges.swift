import SwiftUI

/// The blue "AGENT" tag next to Claude Code's name.
struct AppBadge: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .black))
            Text("AGENT")
        }
        .font(AppFont.sans(9.5, .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(theme.blurple, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A small orange (Claude-coral) chip for the model name / thinking marker.
struct OrangeTag: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text)
            .font(AppFont.mono(9, .medium))
            .tracking(0.3)
            .foregroundStyle(theme.claude)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(theme.claude.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A slash-command rendered as a colored block — used in the timeline and the
/// composer so `/commands` read the same in both places.
struct CommandChip: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text.hasPrefix("/") ? text : "/\(text)")
            .font(AppFont.mono(12, .medium))
            .foregroundStyle(theme.blurple)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.blurple.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// A small pill, e.g. "EXIT 0" on the terminal embed.
struct TagPill: View {
    let text: String
    var fg: Color
    var bg: Color
    var body: some View {
        Text(text)
            .font(AppFont.mono(9, .medium))
            .tracking(0.4)
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Presence/status dot bottom-right of a session avatar.
struct PresenceDot: View {
    @Environment(\.theme) private var theme
    let presence: SessionPresence
    var ring: Color

    var body: some View {
        Group {
            switch presence {
            case .green:
                dot(theme.greenText)
            case .faint:
                dot(theme.faint)
            case .none:
                EmptyView()
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(ring, lineWidth: 3))
    }
}
