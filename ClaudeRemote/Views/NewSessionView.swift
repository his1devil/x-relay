import SwiftUI

struct NewSessionView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var relay: RelayHub   // spawns route to the Mac owning the chosen cwd

    @State private var selectedPath: String?
    @State private var agent: AgentKind = .claude
    @State private var prompt = ""

    private var projects: [(name: String, path: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        let source = relay.anyEnabled ? relay.sessions : store.sessions
        for s in source where !s.path.isEmpty {
            if seen.insert(s.path).inserted { out.append((projectLabel(s.path), s.path)) }
        }
        return out
    }

    private func projectLabel(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    projectSection
                    agentSection
                    instructionSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
            startButton
        }
        .background(theme.screen.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("New session")
                .font(AppFont.sans(20, .bold))
                .foregroundStyle(theme.white)
            Spacer()
            Button("Cancel") { dismiss() }
                .font(AppFont.sans(14, .semibold))
                .foregroundStyle(theme.sub)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Project")
            VStack(spacing: 8) {
                ForEach(Array(projects.prefix(6)), id: \.path) { project in
                    Button { selectedPath = project.path } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "number")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.faint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                    .font(AppFont.sans(14, .semibold))
                                    .foregroundStyle(theme.ink)
                                Text(project.path)
                                    .font(AppFont.mono(11))
                                    .foregroundStyle(theme.faint)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            tick(selected: selectedPath == project.path)
                        }
                        .padding(11)
                        .background(theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                            selectedPath == project.path ? theme.blurple : theme.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Agent")
            HStack(spacing: 8) {
                agentPill(.claude)
                agentPill(.codex)
                agentPill(.til)
            }
        }
    }

    private func agentPill(_ kind: AgentKind) -> some View {
        let selected = agent == kind
        return Button { agent = kind } label: {
            HStack(spacing: 8) {
                AgentTile(kind: kind, size: 24)
                Text(kind.short)
                    .font(AppFont.sans(13.5, .semibold))
                    .foregroundStyle(selected ? .white : theme.sub)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(selected ? theme.blurple : theme.card)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.clear : theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("First instruction")
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("What should the agent work on? (optional)")
                        .font(AppFont.sans(14))
                        .foregroundStyle(theme.faint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 13)
                }
                TextEditor(text: $prompt)
                    .font(AppFont.sans(14))
                    .foregroundStyle(theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(height: 104)
            }
            .background(theme.input)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var startButton: some View {
        VStack(spacing: 6) {
            Button { start() } label: {
                Text("Start session")
                    .font(AppFont.sans(15, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.blurple, in: RoundedRectangle(cornerRadius: 8))
                    .opacity(canStart ? 1 : 0.4)
            }
            .disabled(!canStart)
            Text(footerHint)
                .font(AppFont.sans(10.5))
                .foregroundStyle(theme.faint)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func start() {
        guard let cwd = selectedPath, relay.anyEnabled else { return }
        relay.newSession(cwd: cwd, agent: agent, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }

    private var canStart: Bool { selectedPath != nil && relay.anyEnabled }

    private var footerHint: String {
        relay.anyEnabled
            ? "Spawns on the Mac owning that project as \(agent.displayName) — runs your first instruction if given."
            : "Connect a Mac first (settings → Pair a Mac → switch it on)."
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppFont.sans(11, .bold))
            .tracking(0.5)
            .foregroundStyle(theme.faint)
    }

    private func tick(selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? theme.blurple : Color.clear)
                .overlay(Circle().stroke(selected ? Color.clear : theme.border, lineWidth: 1))
                .frame(width: 22, height: 22)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

}
