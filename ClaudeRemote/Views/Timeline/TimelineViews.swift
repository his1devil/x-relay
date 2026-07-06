import SwiftUI

/// Dispatches a timeline item to its view. Horizontal insets live here so every
/// row lines up on the 16pt channel gutter.
struct TimelineItemView: View {
    let item: TimelineItem

    var body: some View {
        switch item {
        case let .dateDivider(_, label):
            DateDividerView(label: label)
        case let .system(note):
            SystemNoteView(note: note)
        case let .user(message):
            UserMessageView(message: message)
        case let .assistant(group):
            AssistantGroupView(group: group)
        }
    }
}

// MARK: - Date divider

struct DateDividerView: View {
    @Environment(\.theme) private var theme
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.divider).frame(height: 1)
            Text(label)
                .font(AppFont.sans(11, .semibold))
                .foregroundStyle(theme.faint)
                .fixedSize()
            Rectangle().fill(theme.divider).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - System note (slash command / interrupt)

struct SystemNoteView: View {
    @Environment(\.theme) private var theme
    let note: SystemNote
    @State private var showSheet = false

    var body: some View {
        switch note.kind {
        case .compact:
            // A context boundary — render as a labeled divider, not a chat row.
            HStack(spacing: 10) {
                Rectangle().fill(theme.divider).frame(height: 1)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Compacted").font(AppFont.mono(10, .semibold)).tracking(0.5)
                }
                .foregroundStyle(theme.faint)
                .fixedSize()
                Rectangle().fill(theme.divider).frame(height: 1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

        case .summary, .continued:
            // Long generated text — one-line teaser chip, full text in a sheet.
            Button { showSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: note.kind == .summary ? "text.badge.checkmark" : "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.blurple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.kind == .summary ? "While you were away" : "Continued from previous session")
                            .font(AppFont.sans(12.5, .semibold))
                            .foregroundStyle(theme.sub)
                        Text(note.text.replacingOccurrences(of: "\n", with: " "))
                            .font(AppFont.sans(12))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.codebg, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.border.opacity(0.7), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .sheet(isPresented: $showSheet) {
                MarkdownSheet(title: note.kind == .summary ? "Away summary" : "Session recap",
                              markdown: note.text)
            }

        default:
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                if note.kind == .slashCommand {
                    Text("You used").font(AppFont.sans(13.5)).foregroundStyle(theme.muted)
                    CommandChip(text: note.text)
                    if let t = note.time {
                        Text(TimeFormat.clockShort(t)).font(AppFont.sans(11)).foregroundStyle(theme.faint)
                    }
                } else {
                    (textPrefix + timeText).font(AppFont.sans(13.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
    }

    private var icon: String {
        switch note.kind {
        case .slashCommand: return "arrow.triangle.2.circlepath"
        case .interrupted: return "xmark.circle"
        default: return "info.circle"
        }
    }

    private var iconColor: Color {
        note.kind == .interrupted ? theme.red : theme.faint
    }

    private var textPrefix: Text {
        switch note.kind {
        case .slashCommand: return Text("You used ").foregroundColor(theme.muted)
        default: return Text(note.text).foregroundColor(theme.muted)
        }
    }

    private var timeText: Text {
        guard let t = note.time else { return Text("") }
        return Text("  \(TimeFormat.clockShort(t))").font(AppFont.sans(11)).foregroundColor(theme.faint)
    }
}

/// Very long assistant messages render a preview (cut at a paragraph boundary)
/// with a fade + "Show full message" opening the whole thing in a sheet — keeps
/// the thread scannable and the row cheap to lay out.
struct CollapsedMarkdown: View {
    @Environment(\.theme) private var theme
    let text: String
    @State private var showSheet = false

    private var preview: String {
        let head = String(text.prefix(2600))
        // Prefer breaking at the last blank line so markdown blocks stay intact.
        if let cut = head.range(of: "\n\n", options: .backwards)?.lowerBound, head.distance(from: head.startIndex, to: cut) > 800 {
            return String(head[..<cut])
        }
        return head
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RichText(text: preview, color: theme.ink)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: 0.88),
                                           .init(color: .black.opacity(0.25), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            Button { showSheet = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Show full message · \(text.count / 1000)k chars")
                }
                .font(AppFont.sans(11.5, .semibold))
                .foregroundStyle(theme.blurple)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showSheet) {
            MarkdownSheet(title: "Full message", markdown: text)
        }
    }
}

/// Full-screen image viewer with pinch-zoom + drag, for user-sent photos.
struct ImageZoomSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .containerRelativeFrame([.horizontal])
                    .scaleEffect(scale)
            }
            .defaultScrollAnchor(.center)
            .gesture(
                MagnificationGesture()
                    .onChanged { v in scale = min(max(lastScale * v, 1), 5) }
                    .onEnded { _ in lastScale = scale }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { scale = scale > 1.5 ? 1 : 2.5; lastScale = scale }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.85), .black.opacity(0.5))
            }
            .padding(16)
        }
        .presentationDetents([.large])
        .presentationBackground(.black)
    }
}

