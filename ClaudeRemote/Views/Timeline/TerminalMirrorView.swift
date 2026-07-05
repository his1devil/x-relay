import SwiftUI

/// Decodes the render-grid JSON frame vibTTY streams (same schema as the cmux
/// libghostty `render_grid_json`) and renders it as a colored monospace grid —
/// the real terminal screen of the hosted pane.
struct TerminalGrid: Decodable {
    struct Style: Decodable {
        let id: Int
        let foreground: String
        let background: String
        let bold, faint, italic, underline, blink, inverse, invisible, strikethrough, overline: Bool
    }
    struct Span: Decodable {
        let row: Int
        let column: Int
        let style_id: Int
        let cell_width: Int
        let text: String
    }
    /// Cursor block — best-effort (fields optional so a frame without it still decodes).
    struct Cursor: Decodable {
        let row: Int?
        let column: Int?
        let visible: Bool?
    }
    let styles: [Style]
    let row_spans: [Span]
    let rows: Int
    let cursor: Cursor?

    static func decode(_ frame: String) -> TerminalGrid? {
        guard let d = frame.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TerminalGrid.self, from: d)
    }

    /// One AttributedString per visible row, spans placed at their columns with
    /// truecolor fg/bg + attrs; gaps padded with spaces.
    func renderedRows() -> [AttributedString] {
        var styleByID: [Int: Style] = [:]
        for s in styles { styleByID[s.id] = s }
        var byRow: [Int: [Span]] = [:]
        for sp in row_spans { byRow[sp.row, default: []].append(sp) }
        let total = max(rows, (byRow.keys.max() ?? -1) + 1)
        guard total > 0 else { return [] }

        var out: [AttributedString] = []
        out.reserveCapacity(total)
        for r in 0 ..< total {
            var line = AttributedString("")
            var col = 0
            for sp in (byRow[r] ?? []).sorted(by: { $0.column < $1.column }) {
                if sp.column > col {
                    line.append(AttributedString(String(repeating: " ", count: sp.column - col)))
                }
                var seg = AttributedString(sp.text)
                if let st = styleByID[sp.style_id] {
                    let fgHex = st.inverse ? st.background : st.foreground
                    let bgHex = st.inverse ? st.foreground : st.background
                    if let fg = Color(termHex: fgHex) { seg.foregroundColor = st.faint ? fg.opacity(0.6) : fg }
                    if let bg = Color(termHex: bgHex) { seg.backgroundColor = bg }
                    if st.underline { seg.underlineStyle = .single }
                    if st.strikethrough { seg.strikethroughStyle = .single }
                    let f = Font.system(size: 12, weight: st.bold ? .bold : .regular, design: .monospaced)
                    seg.font = st.italic ? f.italic() : f
                }
                line.append(seg)
                col = sp.column + sp.cell_width
            }
            out.append(line)
        }
        return out
    }
}

extension Color {
    /// "#RRGGBB" → Color.
    init?(termHex: String) {
        guard termHex.hasPrefix("#"), termHex.count == 7,
              let v = Int(termHex.dropFirst(), radix: 16) else { return nil }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

/// Live terminal-mirror view: renders the streamed grid + an input row that sends
/// raw text / special keys back to the hosted pane. The screen half re-renders on
/// every streamed frame (~10/s while the pane is busy); the controls half is
/// Equatable-frozen so the TextField is untouched by that churn.
struct TerminalMirrorView: View {
    let frame: String?
    var onText: (String, Bool) -> Void          // (text, enter)
    var onKeys: ([String]) -> Void               // special keys: up/down/left/right/enter/esc/tab

    private var grid: TerminalGrid? { frame.flatMap(TerminalGrid.decode) }

    var body: some View {
        let g = grid
        VStack(spacing: 0) {
            TerminalScreen(grid: g, waiting: frame == nil)
            TerminalControls(onText: onText, onKeys: onKeys)
                .equatable()   // grid frames must NOT rebuild the input field
        }
        .background((g?.styles.first.flatMap { Color(termHex: $0.background) } ?? .black).ignoresSafeArea())
    }
}

private struct TerminalScreen: View {
    @Environment(\.theme) private var theme
    let grid: TerminalGrid?
    let waiting: Bool

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            if let rows = grid?.renderedRows(), !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(8)
            } else {
                VStack(spacing: 8) {
                    ProgressView().tint(theme.blurple)
                    Text(waiting ? "Waiting for terminal…" : "Decoding…")
                        .font(AppFont.mono(12)).foregroundStyle(theme.faint)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Key bar + input row. Equatable (always equal) so the parent's per-frame body
/// evals skip it entirely — the send-then-clear race with UITextField's binding
/// sync came from exactly that churn.
private struct TerminalControls: View, Equatable {
    @Environment(\.theme) private var theme
    var onText: (String, Bool) -> Void
    var onKeys: ([String]) -> Void

    @State private var input = ""
    @FocusState private var focused: Bool

    static func == (_: Self, _: Self) -> Bool { true }

    var body: some View {
        VStack(spacing: 0) {
            keyBar
            inputBar
        }
    }

    // Arrow keys / enter / esc / tab for menus + TUI navigation (e.g. trust prompts).
    private var keyBar: some View {
        HStack(spacing: 6) {
            ForEach([("esc", "escape"), ("tab", "arrow.right.to.line"),
                     ("↑", "chevron.up"), ("↓", "chevron.down"),
                     ("↵", "return")], id: \.0) { label, _ in
                Button(label) { onKeys([keyName(label)]) }
                    .font(AppFont.mono(13, .semibold))
                    .frame(minWidth: 38, minHeight: 30)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(theme.sub)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(theme.screen.opacity(0.9))
    }

    private func keyName(_ label: String) -> String {
        switch label {
        case "esc": return "esc"
        case "tab": return "tab"
        case "↑": return "up"
        case "↓": return "down"
        case "↵": return "enter"
        default: return label
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("type into terminal…", text: $input)
                .textFieldStyle(.plain)
                .font(AppFont.mono(13))
                .foregroundStyle(theme.ink)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(theme.codebg, in: Capsule())
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(input.isEmpty ? theme.faint : theme.blurple)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.screen)
    }

    private func send() {
        let t = input
        onText(t, true)  // send the line + Enter
        // Clear on the NEXT runloop turn — belt & braces against any in-flight
        // UITextField→binding sync writing the old text back.
        DispatchQueue.main.async { input = "" }
    }
}
