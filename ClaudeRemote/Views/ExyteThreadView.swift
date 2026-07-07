import SwiftUI
import PhotosUI
import ExyteChat

/// Thread screen backed by exyte/Chat (a flipped-UITableView chat list) — native
/// UIKit keyboard/scroll handling with our own rendering on top. Perf structure:
///
/// - `ExyteThreadAdapter` maps timeline → [Message] once per CONTENT change (not per
///   body eval) and carries per-row content stamps so only changed rows reload.
/// - `ChatPane` is Equatable on the adapter revision: model churn that doesn't touch
///   the transcript (working flag, permissions, grid frames) skips the whole
///   ChatView re-init (and exyte's O(n) mapMessages) entirely.
/// - `StatusStrip` observes the model directly, so it stays live even when the pane
///   short-circuits.
struct ExyteThreadView: View {
    let session: Session
    @StateObject private var model: ThreadModel
    @StateObject private var adapter: ExyteThreadAdapter
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var terminalMode = false   // structured ⇄ raw terminal mirror (P4)

    init(session: Session, relay: RelayClient) {
        self.session = session
        let m = ThreadModel(session: session, relay: relay)
        _model = StateObject(wrappedValue: m)
        _adapter = StateObject(wrappedValue: ExyteThreadAdapter(model: m, session: session))
    }

    var body: some View {
        let _ = Perf.event("threadBody")
        VStack(spacing: 0) {
            header
            if terminalMode {
                TerminalMirrorView(
                    frame: model.gridFrame,
                    onText: { text, enter in model.sendTerminalText(text, enter: enter) },
                    onKeys: { keys in model.sendTerminalKeys(keys) }
                )
            } else {
                ZStack {
                    ChatPane(rev: adapter.rev, session: session, theme: theme, model: model, adapter: adapter)
                        .equatable()
                    if model.isLoading && adapter.messages.isEmpty {
                        MessageSkeleton()   // transcript on its way — shaped placeholder, not a blank
                    }
                }
            }
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationBarHidden(true)
        .onChange(of: terminalMode) { _, on in model.setTerminalMirror(on) }
        .onAppear {
            model.start()
            UserDefaults.standard.set(session.id, forKey: "cr.lastSessionId")   // drawer highlights it
        }
        .onDisappear { model.stop() }
    }

    // MARK: header (ours, fixed above the chat)

    private var header: some View {
        HStack(spacing: 9) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.white)
            }
            Image(systemName: "number").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.faint)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).font(AppFont.sans(16, .bold)).foregroundStyle(theme.white).lineLimit(1)
                Text("\(session.host) · \(session.path)").font(AppFont.mono(10)).foregroundStyle(theme.faint).lineLimit(1)
            }
            Spacer(minLength: 4)
            // Terminal mirror only for drivable sessions — a preview session has no
            // live pane to mirror.
            if session.isRemote && session.canDrive {
                Button { terminalMode.toggle() } label: {
                    Image(systemName: terminalMode ? "bubble.left.and.text.bubble.right" : "terminal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(terminalMode ? theme.blurple : theme.sub)
                }
                .accessibilityLabel(terminalMode ? "Structured view" : "Terminal view")
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["CR_HUD"] != nil { PerfHUD() }
            #endif
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.screen)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

// MARK: - chat pane (Equatable short-circuit)

private struct ChatPane: View, Equatable {
    let rev: Int
    let session: Session
    let theme: Theme
    let model: ThreadModel
    let adapter: ExyteThreadAdapter

    // Streaming-follow: when new content lands while the reader is up in history,
    // light a badge on the scroll-to-bottom button instead of yanking the scroll.
    @State private var atBottom = true
    @State private var newBelow = false

    /// Re-evaluate only when the transcript content (rev) or theme actually changed.
    static func == (l: Self, r: Self) -> Bool {
        l.rev == r.rev && l.session.canDrive == r.session.canDrive && l.theme.screen == r.theme.screen
    }

    var body: some View {
        let _ = Perf.event("chatPaneBody", "rev=\(rev) n=\(adapter.messages.count)")
        ChatView(messages: adapter.messages, chatType: .conversation) { [weak model] draft in
            let t = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard session.isRemote, session.canDrive, !t.isEmpty else { return }
            model?.send(t)
        } messageBuilder: { params in
            MessageCell(params: params, adapter: adapter, model: model, theme: theme, session: session)
        } inputViewBuilder: { params in
            Composer(params: params, session: session, theme: theme, model: model)
        }
        .showDateHeaders(false)
        .showMessageMenuOnLongPress(false)
        .setAvailableInputs([.text])
        .keyboardDismissMode(.interactive)
        .showScrollToBottomButton(true)
        .onScrolledToBottomChanged { bottom in
            atBottom = bottom
            if bottom { newBelow = false }
        }
        .scrollToBottomBadge(newBelow)
        .betweenListAndInputViewBuilder { StatusStrip(model: model, session: session, theme: theme) }
        // Match exyte's bare list surfaces (background + scroll button) to our theme;
        // messages, composer and the strip are our own views.
        .chatTheme(colors: .init(mainBG: theme.screen, mainTint: theme.blurple, inputBG: theme.input))
        .onChange(of: rev) { _, _ in
            if !atBottom { newBelow = true }
        }
    }
}

// MARK: - message cell (our rendering, O(1) lookup)

private struct MessageCell: View {
    let params: MessageBuilderParameters
    @ObservedObject var adapter: ExyteThreadAdapter   // content channel: redraw in place
    @ObservedObject var model: ThreadModel            // optimistic echo + upload thumbs
    let theme: Theme
    var session: Session

    var body: some View {
        let _ = Perf.event("cellHost", params.message.id)
        let fresh = params.message.id == "cr-optimistic"
            || (params.message.id == adapter.lastAppendedId
                && Date().timeIntervalSince(adapter.lastAppendAt) < 1.5)
        Group {
            if params.message.id == "cr-optimistic" {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.optimisticThumbs.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(model.optimisticThumbs.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 116, height: 116)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.leading, 18)
                    }
                    UserMessageView(message: UserMessage(id: "cr-optimistic", text: adapter.optimisticText ?? "", time: nil))
                }
                .opacity(0.6)
            } else if let item = adapter.itemsById[params.message.id] {
                TimelineItemView(item: item, agent: session.agent)
            } else {
                EmptyView()
            }
        }
        .environment(\.theme, theme)   // env doesn't cross the UITableView boundary
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - loading skeleton (thread opening)

