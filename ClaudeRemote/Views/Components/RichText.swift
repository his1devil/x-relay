import SwiftUI

/// Block-aware markdown with SYNCHRONOUS layout (no async height measurement),
/// so scrolling a `LazyVStack` stays stable — MarkdownUI's async measuring made
/// the scroll land in empty space on layout changes (keyboard, live updates).
/// Handles paragraphs, headings, fenced code, ordered/unordered lists, quotes,
/// tables and rules; inline spans go through `MarkdownText`.
struct RichText: View {
    let text: String
    var color: Color
    var size: CGFloat = 14.5
    /// Hug content width instead of greedily filling the container — used inside
    /// the user bubble so short messages get a small bubble.
    var hugging: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(MarkdownCache.blocks(for: text)) { block in
                switch block.kind {
                case let .paragraph(s):
                    MarkdownText(text: s, color: color, size: size, hugging: hugging)
                        .lineSpacing(3.5)
                case let .heading(level, s):
                    MarkdownText(text: s, color: color, size: headingSize(level), weight: .bold)
                        .padding(.top, level <= 2 ? 5 : 3)
                case let .code(code):
                    CodeBlockView(code: code, size: size)
                case let .bullets(items):
                    BulletListView(items: items, color: color, size: size)
                case let .ordered(items):
                    OrderedListView(items: items, color: color, size: size)
                case let .quote(s):
                    QuoteView(text: s, size: size)
                case let .table(headers, rows):
                    TableView(headers: headers, rows: rows, size: size)
                case .rule:
                    RuleView()
                }
            }
        }
        .frame(maxWidth: hugging ? nil : .infinity, alignment: .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return size + 5
        case 2: return size + 3
        case 3: return size + 1.5
        default: return size + 0.5
        }
    }
}

/// Fenced code block: inline preview, taps open the full `CodeSheet` drawer.
private struct CodeBlockView: View {
    @Environment(\.theme) private var theme
    let code: String
    var size: CGFloat
    @State private var show = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(AppFont.mono(size - 2))
                .foregroundStyle(theme.sub)
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .padding(.vertical, 11)
                .padding(.horizontal, 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codebg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border.opacity(0.55), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.down.left.and.arrow.up.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.faint)
                .padding(6)
                .background(theme.codebg.opacity(0.85), in: Circle())
                .padding(5)
        }
        .contentShape(Rectangle())
        .onTapGesture { show = true }
        .sheet(isPresented: $show) {
            CodeSheet(text: code, color: theme.sub, title: "Code").environment(\.theme, theme)
        }
    }
}

private struct BulletListView: View {
    @Environment(\.theme) private var theme
    let items: [String]
    var color: Color
    var size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5.5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle().fill(theme.muted).frame(width: 4, height: 4).offset(y: -3)
                    MarkdownText(text: item, color: color, size: size)
                        .lineSpacing(3)
                }
            }
        }
        .padding(.leading, 2)
    }
}

private struct OrderedListView: View {
    @Environment(\.theme) private var theme
    let items: [String]
    var color: Color
    var size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5.5) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("\(idx + 1).")
                        .font(AppFont.mono(size - 1))
                        .foregroundStyle(theme.muted)
                        .frame(minWidth: 18, alignment: .trailing)
                    MarkdownText(text: item, color: color, size: size)
                        .lineSpacing(3)
                }
            }
        }
        .padding(.leading, 2)
    }
}

private struct QuoteView: View {
    @Environment(\.theme) private var theme
    let text: String
    var size: CGFloat

    var body: some View {
        MarkdownText(text: text, color: theme.muted, size: size)
            .padding(.leading, 11)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(theme.divider).frame(width: 3)
            }
    }
}

private struct RuleView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.divider).frame(height: 1).padding(.vertical, 2)
    }
}

/// Equal-width columns so columns line up across rows without a Grid.
private struct TableView: View {
    @Environment(\.theme) private var theme
    let headers: [String]
    let rows: [[String]]
    var size: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            row(headers, header: true)
            ForEach(rows.indices, id: \.self) { r in
                Rectangle().fill(theme.border).frame(height: 1)
                row(rows[r], header: false, zebra: r % 2 == 1)
            }
        }
        .background(theme.codebg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border, lineWidth: 1))
    }

    private func row(_ cells: [String], header: Bool, zebra: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(headers.indices, id: \.self) { c in
                Text(c < cells.count ? cells[c] : "")
                    .font(AppFont.sans(size - 1.5, header ? .semibold : .regular))
                    .foregroundStyle(header ? theme.white : theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 9)
            }
        }
        .background(header ? theme.card : (zebra ? theme.white.opacity(0.03) : Color.clear))
    }
}

// MARK: - parser

struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph(String)
        case heading(Int, String)
        case code(String)
        case bullets([String])
        case ordered([String])
        case quote(String)
        case table([String], [[String]])
        case rule
    }

    let id = UUID()
    let kind: Kind

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(MarkdownBlock(kind: .paragraph(paragraph.joined(separator: "\n")))); paragraph = [] }
        }
        func flushBullets() { if !bullets.isEmpty { blocks.append(MarkdownBlock(kind: .bullets(bullets))); bullets = [] } }
        func flushOrdered() { if !ordered.isEmpty { blocks.append(MarkdownBlock(kind: .ordered(ordered))); ordered = [] } }
        func flushLists() { flushBullets(); flushOrdered() }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph(); flushLists()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                blocks.append(MarkdownBlock(kind: .code(code.joined(separator: "\n"))))
                i += 1
                continue
            }

            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph(); flushLists()
                let headers = tableCells(line)
                i += 2
                var tableRows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    tableRows.append(tableCells(lines[i])); i += 1
                }
                blocks.append(MarkdownBlock(kind: .table(headers, tableRows)))
                continue
            }

            if isRule(trimmed) {
                flushParagraph(); flushLists()
                blocks.append(MarkdownBlock(kind: .rule)); i += 1; continue
            }

            if let h = headingLevel(trimmed) {
                flushParagraph(); flushLists()
                let content = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .heading(h, content))); i += 1; continue
            }

            if let item = orderedContent(line) {
                flushParagraph(); flushBullets(); ordered.append(item); i += 1; continue
            }
            if let item = bulletContent(line) {
                flushParagraph(); flushOrdered(); bullets.append(item); i += 1; continue
            }
            flushLists()

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .quote(String(trimmed.dropFirst(2))))); i += 1; continue
            }

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            paragraph.append(line); i += 1
        }
        flushParagraph(); flushLists()
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bulletContent(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where t.hasPrefix(marker) { return String(t.dropFirst(marker.count)) }
        return nil
    }

    private static func orderedContent(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let sep = t.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let prefix = t[t.startIndex..<sep]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber),
              t.index(after: sep) < t.endIndex, t[t.index(after: sep)] == " " else { return nil }
        return String(t[t.index(sep, offsetBy: 2)...])
    }

    private static func isRule(_ t: String) -> Bool {
        guard t.count >= 3 else { return false }
        return t.allSatisfy { $0 == "-" } || t.allSatisfy { $0 == "*" } || t.allSatisfy { $0 == "_" }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