/// Full-text viewer for long generated content (away summaries, session recaps)
/// — renders through the app's markdown pipeline inside a dismissable sheet.
struct MarkdownSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let title: String
    let markdown: String

    var body: some View {
        NavigationStack {
            ScrollView {
                RichText(text: markdown, color: theme.ink)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.screen)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(theme.blurple)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - User message

/// Lazily decodes + downscales transcript-embedded image bytes; keyed by content
/// hash so re-parses / cell reuse never re-decode the same photo.
enum UserImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func thumb(for data: Data) -> UIImage? {
        let key = "\(data.count)-\(data.prefix(64).hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = UIImage(data: data) else { return nil }
        let maxEdge: CGFloat = 700
        let m = max(img.size.width, img.size.height)
        let out: UIImage
        if m > maxEdge, m > 0 {
            let s = maxEdge / m
            let size = CGSize(width: img.size.width * s, height: img.size.height * s)
            out = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        } else {
            out = img
        }
        cache.setObject(out, forKey: key)
        return out
    }
}

struct UserMessageView: View {
    @Environment(\.theme) private var theme
    let message: UserMessage
    @State private var zoomed: IdentifiedImage?

    private struct IdentifiedImage: Identifiable { let id = UUID(); let image: UIImage }

    @ObservedObject private var profile = ProfileStore.shared

    var body: some View {
        // Discord/Claude-Code author layout: avatar + nickname + time (time to
        // the RIGHT of the name), then the message body beneath — the user's
        // identity shows on every message, never elided.
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                UserAvatar(size: 24)
                Text(profile.nickname)
                    .font(AppFont.sans(15, .bold))
                    .foregroundStyle(theme.white)
                    .fixedSize()
                Text(TimeFormat.messageStamp(message.time))
                    .font(AppFont.sans(11))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            bubble
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .sheet(item: $zoomed) { z in
            ImageZoomSheet(image: z.image)
                .environment(\.theme, theme)
        }
    }

    private var bubble: some View {
        let (body, attachments) = Self.splitAttachments(message.text)
        return VStack(alignment: .leading, spacing: 8) {
            if !message.images.isEmpty {
                imageGrid
            }
            if !body.isEmpty {
                RichText(text: body, color: theme.ink)
            }
            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(attachments, id: \.self) { p in
                        HStack(spacing: 7) {
                            Image(systemName: Self.isImagePath(p) ? "photo" : "paperclip")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.blurple)
                            Text((p as NSString).lastPathComponent)
                                .font(AppFont.mono(11.5))
                                .foregroundStyle(theme.sub)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(theme.codebg.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    /// Discord-style inline previews: one image → large rounded preview; several →
    /// two-up grid. Tap opens full-screen.
    private var imageGrid: some View {
        let thumbs = message.images.compactMap { UserImageCache.thumb(for: $0) }
        let single = thumbs.count == 1
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 6)] + (single ? [] : [GridItem(.flexible())]),
                         spacing: 6) {
            ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                Button { zoomed = IdentifiedImage(image: img) } label: {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: single ? 240 : 132, maxHeight: single ? 240 : 132)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: single ? 240 : 272)
    }

    /// Phone-sent attachments arrive as trailing absolute paths appended by the
    /// agent (space-joined on one line; older builds newline-joined). Pull them
    /// off the end and render chips instead of raw path text.
    static func splitAttachments(_ text: String) -> (body: String, paths: [String]) {
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var paths: [String] = []
        while let last = tokens.last,
              last.hasPrefix("/"), last.contains("."),
              (last.contains("/.vibtty/attach/") || isImagePath(last)) {
            paths.insert(last, at: 0)
            tokens.removeLast()
        }
        guard !paths.isEmpty else { return (text, []) }   // untouched when nothing matched
        // Rebuild the body from the original text by cutting the matched tail.
        var body = text
        for p in paths.reversed() {
            if let r = body.range(of: p, options: .backwards) {
                body = String(body[..<r.lowerBound])
            }
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    static func isImagePath(_ p: String) -> Bool {
        let ext = (p as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext)
    }
}

// MARK: - Claude message group

struct AssistantGroupView: View {
    @Environment(\.theme) private var theme
    let group: AssistantGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                ClaudeAvatar(size: 24)
                Text("Claude Code")
                    .font(AppFont.sans(15, .bold))
                    .foregroundStyle(theme.claude)
                    .fixedSize()
                AppBadge()
                if let model = group.model {
                    OrangeTag(text: Self.modelLabel(model))
                }
                if group.hasThinking {
                    OrangeTag(text: "thinking")
                }
                Spacer(minLength: 4)
                Text(TimeFormat.messageStamp(group.time))
                    .font(AppFont.sans(11))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .layoutPriority(-1)   // yield/truncate before the name+tags overflow
            }
            .padding(.bottom, 1)

            ForEach(Self.segments(group.blocks)) { seg in
                switch seg {
                case let .block(block):
                    switch block {
                    case let .text(_, text):
                        if text.count > 5000 {
                            CollapsedMarkdown(text: text)
                        } else {
                            RichText(text: text, color: theme.ink)
                        }
                    case let .thinking(_, text):
                        ThinkingBlockView(text: text)
                    case let .tool(call):
                        ToolEmbedView(call: call)   // interactive kinds stay inline
                    }
                case let .toolRun(calls):
                    ToolRunView(calls: calls)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Consecutive "mechanical" tool calls (bash/edit/read/…) fold into ONE
    /// tappable summary row, Claude-Code-iOS style; interactive/content embeds
    /// (questions, todos) always stay inline.
    enum Segment: Identifiable {
        case block(Block)
        case toolRun([ToolCall])
        var id: String {
            switch self {
            case let .block(b): return b.id
            case let .toolRun(calls): return "run-\(calls.first?.id ?? "?")"
            }
        }
    }

    static func segments(_ blocks: [Block]) -> [Segment] {
        var out: [Segment] = []
        var run: [ToolCall] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            out.append(.toolRun(run))
            run = []
        }
        for b in blocks {
            if case let .tool(c) = b, isCollapsible(c) {
                run.append(c)
            } else {
                flushRun()
                out.append(.block(b))
            }
        }
        flushRun()
        return out
    }

    private static func isCollapsible(_ c: ToolCall) -> Bool {
        switch c.kind {
        case .question, .todo, .task: return false   // interactive/stateful — keep visible
        default: return true
        }
    }

    /// "claude-opus-4-8" → "Opus 4.8" (drops the `claude-` prefix and any long
    /// date suffix, keeps the family + short version numbers).
    static func modelLabel(_ id: String) -> String {
        var s = id
        if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
        let parts = s.split(separator: "-").map(String.init)
        guard let family = parts.first else { return id }
        let nums = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) && $0.count < 4 }
        return nums.isEmpty ? family.capitalized : "\(family.capitalized) \(nums.joined(separator: "."))"
    }
}

// MARK: - Collapsed tool run (Claude-Code-iOS style summary row)

struct ToolRunView: View {
    @Environment(\.theme) private var theme
    let calls: [ToolCall]
    @State private var expanded = false

    private var running: Bool { calls.contains { $0.result == nil } }
    private var current: ToolCall? { calls.last { $0.result == nil } ?? calls.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.selection()
                withAnimation(Motion.snap) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if running {
                        ProgressView().controlSize(.mini).tint(theme.claude)
                        Text(current?.title ?? "Working…")
                            .font(AppFont.sans(14, .medium))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    } else {
                        Text(summary)
                            .font(AppFont.sans(14, .medium))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    }
                    if addTotal > 0 {
                        Text("+\(addTotal)").font(AppFont.mono(12.5)).foregroundStyle(theme.addText)
                    }
                    if delTotal > 0 {
                        Text("−\(delTotal)").font(AppFont.mono(12.5)).foregroundStyle(theme.delText)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.faint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calls) { call in
                        ToolEmbedView(call: call)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
    }

    /// "Ran 3 commands, edited 2 files, read a file" — verbs in first-appearance
    /// order, counted, mirroring the Claude Code iOS summary rows.
    private var summary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var editedFiles = Set<String>()
        for c in calls {
            let verb: String
            switch c.kind {
            case .bash: verb = "command"
            case .edit: verb = "edit"; editedFiles.insert(c.fileName ?? c.id)
            case .write: verb = "create"; editedFiles.insert(c.fileName ?? c.id)
            case .read: verb = "read"
            case .search: verb = "search"
            case .agent: verb = "subagent"
            case .file: verb = "sentfile"
            case .skill: verb = "skill"
            case .schedule: verb = "schedule"
            case .mcp: verb = "mcp"
            default: verb = "tool"
            }
            if counts[verb] == nil { order.append(verb) }
            counts[verb, default: 0] += 1
        }
        let parts: [String] = order.map { verb in
            let n = counts[verb] ?? 0
            switch verb {
            case "command": return n == 1 ? "ran a command" : "ran \(n) commands"
            case "edit": return editedFiles.count == 1 ? "edited a file" : "edited \(editedFiles.count) files"
            case "create": return n == 1 ? "created a file" : "created \(n) files"
            case "read": return n == 1 ? "read a file" : "read \(n) files"
            case "search": return n == 1 ? "searched" : "\(n) searches"
            case "subagent": return n == 1 ? "ran a subagent" : "ran \(n) subagents"
            case "sentfile": return "sent files"
            case "skill": return n == 1 ? "used a skill" : "used \(n) skills"
            case "schedule": return "scheduled a check-in"
            case "mcp": return n == 1 ? "made an MCP call" : "made \(n) MCP calls"
            default: return n == 1 ? "used a tool" : "used \(n) tools"
            }
        }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private var addTotal: Int {
        calls.filter { $0.kind == .edit || $0.kind == .write }.map(\.addCount).reduce(0, +)
    }
    private var delTotal: Int {
        calls.filter { $0.kind == .edit || $0.kind == .write }.map(\.delCount).reduce(0, +)
    }
}

// MARK: - Thinking (collapsible)

struct ThinkingBlockView: View {
    @Environment(\.theme) private var theme
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text(expanded ? "Hide thinking" : "Thought for a moment")
                        .font(AppFont.sans(12.5))
                        .italic()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(theme.muted)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(AppFont.sans(13))
                    .foregroundStyle(theme.muted)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.divider).frame(width: 2)
                    }
            }
        }
    }
}
