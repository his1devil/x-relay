import SwiftUI

/// Payload pushed onto the nav stack when an Edit embed is tapped → full DiffView.
struct DiffPayload: Hashable {
    struct Row: Hashable {
        let oldNo: Int?
        let newNo: Int?
        let sign: String
        let text: String
    }

    let id: String
    let fileName: String
    let dir: String?
    let addCount: Int
    let delCount: Int
    let rows: [Row]

    init(call: ToolCall) {
        id = call.id
        fileName = call.fileName ?? "file"
        dir = call.fileDir
        addCount = call.addCount
        delCount = call.delCount
        rows = call.diffRows().map { Row(oldNo: $0.oldNo, newNo: $0.newNo, sign: $0.sign, text: $0.code) }
    }
}

// MARK: - Tool embed dispatcher

struct ToolEmbedView: View {
    @Environment(\.theme) private var theme
    let call: ToolCall
    @State private var showDiff = false
    @State private var showReadSheet = false

    var body: some View {
        switch call.kind {
        case .bash: bashEmbed
        case .edit: editEmbed
        case .write: writeEmbed
        case .read: readEmbed
        case .search: searchEmbed
        case .todo, .task: todoEmbed
        case .question: questionEmbed
        case .agent: agentEmbed
        case .file: fileEmbed
        case .skill: skillEmbed
        case .schedule: scheduleEmbed
        case .mcp: mcpEmbed
        case .generic: genericEmbed
        }
    }

    // MARK: bash

    private var bashEmbed: some View {
        EmbedContainer(accent: theme.greenText) {
            EmbedHeader(icon: "terminal", title: "Terminal") {
                if let r = call.result {
                    TagPill(text: r.isError ? "ERROR" : "EXIT 0",
                            fg: r.isError ? theme.red : theme.greenText,
                            bg: (r.isError ? theme.red : theme.greenText).opacity(0.18))
                }
            }
            CodeBox {
                VStack(alignment: .leading, spacing: 2) {
                    if let cmd = call.bashCommand {
                        Text("$ \(cmd)")
                            .foregroundStyle(theme.faint)
                            .textSelection(.enabled)
                    }
                    let out = call.result?.stdout ?? ""
                    let err = call.result?.stderr ?? ""
                    if !out.isEmpty {
                        ExpandableMono(text: out, color: theme.sub)
                    }
                    if !err.isEmpty {
                        ExpandableMono(text: err, color: theme.delText)
                    }
                    if out.isEmpty, err.isEmpty, let t = call.result?.text, !t.isEmpty {
                        ExpandableMono(text: t, color: call.result?.isError == true ? theme.delText : theme.sub)
                    }
                }
            }
        }
    }

    // MARK: edit → diff

