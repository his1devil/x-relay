import SwiftUI

/// Circular context-usage gauge for the composer: ring fills with the live
/// prompt-token footprint, the number is the percent. Pure shapes — updates only
/// when the percent value changes.
struct ContextRing: View {
    @Environment(\.theme) private var theme
    let percent: Int   // 0…99

    private var color: Color {
        switch percent {
        case ..<60: return theme.greenText
        case ..<85: return theme.gold
        default: return theme.red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.border.opacity(0.8), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.snap, value: percent)
            Text("\(percent)")
                .font(AppFont.mono(8.5, .semibold))
                .foregroundStyle(theme.sub)
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel("Context \(percent) percent")
    }
}

/// Single-purpose picker driven by Claude Code's own slash semantics (verified
/// against the real TUI):
///   · `.model`  → `/model <short>` — sets + saves as default
///   · `.effort` → `/effort <lvl>` — low/medium/high save as default, MAX is
///     session-only (CC's own wording)
struct ModelPickerSheet: View {
    enum Mode { case model, effort }

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let currentModelLabel: String
    let initialSelection: String?
    let onApply: (String) -> Void

    @State private var selection: String = ""

    struct Option: Identifiable {
        let arg: String
        let name: String
        let detail: String
        var id: String { arg }
    }

    static let models: [Option] = [
        .init(arg: "fable",  name: "Fable 5",   detail: "Deep reasoning · pairs with effort levels"),
        .init(arg: "opus",   name: "Opus 4.8",  detail: "Most capable generalist"),
        .init(arg: "sonnet", name: "Sonnet 5",  detail: "Fast, sharp default for coding"),
        .init(arg: "haiku",  name: "Haiku 4.5", detail: "Lightest + fastest, quick edits"),
    ]
    static let efforts: [Option] = [
        .init(arg: "low",    name: "Low",    detail: "Snappy answers, minimal deliberation"),
        .init(arg: "medium", name: "Medium", detail: "Balanced depth (Claude Code default)"),
        .init(arg: "high",   name: "High",   detail: "Comprehensive implementation & testing"),
        .init(arg: "max",    name: "Max",    detail: "Deepest reasoning — this session only"),
    ]

    private var options: [Option] { mode == .model ? Self.models : Self.efforts }
    private var title: String { mode == .model ? "Model" : "Reasoning effort" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 6) {
                        ForEach(options) { o in
                            optionRow(o)
                        }
                    }
                    if mode == .effort {
                        Text("Low · Medium · High save as your Claude Code default; Max applies to this session only.")
                            .font(AppFont.mono(10))
                            .foregroundStyle(theme.faint)
                            .padding(.top, 6)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(16)
            }
            .background(theme.screen)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(theme.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        Haptics.light()
                        onApply(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(selection.isEmpty ? theme.faint : theme.blurple)
                    .disabled(selection.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.screen)
        .onAppear { selection = initialSelection ?? "" }
    }

    private func optionRow(_ o: Option) -> some View {
        let selected = selection == o.arg
        let isCurrent = mode == .model
            && currentModelLabel.localizedCaseInsensitiveContains(o.name.split(separator: " ").first ?? "")
        return Button {
            Haptics.selection()
            withAnimation(Motion.snap) { selection = o.arg }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? theme.blurple : theme.faint)
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 7) {
                        Text(o.name)
                            .font(AppFont.sans(14.5, .semibold))
                            .foregroundStyle(theme.ink)
                        if isCurrent {
                            Text("CURRENT")
                                .font(AppFont.mono(8.5, .semibold))
                                .foregroundStyle(theme.greenText)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.greenText.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Text(o.detail)
                        .font(AppFont.sans(12))
                        .foregroundStyle(theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(selected ? theme.blurple.opacity(0.10) : theme.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? theme.blurple.opacity(0.55) : theme.border.opacity(0.6), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}