private struct MessageSkeleton: View {
    @Environment(\.theme) private var theme
    @State private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            group(nameW: 70, lines: [260, 320, 180])
            group(nameW: 96, lines: [300, 210])
            group(nameW: 70, lines: [280, 330, 140])
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.screen)
        .opacity(on ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
        .onAppear { on = true }
        .allowsHitTesting(false)
    }

    private func group(nameW: CGFloat, lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(theme.codebg).frame(width: 22, height: 22)
                RoundedRectangle(cornerRadius: 3).fill(theme.codebg).frame(width: nameW, height: 11)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                RoundedRectangle(cornerRadius: 3).fill(theme.codebg.opacity(0.7)).frame(width: w, height: 10)
            }
        }
    }
}

// MARK: - working / permission strip (self-observing, stays live when the pane skips)

private struct StatusStrip: View {
    @ObservedObject var model: ThreadModel
    let session: Session
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            if let hint = model.jumpHint {
                SessionJumpBanner(hint: hint, ready: model.listedIds.contains(hint.sessionId)) {
                    Haptics.light()
                    NotificationCenter.default.post(name: .crJumpSession, object: nil,
                                                    userInfo: ["id": hint.sessionId])
                    model.jumpHint = nil
                }
                .environment(\.theme, theme)
                .onAppear { Haptics.rigid() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.pop, value: model.jumpHint)
            }
            if let fail = model.sendFailure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.red)
                    Text(fail)
                        .font(AppFont.sans(12.5))
                        .foregroundStyle(theme.red)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.faint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.red.opacity(0.12))
                .contentShape(Rectangle())
                .onTapGesture { model.sendFailure = nil }
            }
            ForEach(model.pendingPermissions) { req in
                PermissionCard(
                    req: req,
                    onAllow: { model.resolvePermission(req, allow: true) },
                    onDeny: { model.resolvePermission(req, allow: false) }
                )
            }
            if model.working && model.pendingPermissions.isEmpty {
                WorkingIndicator(label: session.agent.short, startedAt: model.workStartedAt)
            }
        }
        .environment(\.theme, theme)
    }
}

// MARK: - composer (ours; send routes through exyte so it resets its text state)

private struct Composer: View {
    let params: InputViewBuilderParameters
    let session: Session
    let theme: Theme
    @ObservedObject var model: ThreadModel

