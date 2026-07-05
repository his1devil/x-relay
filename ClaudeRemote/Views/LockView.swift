import SwiftUI

/// The lock-screen mock from the design: a notification stack of session events.
/// In production these cards are real APNs pushes (Phase 3, with the relay); for
/// now it previews the treatment, fed by the live sessions. Reachable via a
/// long-press on the sessions-header avatar.
struct LockView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(Self.dateString)
                    .font(AppFont.sans(14, .medium))
                    .foregroundStyle(theme.muted)
                Text(Self.timeString)
                    .font(AppFont.sans(74, .bold))
                    .foregroundStyle(theme.white)
            }
            .padding(.top, 60)

            Spacer()

            VStack(spacing: 10) {
                ForEach(Array(store.sessions.prefix(2))) { session in
                    card(for: session)
                }
            }
            Button { dismiss() } label: {
                Text("swipe up to open")
                    .font(AppFont.mono(11))
                    .tracking(0.6)
                    .foregroundStyle(theme.faint)
                    .padding(.vertical, 16)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.screen.ignoresSafeArea())
        .gesture(DragGesture().onEnded { if $0.translation.height < -40 { dismiss() } })
    }

    private func card(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6).fill(theme.blurple)
                    .frame(width: 22, height: 22)
                    .overlay(Text("D").font(AppFont.mono(13, .bold)).foregroundStyle(.white))
                Text("CLAUDE · #\(session.name)")
                    .font(AppFont.sans(12, .semibold))
                    .tracking(0.3)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(TimeFormat.relative(session.lastActivity))
                    .font(AppFont.mono(11))
                    .foregroundStyle(theme.faint)
            }
            Text(session.status == .needs ? "Claude needs your approval" : session.snippet)
                .font(AppFont.sans(14.5, .semibold))
                .foregroundStyle(theme.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private static var timeString: String {
        let f = DateFormatter(); f.dateFormat = "H:mm"; return f.string(from: Date())
    }

    private static var dateString: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f.string(from: Date())
    }
}
