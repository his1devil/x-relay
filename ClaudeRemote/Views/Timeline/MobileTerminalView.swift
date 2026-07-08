import SwiftUI

/// Mobile-first terminal renderer over the SAME grid frames as the legacy
/// mirror (vibTTY unchanged). Differences that matter on a phone:
/// - ONE Canvas draw per frame (the legacy view rebuilt an AttributedString
///   Text per row ~10×/s — heavy screens janked)
/// - Fit-to-width type with pinch zoom + double-tap reset
/// - A proper key accessory bar (sticky Ctrl, repeatable arrows, paste)
/// - Long-press row selection → copy
struct MobileTerminalView: View {
    let frame: String?
    var onText: (String, Bool) -> Void
    var onKeys: ([String]) -> Void

    @Environment(\.theme) private var theme
    @State private var zoom: CGFloat = 1.0
    @State private var pinchBase: CGFloat = 1.0
    @State private var selectedRows: ClosedRange<Int>? = nil
    @State private var copied = false

    private var grid: TerminalGrid? { frame.flatMap(TerminalGrid.decode) }

    var body: some View {
        let g = grid
        VStack(spacing: 0) {
            GeometryReader { geo in
                if let g {
                    let cols = max(g.maxColumns, 20)
                    // READABLE-FIRST (Termius/Blink semantics): desktop panes
                    // run 200+ columns — fitting those to a phone squeezes
                    // type below legibility. Base is a readable 12pt unless
                    // the pane is narrow enough to genuinely fit; horizontal
                    // scroll covers the overflow, and double-tap toggles a
                    // fit-width overview. zoom is the user multiplier on top.
                    let fitWidthSize = (geo.size.width - 12) / CGFloat(cols) * 1.66
                    let baseSize = fitWidthSize >= 9 ? min(20, fitWidthSize) : 12
                    let fontSize = max(4, min(24, baseSize * zoom))
                    let cellW = ceil(fontSize * 0.602)
                    let cellH = ceil(fontSize * 1.28)
                    let contentW = CGFloat(cols) * cellW + 12
                    // Horizontal pans whenever content overflows — NOT only
                    // when zoomed (wide panes overflow at zoom 1 by design).
                    let axes: Axis.Set = contentW > geo.size.width + 1 ? [.vertical, .horizontal] : .vertical
                    ScrollView(axes) {
                        TerminalCanvas(grid: g, fontSize: fontSize, cellW: cellW, cellH: cellH,
                                       selection: selectedRows)
                            .frame(width: max(geo.size.width, contentW),
                                   height: CGFloat(g.totalRows) * cellH + 12)
                            .contentShape(Rectangle())
                            .gesture(
                                LongPressGesture(minimumDuration: 0.35)
                                    .sequenced(before: DragGesture(minimumDistance: 0))
                                    .onEnded { value in
                                        if case .second(true, let drag) = value {
                                            let startRow = Int(((drag?.startLocation.y ?? 0) - 6) / cellH)
                                            let endRow = Int(((drag?.location.y ?? drag?.startLocation.y ?? 0) - 6) / cellH)
                                            let lo = max(0, min(startRow, endRow))
                                            let hi = min(g.totalRows - 1, max(startRow, endRow))
                                            selectedRows = lo ... hi
                                            Haptics.selection()
                                        }
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    let fitWidthSize = (geo.size.width - 12) / CGFloat(cols) * 1.66
                                    let base: CGFloat = fitWidthSize >= 9 ? min(20, fitWidthSize) : 12
                                    let overviewZoom = max(0.2, fitWidthSize / base)
                                    zoom = abs(zoom - 1) < 0.05 ? overviewZoom : 1
                                    pinchBase = zoom
                                }
                            }
                            .onTapGesture { selectedRows = nil }
                    }
                    .defaultScrollAnchor(.bottomLeading)
                } else {
                    VStack(spacing: 8) {
                        ProgressView().tint(theme.blurple)
                        Text("Waiting for terminal…").font(AppFont.mono(12)).foregroundStyle(theme.faint)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { zoom = min(3, max(0.2, pinchBase * $0)) }
                    .onEnded { _ in pinchBase = zoom }
            )

            if let sel = selectedRows, let g {
                selectionBar(sel, grid: g)
            }
            MobileKeyBar(onText: onText, onKeys: onKeys)
                .equatable()
        }
        .background((g?.styles.first.flatMap { Color(termHex: $0.background) } ?? .black).ignoresSafeArea())
    }

    private func selectionBar(_ sel: ClosedRange<Int>, grid g: TerminalGrid) -> some View {
        HStack(spacing: 10) {
            Text("\(sel.count) 行").font(AppFont.mono(11)).foregroundStyle(.white.opacity(0.7))
            Button {
                UIPasteboard.general.string = g.plainText(rows: sel)
                copied = true
                Haptics.rigid()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false; selectedRows = nil }
            } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(AppFont.sans(12, .semibold))
            }
            .buttonStyle(.borderedProminent).controlSize(.mini).tint(theme.blurple)
            Spacer()
            Button { selectedRows = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.85))
    }
}

/// Single-pass Canvas: background runs first, then glyph runs, then cursor.
private struct TerminalCanvas: View {
    let grid: TerminalGrid
    let fontSize: CGFloat
    let cellW: CGFloat
    let cellH: CGFloat
    let selection: ClosedRange<Int>?