    @State private var attachments: [PickedAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var showAddSheet = false
    @FocusState private var inputFocused: Bool
    @State private var sendTick = false
    @State private var showModelSheet = false
    @State private var showEffortSheet = false

    /// Which selectors this agent supports — unsupported agents show a static
    /// default chip only (per product rule).
    private var supportsModelSwitch: Bool { session.agent == .claude || session.agent == .til }

    private func canSend(_ text: String) -> Bool {
        session.isRemote && session.canDrive &&
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var typingDisabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CR_MOCK"] != nil { return false }
        #endif
        return live.isPreview
    }

    @ViewBuilder
    private func selectorChip(icon: String, label: String, action: (() -> Void)?) -> some View {
        let core = HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
            Text(label)
                .font(AppFont.mono(11, .medium))
                .lineLimit(1)
            if action != nil {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.faint)
            }
        }
        .foregroundStyle(theme.sub)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.plusBtn.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(theme.border.opacity(0.6), lineWidth: 1))
        if let action {
            Button(action: action) { core }.buttonStyle(PressableStyle())
        } else {
            core
        }
    }

    private var contextPercent: Int? {
        guard supportsModelSwitch, let t = model.contextTokens, t > 0 else { return nil }
        return min(99, Int((Double(t) / contextWindow) * 100))
    }

    /// Context window by model id: 1M-beta models carry a "[1m]" suffix;
    /// everything else in the Claude family is 200k today.
    private var contextWindow: Double {
        let id = (model.liveSession ?? session).model ?? ""
        return id.contains("[1m]") || id.contains("-1m") ? 1_000_000 : 200_000
    }

    private var effortChipLabel: String {
        model.chosenEffort ?? live.defaultEffort ?? "effort"
    }

    /// The session's ACTUAL current model id: transcript truth first, then the
    /// Claude global default from settings.json.
    private var liveModelId: String {
        (live.model?.isEmpty == false ? live.model : nil) ?? live.defaultModel ?? ""
    }

    /// Map a model id ("claude-fable-5[1m]") to the short `/model` arg.
    static func modelArg(from id: String) -> String? {
        let l = id.lowercased()
        if l.contains("fable") { return "fable" }
        if l.contains("opus") { return "opus" }
        if l.contains("sonnet") { return "sonnet" }
        if l.contains("haiku") { return "haiku" }
        return nil
    }

    private var modelChipLabel: String {
        let name: String
        if let m = model.chosenModel,
           let opt = ModelPickerSheet.models.first(where: { $0.arg == m }) {
            name = opt.name
        } else {
            name = currentModelLabel
        }
        return name
    }

    private var currentModelLabel: String {
        // Same fallback chain as the sheet preselection: transcript model →
        // Claude global default → generic label. The chip used to show a bare
        // "Model" whenever the transcript hadn't named one yet.
        if let arg = Self.modelArg(from: liveModelId),
           let opt = ModelPickerSheet.models.first(where: { $0.arg == arg }) {
            return opt.name
        }
        if !liveModelId.isEmpty { return AssistantGroupView.modelLabel(liveModelId) }
        return "Model"
    }

    /// Live view of this session (list pushes refresh it); falls back to the
    /// opening snapshot until the first push lands.
    private var live: Session { model.liveSession ?? session }

    private var placeholder: String {
        if !session.isRemote { return "Read-only · pair a Mac to reply" }
        if live.cwdLive && !live.agentAlive {
            return "Agent exited — restart claude/codex in vibTTY to reply"
        }
        if !live.canDrive {
            return live.cwdLive
                ? "Preview · a newer session is active in this project — open the latest to reply"
                : "Preview only · not open in vibTTY — resume it there to reply"
        }
        return "Message #\(session.name)"
    }

    private func doSend() {
        guard live.canDrive else { return }
        guard canSend(params.text.wrappedValue) else { return }
        Haptics.light()
        sendTick.toggle()
        model.send(params.text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments)
        params.text.wrappedValue = ""
        attachments = []
    }

    var body: some View {
        // Reference layout (Claude Code iOS): ONE rounded container — media
        // previews on top, roomy text in the middle, action row at the bottom
        // with a filled circular send button.
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty { previewStrip }
            TextField("", text: params.text, prompt: Text(placeholder).foregroundColor(theme.faint), axis: .vertical)
                .font(AppFont.sans(15))
                .foregroundStyle(theme.ink)
                .tint(theme.blurple)
                .lineLimit(1 ... 6)
                .frame(minHeight: 24)
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .focused($inputFocused)
                .disabled(typingDisabled)
            HStack(spacing: 10) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.sub)
                        .frame(width: 34, height: 34)
                        .background(theme.plusBtn.opacity(0.9), in: Circle())
                        .overlay(Circle().stroke(theme.border.opacity(0.6), lineWidth: 1))
                }
                .disabled(typingDisabled)
                if session.isRemote && live.canDrive {
                    if supportsModelSwitch {
                        selectorChip(icon: "cpu", label: modelChipLabel) {
                            Haptics.selection(); showModelSheet = true
                        }
                        selectorChip(icon: "gauge.with.needle", label: effortChipLabel) {
                            Haptics.selection(); showEffortSheet = true
                        }
                    } else {
                        // Unsupported agent (e.g. Codex today): show ITS model
                        // (from its own transcript), never Claude's defaults.
                        selectorChip(icon: "cpu",
                                     label: (live.model?.isEmpty == false ? live.model! : session.agent.displayName),
                                     action: nil)
                            .opacity(0.55)
                    }
                    if let pct = contextPercent {
                        ContextRing(percent: pct)
                            .padding(.leading, 2)
                    }
                }
                Spacer(minLength: 0)
                Button { doSend() } label: {
                    Image(systemName: "arrow.up")
                        .symbolEffect(.bounce, value: sendTick)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(canSend(params.text.wrappedValue) ? theme.blurple : theme.plusBtn, in: Circle())
                }
                .disabled(!canSend(params.text.wrappedValue))
                .animation(.easeOut(duration: 0.15), value: canSend(params.text.wrappedValue))
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(theme.input, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(theme.border.opacity(0.7), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !typingDisabled { inputFocused = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(theme.screen)
        .environment(\.theme, theme)
        // PhotosPicker must NOT live inside a Menu — the Menu dismisses before it can
        // present. Drive it from a confirmationDialog via an isPresented flag instead.
        .confirmationDialog("Add attachment", isPresented: $showAddSheet, titleVisibility: .visible) {
            Button("Photo Library") { showPhotos = true }
            Button("Files") { showFiles = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .sheet(isPresented: $showModelSheet) {
            ModelPickerSheet(mode: .model, currentModelLabel: currentModelLabel,
                             initialSelection: model.chosenModel ?? Self.modelArg(from: liveModelId)) { arg in
                model.sendCommand("/model \(arg)")
                model.chosenModel = arg
            }
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $showEffortSheet) {
            ModelPickerSheet(mode: .effort, currentModelLabel: currentModelLabel,
                             initialSelection: model.chosenEffort ?? live.defaultEffort) { arg in
                model.sendCommand("/effort \(arg)")
                model.chosenEffort = arg
            }
            .environment(\.theme, theme)
        }
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                for url in urls { if let a = AttachmentPrep.fromFile(url: url) { attachments.append(a) } }
            }
        }
    }

    /// Removable previews above the input row (Claude-Code-iOS layout: media on
    /// top, text below). Bigger thumbs + a bold ✕ badge per the reference.
    private var previewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { a in
                    // The ✕ badge must stay INSIDE the ZStack bounds — content
                    // offset outside its parent is not hit-testable in SwiftUI.
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let t = a.thumbnail {
                                Image(uiImage: t).resizable().scaledToFill()
                                    .frame(width: 92, height: 92)
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc.fill").font(.system(size: 24)).foregroundStyle(theme.sub)
                                    Text((a.name as NSString).pathExtension.uppercased())
                                        .font(AppFont.mono(9)).foregroundStyle(theme.faint)
                                }
                                .frame(width: 92, height: 92)
                                .background(theme.card)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.top, 9)
                        .padding(.trailing, 9)
                        Button { withAnimation(.easeOut(duration: 0.15)) { attachments.removeAll { $0.id == a.id } } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(.black.opacity(0.78), in: Circle())
                                .overlay(Circle().stroke(theme.screen, lineWidth: 2))
                        }
                        .accessibilityLabel("Remove attachment")
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data),
                   let a = AttachmentPrep.fromImage(img, name: nil) {
                    await MainActor.run { attachments.append(a) }
                }
            }
            await MainActor.run { photoItems = [] }
        }
    }
}
