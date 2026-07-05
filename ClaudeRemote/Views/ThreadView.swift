import SwiftUI

struct ThreadView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @StateObject private var model: ThreadModel
    @State private var draft = ""
    @State private var terminalMode = false   // structured ⇄ terminal mirror (P4)
    @FocusState private var focused: Bool
    @State private var didInitialScroll = false
    @State private var atBottom = true        // is the bottom sentinel on screen?
    @State private var hasNewBelow = false     // new content arrived while scrolled up
    @State private var initialReady = false    // initial jump converged — safe to stream-follow
    @StateObject private var kb = KeyboardObserver()

    private let topAnchor = "THREAD_TOP"
    private let bottomAnchor = "THREAD_BOTTOM"

    init(session: Session, relay: RelayClient? = nil) {
        self.session = session
        _model = StateObject(wrappedValue: ThreadModel(session: session, relay: relay))
    }

    private var canSend: Bool {
        session.isRemote && session.canDrive && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        if !session.isRemote { return "Read-only · pair a Mac to reply" }
        if !session.canDrive { return "Preview only · not hosted in vibTTY — resume it there to reply" }
        return "Message #\(session.name)"
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.isRemote, session.canDrive, !text.isEmpty else { return }
        draft = ""            // clear immediately (IM-style) — optimistic echo shows the sent text
        model.send(text)
    }

    var body: some View {
        // Plain SwiftUI: the composer is a native TextField so SwiftUI's keyboard
        // avoidance moves the whole stack in lockstep with the keyboard (a custom
        // UITextView composer breaks that). `axis: .vertical` gives native
        // auto-grow; `defaultScrollAnchor(.bottom)` keeps the latest visible.
        VStack(spacing: 0) {
            header
            if terminalMode {
                TerminalMirrorView(
                    frame: model.gridFrame,
                    onText: { text, enter in model.sendTerminalText(text, enter: enter) },
                    onKeys: { keys in model.sendTerminalKeys(keys) }
                )
            } else {
                // Composer as the scroll view's bottom safe-area inset: the ScrollView
                // tracks the keyboard NATIVELY (adjusting its content inset) instead of
                // the whole stack being shoved up + re-laid-out — smooth, no blank band.
                transcript
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .background(theme.screen.ignoresSafeArea())
        .navigationBarHidden(true)
        .onChange(of: terminalMode) { _, on in model.setTerminalMirror(on) }
        .onAppear {
            model.start()
            let env = ProcessInfo.processInfo.environment
            if session.isRemote, let text = env["CR_AUTOSEND"], env["CR_AUTOPUSH_ID"] == session.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.send(text) }
            }
            if env["CR_FOCUS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { focused = true }
            }
        }
        .onDisappear { model.stop() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.white)
            }
            Image(systemName: "number")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.faint)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(AppFont.sans(16, .bold))
                    .foregroundStyle(theme.white)
                    .lineLimit(1)
                Text("\(session.host) · \(session.path)")
                    .font(AppFont.mono(10))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // Terminal mirror only for drivable sessions — a preview session has no
            // live pane to mirror, so the toggle is hidden (else it spun "Waiting for
            // terminal…" forever).
            if session.isRemote && session.canDrive {
                Button { terminalMode.toggle() } label: {
                    Image(systemName: terminalMode ? "bubble.left.and.text.bubble.right" : "terminal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(terminalMode ? theme.blurple : theme.sub)
                }
                .accessibilityLabel(terminalMode ? "Structured view" : "Terminal view")
            }
            Text("v23")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.faint.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(theme.screen)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    // MARK: transcript

    @ViewBuilder
    private var transcript: some View {
        if model.isLoading && model.items.isEmpty {
            // MUST be a SINGLE view: this is the base of the composer's `.safeAreaInset`,
            // and a multi-element builder result (Spacer/ProgressView/Spacer) makes the
            // inset render once PER element — the "3 input boxes while loading" bug.
            ProgressView()
                .tint(theme.blurple)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loadedTranscript
        }
    }

    private var loadedTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 12).id(topAnchor)
                    ForEach(model.items) { item in
                        TimelineItemView(item: item)
                    }
                    if let opt = model.optimisticUser {
                        UserMessageView(message: UserMessage(id: "optimistic", text: opt, time: Date()))
                            .opacity(0.55)
                            .id("cr-optimistic")
                    }
                    ForEach(model.pendingPermissions) { req in
                        PermissionCard(
                            req: req,
                            onAllow: { model.resolvePermission(req, allow: true) },
                            onDeny: { model.resolvePermission(req, allow: false) }
                        )
                    }
                    if model.working && model.pendingPermissions.isEmpty {
                        WorkingIndicator(label: session.agent.short).id("cr-working")
                    }
                    Color.clear.frame(height: 12).id(bottomAnchor)
                        .onAppear { atBottom = true; hasNewBelow = false }
                        .onDisappear { atBottom = false }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { focused = false })
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["CR_TOP"] != nil ? .top : .bottom)
            .overlay(alignment: .bottomTrailing) { scrollArrows(proxy) }
            .onChange(of: model.isLoading) { _, loading in
                if !loading, !didInitialScroll { didInitialScroll = true; jumpToBottomInitially(proxy) }
            }
            .onAppear {
                if !model.items.isEmpty, !didInitialScroll { didInitialScroll = true; jumpToBottomInitially(proxy) }
            }
            // Sending: re-engage follow so the user always sees their message + the reply.
            .onChange(of: model.optimisticUser) { _, _ in atBottom = true; scrollToBottom(proxy) }
            .onChange(of: model.pendingPermissions.count) { _, _ in atBottom = true; scrollToBottom(proxy) }
            // Keyboard: the composer rides up natively (safeAreaInset), but a ScrollView
            // won't re-anchor its content when the keyboard resizes the viewport — the
            // last messages slide behind it. So on each keyboard transition scroll to the
            // bottom, animated with the SYSTEM's own duration, so the list moves on the
            // SAME beat as the keyboard (not a snap after it settles).
            .onChange(of: kb.tick) { _, _ in
                withAnimation(.easeOut(duration: kb.duration)) {
                    proxy.scrollTo(bottomTargetID, anchor: .bottom)
                }
            }
            // Stream-follow: while parked at the bottom (or mid-turn) keep the latest in
            // view as content streams in; if the user scrolled up, don't yank them — flag
            // the down-arrow instead.
            .onChange(of: model.revision) { _, _ in
                guard initialReady else { return }
                if atBottom || model.working { scrollToBottom(proxy) }
                else { withAnimation(.easeInOut(duration: 0.2)) { hasNewBelow = true } }
            }
        }
    }

    /// The bottom-most CONCRETE view currently rendered — scroll targets this, never
    /// the empty trailing anchor.
    private var bottomTargetID: String {
        if model.working && model.pendingPermissions.isEmpty { return "cr-working" }
        if let last = model.pendingPermissions.last { return last.id }
        if model.optimisticUser != nil { return "cr-optimistic" }
        return model.items.last?.id ?? bottomAnchor
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Scroll to the bottom-most CONCRETE view (working indicator / optimistic echo /
        // last item), never the empty trailing anchor: SwiftUI walks to (and measures) a
        // real view, so a big late block — e.g. a file-view tool embed — can't leave us
        // overshot in blank space. Re-issue across ticks so it settles as that block
        // finishes measuring. `bottomTargetID` is recomputed each pass so it tracks a
        // target that changes mid-scroll (optimistic → real, working → done).
        func go() { proxy.scrollTo(bottomTargetID, anchor: .bottom) }
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.22)) { go() }
            }
        }
        for delay in (animated ? [0.28, 0.55] : [0.0, 0.05, 0.15, 0.3, 0.55]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: go))
        }
    }

    /// Initial open: converge to the bottom, then arm stream-follow (only after the
    /// jump settles, so a mid-jump revision doesn't scroll the still-unmeasured stack).
    private func jumpToBottomInitially(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { initialReady = true }
    }

    private func scrollArrows(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 10) {
            arrowButton("chevron.up") { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(topAnchor, anchor: .top) } }
            arrowButton("chevron.down", highlight: hasNewBelow) {
                hasNewBelow = false
                atBottom = true
                scrollToBottom(proxy)
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, 14)
    }

    private func arrowButton(_ icon: String, highlight: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(highlight ? .white : theme.sub)
                .frame(width: 34, height: 34)
                .background(highlight ? theme.blurple : theme.card.opacity(0.92), in: Circle())
                .overlay(Circle().stroke(highlight ? Color.clear : theme.border, lineWidth: 1))
                .shadow(color: highlight ? theme.blurple.opacity(0.5) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 9) {
            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 30, height: 30)
                    .background(theme.plusBtn, in: Circle())
            }
            TextField("", text: $draft, prompt: Text(placeholder).foregroundColor(theme.faint), axis: .vertical)
                .font(AppFont.sans(14.5))
                .foregroundStyle(draft.hasPrefix("/") ? theme.blurple : theme.ink)
                .tint(theme.blurple)
                .focused($focused)
                .lineLimit(1...5)
                .frame(minHeight: 30)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(session.isPreview)   // preview-only: composer read-only, placeholder explains
                // A vertical TextField's Return inserts a newline and `onSubmit` is
                // unreliable — so treat a trailing newline as "send" (IM-style): the
                // message reliably goes out and the box clears instead of keeping the
                // stray newline.
                .onChange(of: draft) { _, new in
                    guard new.hasSuffix("\n") else { return }
                    let body = String(new.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    draft = ""
                    guard session.isRemote, session.canDrive, !body.isEmpty else { return }
                    model.send(body)
                }
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.blurple)
                    .frame(width: 30, height: 30)
            }
            .opacity(canSend ? 1 : 0.4)
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.input, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(theme.screen)   // opaque so scroll content can't peek behind the inset
    }
}