    private var editEmbed: some View {
        Button { showDiff = true } label: {
            EmbedContainer(accent: theme.claude) {
                EmbedHeader(icon: "pencil", title: call.title) {
                    Text("+\(call.addCount)").font(AppFont.mono(11)).foregroundStyle(theme.addText)
                    Text("−\(call.delCount)").font(AppFont.mono(11)).foregroundStyle(theme.delText)
                    Image(systemName: "arrow.down.left.and.arrow.up.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.faint)
                }
                CodeBox {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(call.diffRows(maxRows: 8).enumerated()), id: \.offset) { _, row in
                            Text("\(row.sign.isEmpty ? " " : row.sign) \(row.code)")
                                .foregroundStyle(row.sign == "+" ? theme.addText : row.sign == "-" ? theme.delText : theme.sub)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDiff) {
            DiffView(payload: DiffPayload(call: call))
                .environment(\.theme, theme)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.screen)
        }
    }

    // MARK: write

    private var writeEmbed: some View {
        EmbedContainer(accent: theme.claude) {
            EmbedHeader(icon: "doc.badge.plus", title: call.title) {
                if let dir = call.fileDir {
                    Text(dir).font(AppFont.mono(10.5)).foregroundStyle(theme.faint)
                }
            }
            if let content = call.input["content"]?.stringValue, !content.isEmpty {
                CodeBox { ExpandableMono(text: content, color: theme.sub, title: call.fileName ?? "File", collapsedLines: 8) }
            }
        }
    }

    // MARK: read

    private var readEmbed: some View {
        Button { if readHasContent { showReadSheet = true } } label: {
            EmbedContainer(accent: theme.blurple) {
                EmbedHeader(icon: "doc.text", title: call.title) {
                    if let imgs = call.result?.imageCount, imgs > 0 {
                        TagPill(text: imgs == 1 ? "IMAGE" : "\(imgs) IMAGES",
                                fg: theme.blurple, bg: theme.blurple.opacity(0.16))
                    }
                    if let n = lineCount(call.result?.text) {
                        Text("\(n) lines").font(AppFont.mono(10.5)).foregroundStyle(theme.faint)
                    }
                    if readHasContent {
                        Image(systemName: "arrow.down.left.and.arrow.up.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.faint)
                    }
                }
                if let dir = call.fileDir {
                    Text(dir).font(AppFont.mono(10.5)).foregroundStyle(theme.faint)
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showReadSheet) {
            CodeSheet(text: call.result?.text ?? "", color: theme.sub, title: call.fileName ?? "File")
                .environment(\.theme, theme)
        }
    }

    private var readHasContent: Bool {
        !(call.result?.text ?? "").isEmpty
    }

    // MARK: search

    private var searchEmbed: some View {
        EmbedContainer(accent: theme.muted) {
            EmbedHeader(icon: "magnifyingglass", title: call.name) {
                if let q = call.searchQuery {
                    Text(q).font(AppFont.mono(11)).foregroundStyle(theme.sub).lineLimit(1)
                }
            }
            if let r = call.result?.text, !r.isEmpty {
                CodeBox { ExpandableMono(text: r, color: theme.sub, title: "Search results", collapsedLines: 6) }
            }
        }
    }

    // MARK: todos / tasks

    private var todoEmbed: some View {
        EmbedContainer(accent: theme.blurple) {
            EmbedHeader(icon: "checklist", title: "To-dos") { EmptyView() }
            let todos = call.todos()
            if todos.isEmpty {
                Text(call.genericSummary).font(AppFont.sans(12.5)).foregroundStyle(theme.sub)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(for: todo.status))
                                .font(.system(size: 12))
                                .foregroundStyle(color(for: todo.status))
                            Text(todo.text)
                                .font(AppFont.sans(13))
                                .foregroundStyle(todo.status == "completed" ? theme.faint : theme.ink)
                                .strikethrough(todo.status == "completed", color: theme.faint)
                        }
                    }
                }
            }
        }
    }

    // MARK: question

    private var questionEmbed: some View {
        EmbedContainer(accent: theme.gold) {
            EmbedHeader(icon: "questionmark.circle", title: "Asked you a question") {
                if call.result != nil {
                    TagPill(text: "ANSWERED", fg: theme.greenText, bg: theme.greenText.opacity(0.16))
                }
            }
            let questions = call.questions()
            if questions.isEmpty {
                Text(call.genericSummary).font(AppFont.sans(13)).foregroundStyle(theme.sub)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(q.prompt)
                                .font(AppFont.sans(13.5, .semibold))
                                .foregroundStyle(theme.ink)
                            FlowChips(items: q.options, chosen: chosenAnswers)
                        }
                    }
                }
            }
        }
    }

    /// The answers live in the tool result as `"Q"="Label"` pairs — mark an option
    /// chosen when it appears quoted there (quote-wrapped match avoids substring
    /// false-positives between similar labels).
    private var chosenAnswers: Set<String> {
        guard let r = call.result?.text, !r.isEmpty else { return [] }
        var out: Set<String> = []
        for q in call.questions() {
            for opt in q.options where r.contains("\"\(opt)\"") {
                out.insert(opt)
            }
        }
        return out
    }

    // MARK: subagent (Agent/Task tool)

    private var agentEmbed: some View {
        EmbedContainer(accent: theme.blurple) {
            EmbedHeader(icon: "person.2.badge.gearshape", title: "Subagent") {
                if let t = call.agentType {
                    TagPill(text: t, fg: theme.blurple, bg: theme.blurple.opacity(0.16))
                }
                if call.result == nil {
                    TagPill(text: "RUNNING", fg: theme.gold, bg: theme.gold.opacity(0.16))
                }
            }
            if let d = call.agentDescription {
                Text(d).font(AppFont.sans(13, .medium)).foregroundStyle(theme.ink)
            }
            if let r = call.result?.text, !r.isEmpty {
                CodeBox { ExpandableMono(text: r, color: theme.sub, title: "Subagent result", collapsedLines: 6) }
            } else if let p = call.agentPrompt {
                Text(p.replacingOccurrences(of: "\n", with: " "))
                    .font(AppFont.sans(12)).foregroundStyle(theme.faint).lineLimit(2)
            }
        }
    }

    // MARK: files sent to the user

    private var fileEmbed: some View {
        EmbedContainer(accent: theme.greenText) {
            EmbedHeader(icon: "paperclip", title: "Sent you \(call.sentFiles.count == 1 ? "a file" : "\(call.sentFiles.count) files")") { EmptyView() }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(call.sentFiles, id: \.self) { f in
                    HStack(spacing: 7) {
                        Image(systemName: iconForFile(f))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.greenText)
                        Text((f as NSString).lastPathComponent)
                            .font(AppFont.mono(11.5))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.codebg, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            if let c = call.sentCaption, !c.isEmpty {
                Text(c).font(AppFont.sans(12.5)).foregroundStyle(theme.sub)
            }
        }
    }

    // MARK: skill

    private var skillEmbed: some View {
        EmbedContainer(accent: theme.gold) {
            EmbedHeader(icon: "sparkles", title: "Skill") {
                if let s = call.skillName {
                    TagPill(text: "/\(s)", fg: theme.gold, bg: theme.gold.opacity(0.16))
                }
            }
            if let a = call.skillArgs, !a.isEmpty {
                Text(a).font(AppFont.mono(11.5)).foregroundStyle(theme.sub).lineLimit(2)
            }
        }
    }

    // MARK: scheduled wakeup

    private var scheduleEmbed: some View {
        EmbedContainer(accent: theme.muted) {
            EmbedHeader(icon: "clock.badge", title: "Scheduled a check-in") {
                if let d = call.scheduleDelay {
                    Text(d >= 90 ? "in \(d / 60) min" : "in \(d)s")
                        .font(AppFont.mono(10.5)).foregroundStyle(theme.faint)
                }
            }
            if let r = call.scheduleReason {
                Text(r).font(AppFont.sans(12.5)).foregroundStyle(theme.sub)
            }
        }
    }

    // MARK: MCP call

    private var mcpEmbed: some View {
        EmbedContainer(accent: theme.claude) {
            EmbedHeader(icon: "server.rack", title: call.mcpParts?.tool ?? call.name) {
                if let server = call.mcpParts?.server {
                    TagPill(text: server, fg: theme.claude, bg: theme.claude.opacity(0.16))
                }
            }
            Text(call.genericSummary)
                .font(AppFont.mono(11.5))
                .foregroundStyle(theme.sub)
                .lineLimit(2)
            if let r = call.result?.text, !r.isEmpty {
                CodeBox { ExpandableMono(text: r, color: theme.sub, title: call.mcpParts?.tool ?? call.name, collapsedLines: 6) }
            }
        }
    }

    // MARK: generic

    private var genericEmbed: some View {
        EmbedContainer(accent: theme.muted) {
            EmbedHeader(icon: "wrench.and.screwdriver", title: call.name) { EmptyView() }
            Text(call.genericSummary)
                .font(AppFont.mono(11.5))
                .foregroundStyle(theme.sub)
                .lineLimit(2)
            if let r = call.result?.text, !r.isEmpty {
                CodeBox { ExpandableMono(text: r, color: theme.sub, title: call.name, collapsedLines: 6) }
            }
        }
    }

    // MARK: helpers

    private func lineCount(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        return s.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func iconForFile(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "txt": return "doc.text"
        case "html", "htm": return "globe"
        case "csv", "xlsx": return "tablecells"
        default: return "doc"
        }
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.lefthalf.filled"
        default: return "circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": return theme.greenText
        case "in_progress": return theme.gold
        default: return theme.faint
        }
    }
}