    var body: some View {
        Canvas { ctx, _ in
            var styleByID: [Int: TerminalGrid.Style] = [:]
            for s in grid.styles { styleByID[s.id] = s }
            let pad: CGFloat = 6
            for sp in grid.row_spans {
                let st = styleByID[sp.style_id]
                let x = pad + CGFloat(sp.column) * cellW
                let y = pad + CGFloat(sp.row) * cellH
                let fgHex = (st?.inverse == true) ? st?.background : st?.foreground
                let bgHex = (st?.inverse == true) ? st?.foreground : st?.background
                if let bgHex, let bg = Color(termHex: bgHex) {
                    ctx.fill(Path(CGRect(x: x, y: y, width: CGFloat(sp.text.count) * cellW, height: cellH)),
                             with: .color(bg))
                }
                var attr = AttributedString(sp.text)
                var font = Font.system(size: fontSize, weight: st?.bold == true ? .bold : .regular, design: .monospaced)
                if st?.italic == true { font = font.italic() }
                attr.font = font
                var fg = fgHex.flatMap { Color(termHex: $0) } ?? .white
                if st?.faint == true { fg = fg.opacity(0.6) }
                attr.foregroundColor = fg
                if st?.underline == true { attr.underlineStyle = .single }
                if st?.strikethrough == true { attr.strikethroughStyle = .single }
                ctx.draw(Text(attr), at: CGPoint(x: x, y: y), anchor: .topLeading)
            }
            if let cur = grid.cursor, cur.visible != false, let r = cur.row, let c = cur.column {
                let rect = CGRect(x: pad + CGFloat(c) * cellW, y: pad + CGFloat(r) * cellH,
                                  width: cellW, height: cellH)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.55)))
            }
            if let sel = selection {
                let rect = CGRect(x: 0, y: pad + CGFloat(sel.lowerBound) * cellH,
                                  width: 40000, height: CGFloat(sel.count) * cellH)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.14)))
            }
        }
    }
}

/// VVTerm-style key accessory: sticky Ctrl, repeatable arrows, Esc/Tab, paste,
/// plus the text input row (shared send pipeline with the legacy mirror).
private struct MobileKeyBar: View, Equatable {
    @Environment(\.theme) private var theme
    var onText: (String, Bool) -> Void
    var onKeys: ([String]) -> Void

    @State private var input = ""
    @State private var ctrlArmed = false
    @FocusState private var focused: Bool

    static func == (_: Self, _: Self) -> Bool { true }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc") { onKeys(["esc"]) }
                    key("tab") { onKeys(["tab"]) }
                    key("ctrl", active: ctrlArmed) { ctrlArmed.toggle(); Haptics.selection() }
                    RepeatKey(symbol: "arrow.up") { onKeys(["up"]) }
                    RepeatKey(symbol: "arrow.down") { onKeys(["down"]) }
                    RepeatKey(symbol: "arrow.left") { onKeys(["left"]) }
                    RepeatKey(symbol: "arrow.right") { onKeys(["right"]) }
                    key("^C") { onText("\u{03}", false) }
                    key("paste") {
                        if let s = UIPasteboard.general.string, !s.isEmpty { onText(s, false) }
                    }
                    key("⏎") { onKeys(["enter"]) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(.black.opacity(0.35))
            HStack(spacing: 8) {
                TextField("", text: $input, prompt: Text("输入命令…").foregroundColor(.white.opacity(0.35)))
                    .font(AppFont.mono(13))
                    .foregroundStyle(.white)
                    .tint(theme.blurple)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .onSubmit { send(enter: true) }
                Button { send(enter: true) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(input.isEmpty ? .white.opacity(0.25) : theme.blurple)
                }
                .buttonStyle(.plain)
                .disabled(input.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.5))
        }
    }

    private func send(enter: Bool) {
        var t = input
        guard !t.isEmpty || enter else { return }
        if ctrlArmed, t.count == 1, let c = t.uppercased().unicodeScalars.first,
           c.value >= 64, c.value < 96 {
            t = String(UnicodeScalar(c.value - 64)!)
            ctrlArmed = false
        }
        onText(t, enter)
        input = ""
    }

    private func key(_ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { action(); Haptics.selection() }) {
            Group {
                if label.hasPrefix("arrow") || label == "paste" {
                    Image(systemName: label == "paste" ? "doc.on.clipboard" : label)
                } else {
                    Text(label)
                }
            }
            .font(AppFont.mono(12, .medium))
            .foregroundStyle(active ? Color.black : .white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(active ? Color.white : .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Arrow key with press-and-hold auto-repeat (TUI navigation lifesaver).
private struct RepeatKey: View {
    let symbol: String
    let fire: () -> Void
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: symbol)
            .font(AppFont.mono(12, .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .onLongPressGesture(minimumDuration: 0.4, pressing: { pressing in
                if pressing {
                    fire(); Haptics.selection()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in fire() }
                } else {
                    timer?.invalidate(); timer = nil
                }
            }, perform: {})
    }
}

extension TerminalGrid {
    var maxColumns: Int {
        row_spans.map { $0.column + max($0.cell_width, $0.text.count) }.max() ?? 80
    }
    var totalRows: Int {
        max(rows, (row_spans.map(\.row).max() ?? -1) + 1)
    }
    func plainText(rows range: ClosedRange<Int>) -> String {
        var byRow: [Int: [Span]] = [:]
        for sp in row_spans where range.contains(sp.row) { byRow[sp.row, default: []].append(sp) }
        return range.map { r in
            var line = ""
            var col = 0
            for sp in (byRow[r] ?? []).sorted(by: { $0.column < $1.column }) {
                if sp.column > col { line += String(repeating: " ", count: sp.column - col) }
                line += sp.text
                col = sp.column + sp.cell_width
            }
            return line
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