// MARK: - Embed building blocks

struct EmbedContainer<Content: View>: View {
    @Environment(\.theme) private var theme
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .clipShape(.rect(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 10, topTrailingRadius: 10))
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 3)
        }
    }
}

struct EmbedHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.muted)
            Text(title)
                .font(AppFont.sans(13, .semibold))
                .foregroundStyle(theme.white)
                .lineLimit(1)
            Spacer(minLength: 6)
            trailing
        }
    }
}

struct CodeBox<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(AppFont.mono(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .background(theme.codebg)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Answer options rendered as a vertical stack of selectable-looking cards.
/// Options in `chosen` render highlighted (the user's picked answer).
struct FlowChips: View {
    @Environment(\.theme) private var theme
    let items: [String]
    var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let picked = chosen.contains(item)
                HStack(spacing: 7) {
                    if picked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.greenText)
                    }
                    Text(item)
                        .font(AppFont.sans(12.5, picked ? .semibold : .medium))
                        .foregroundStyle(picked ? theme.ink : theme.sub)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(picked ? theme.greenText.opacity(0.10) : theme.codebg)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(picked ? theme.greenText.opacity(0.55) : theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Mono text that clamps to N lines; overflow opens the full content in a
/// bottom-sheet "drawer" so a long file/output never floods the thread.
struct ExpandableMono: View {
    @Environment(\.theme) private var theme
    let text: String
    var color: Color
    var title: String = "Output"
    var collapsedLines: Int = 10
    @State private var showSheet = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let overflow = lines.count > collapsedLines
        let preview = overflow ? lines.prefix(collapsedLines).joined(separator: "\n") : text

        VStack(alignment: .leading, spacing: 5) {
            Text(preview)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if overflow {
                Button { showSheet = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.left.and.arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("Show all \(lines.count) lines")
                    }
                    .font(AppFont.sans(11, .semibold))
                    .foregroundStyle(theme.blurple)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showSheet) {
            CodeSheet(text: text, color: color, title: title)
                .environment(\.theme, theme)
        }
    }
}

/// The drawer: full mono content, vertically + horizontally scrollable and
/// selectable, on the app's dark surface. Detents let it open half or full.
struct CodeSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let text: String
    var color: Color
    var title: String

    // Guard against pathological sizes — keep the sheet snappy.
    private var clipped: String {
        text.count > 200_000 ? String(text.prefix(200_000)) + "\n… (truncated)" : text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(AppFont.sans(14, .bold))
                    .foregroundStyle(theme.white)
                    .lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }

            ScrollView([.vertical, .horizontal]) {
                Text(clipped)
                    .font(AppFont.mono(12))
                    .foregroundStyle(color == theme.sub ? theme.ink : color)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.screen)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.screen)
    }
}
