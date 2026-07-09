import SwiftUI

/// Platform-native timeline list — the claude-code-app architecture:
/// ScrollView + LazyVStack + scrollPosition(id:). History prepends are held
/// stable by the SYSTEM (spike-verified: 100 variable-height rows prepend →
/// 0.1pt anchor drift), so there is no estimation, no reloadData, no offset
/// compensation — the whole class of history-mount jumps cannot exist here.
/// Mount trigger mirrors claude code: reaching the TOP reveals a spinner row;
/// only while it is visible does the next page mount.
/// Finds the enclosing UIScrollView so the pull gesture can require
/// `isTracking` — a finger physically on the glass. Momentum rubber-band
/// (isTracking == false) can spike deep past any threshold; a synthetic or
/// real flick must never mount history.
private struct ScrollViewIntrospector: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { [weak v] in
            var p: UIView? = v
            while let cur = p, !(cur is UIScrollView) { p = cur.superview }
            if let sv = p as? UIScrollView { onResolve(sv) }
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct NativeTimelineList: View {
    let items: [TimelineItem]
    let agent: AgentKind
    let theme: Theme
    let optimisticText: String?
    let hasMoreHistory: Bool
    let loadingOlder: Bool
    let mountTick: Int
    /// Bumped on every (re)parse — including IN-PLACE growth of the tail
    /// assistant group, which items.last?.id can never see. Drives streaming
    /// follow for the scrolled-up-then-returned-to-bottom mode where the
    /// pinned anchor no longer applies.
    let contentRevision: Int
    let onPullHistory: () -> Void
    let onPullSettled: () -> Void
    let onAtBottomChanged: (Bool) -> Void
    @Binding var jumpToBottom: Bool

    @State private var posID: String?
    @State private var atBottom = true
    @State private var overscroll: CGFloat = 0
    @State private var overscrollSince: Date?
    @State private var scrollViewRef: UIScrollView?
    @State private var pullArmed = false
    @State private var pullAnchorID: String?
    /// Keyboard transitions hide the bottom sentinel — that must not count
    /// as the user scrolling (it killed the pin and broke give-back).
    @State private var kbGuard = false
    @State private var settleTries = 0
    @State private var endHintVisible = false
    /// Until the user drags, the viewport is PINNED to the newest message:
    /// opening lands at the bottom and back-filled history grows silently
    /// above. First drag hands control to the user (spinner paging takes
    /// over at the top).
    @State private var userHasScrolled = false

    /// Scroll to the newest message and RETRY until the bottom sentinel
    /// confirms (one-shot scrollTo raced iOS 26's layout cadence and stalled
    /// mid-list on some sessions).
    private func settleToBottom(_ proxy: ScrollViewProxy) {
        settleTries = 0
        func attempt() {
            proxy.scrollTo("cr-bottom", anchor: .bottom)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                if !atBottom, settleTries < 40 {
                    settleTries += 1
                    attempt()
                }
            }
        }
        attempt()
    }

    private func showEndHint() {
        endHintVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { endHintVisible = false }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Overscroll sentinel: its minY in the scroll coordinate
                    // space goes POSITIVE only while the user drags past the
                    // top (rubber-band). Passing the threshold arms the pull;
                    // one pull mounts exactly one chunk — strictly user-driven.
                    Color.clear.frame(height: 1)
                        .background(ScrollViewIntrospector { sv in scrollViewRef = sv })
                        .overlay {
                            GeometryReader { g in
                                Color.clear.onChange(of: g.frame(in: .named("cr-scroll")).minY) { _, y in
                                    overscroll = max(0, y)
                                    // A flick's rubber-band is a brief spike;
                                    // a deliberate pull is DEEP (>110pt) and
                                    // SUSTAINED (>0.12s). Require both so
                                    // momentum bounces never mount history.
                                    if y > 140, userHasScrolled, !loadingOlder,
                                       let sv = scrollViewRef, sv.isTracking,
                                       sv.contentOffset.y < 50 {
                                        if overscrollSince == nil { overscrollSince = Date() }
                                        if let t = overscrollSince, Date().timeIntervalSince(t) > 0.2 {
                                            overscrollSince = nil
                                            if hasMoreHistory {
                                                pullArmed = true
                                                onPullHistory()
                                            } else if !endHintVisible {
                                                showEndHint()
                                            }
                                        }
                                    } else if y < 80 {
                                        overscrollSince = nil
                                    }
                                    // Armed pull executes only once the finger
                                    // lifts AND the rubber-band has settled —
                                    // splicing mid-drag shifted the anchor.
                                    if pullArmed, y < 16, scrollViewRef?.isTracking != true {
                                        pullArmed = false
                                        // At the absolute top the viewport's
                                        // first row is the id-less sentinel, so
                                        // the position binding reads nil — no
                                        // anchor, and a prepend would slide the
                                        // viewport into the new content. Pin
                                        // the OLDEST real row explicitly (it's
                                        // already at the top: zero movement),
                                        // then splice.
                                        // GEOMETRY snapshot: after the splice, restoring is
                                        // pure algebra — offset += Δ(contentSize.height).
                                        // Every id-anchored scheme died on shifting group/
                                        // divider identities at the seam.
                                        if let sv = scrollViewRef {
                                            // At the true top (off<50 gate) the
                                            // oldest real row IS the viewport-top
                                            // row; boundary normalization keeps
                                            // its id stable across the splice.
                                            pullAnchorID = items.first(where: { !$0.id.hasPrefix("div-") })?.id
                                            // Align the viewport to the anchor's
                                            // top BEFORE the splice — restore
                                            // then reproduces this exact frame
                                            // (kills the residual half-row nudge).
                                            if let a = pullAnchorID {
                                                posID = a
                                                proxy.scrollTo(a, anchor: .top)
                                            }
                                            _ = sv
                                        }
                                        onPullSettled()
                                    }
                                }
                            }
                        }
                    ForEach(items) { item in
                        TimelineItemView(item: item, agent: agent)
                            .id(item.id)
                    }
                    if let opt = optimisticText, !opt.isEmpty {
                        UserMessageView(message: UserMessage(id: "cr-optimistic", text: opt, time: nil))
                            .opacity(0.6)
                            .id("cr-optimistic")
                    }
                    // Bottom sentinel: tracks whether the user is parked at
                    // the newest message (drives follow-stream + the badge).
                    Color.clear.frame(height: 1)
                        .id("cr-bottom")
                        .onAppear { atBottom = true; onAtBottomChanged(true) }
                        .onDisappear {
                            // Keyboard transitions must not count as the user
                            // leaving the bottom (order matters: the guard
                            // check ran AFTER state was already torn down,
                            // so follow-mode died and the jump button popped
                            // during every keyboard move).
                            if kbGuard { return }
                            atBottom = false
                            onAtBottomChanged(false)
                            // While pinned (posID nil + bottom anchor) the
                            // sentinel CANNOT leave the viewport — so its
                            // disappearance is, by elimination, the user's
                            // first scroll. This replaces a full-surface
                            // DragGesture that was stealing the navigation
                            // edge-swipe (right-swipe back stopped working).
                            userHasScrolled = true
                        }
                }
                .scrollTargetLayout()
            }
            .coordinateSpace(name: "cr-scroll")
            .scrollPosition(id: $posID, anchor: .top)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    settleToBottom(proxy)
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            })
            .background(theme.screen)
            .overlay(alignment: .top) {
                if loadingOlder || endHintVisible {
                    Group {
                        if loadingOlder {
                            ProgressView().controlSize(.small).tint(theme.sub)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.sub)
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: loadingOlder)
            .animation(.easeOut(duration: 0.2), value: endHintVisible)
            .onChange(of: mountTick) { _, _ in
                // History chunk landed: hold the pre-splice top row in
                // place. scrollPosition applies it in the SAME layout
                // pass (geometry compensation raced the render frame —
                // contentSize hadn't grown yet on the async hop).
                if let anchor = pullAnchorID {
                    pullAnchorID = nil
                    posID = anchor
                    proxy.scrollTo(anchor, anchor: .top)
                }
                // History page landed. Before the user's first drag, CLEAR
                // the position anchor so defaultScrollAnchor(.bottom) keeps
                // the viewport glued to the newest message (scrollTo is a
                // no-op for lazily-unrealized rows; scrollPosition would
                // "helpfully" pin us to the OLD content instead). After the
                // first drag, posID takes over and prepends hold position.
                if !userHasScrolled {
                    posID = nil
                    // defaultScrollAnchor(.bottom) can overshoot into empty
                    // space under lazy estimation (viewport past the real
                    // content after the hug-frame removal) — land explicitly.
                    settleToBottom(proxy)
                }
            }

            .onChange(of: contentRevision) { _, _ in
                // Follow the stream only when parked at the bottom. Revision
                // moves on every parse — new rows AND in-place tail growth
                // (items.last?.id misses the latter; anchor-pinned mode
                // already follows, this covers the posID return-to-bottom mode).
                if atBottom {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("cr-bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: optimisticText) { _, v in
                if v != nil {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("cr-bottom", anchor: .bottom)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                // Inset architecture handles the geometry; we only guard the
                // sentinel misreads during the transition.
                kbGuard = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { kbGuard = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                kbGuard = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { kbGuard = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { _ in
                // Interactive dismiss drives continuous frame changes that
                // show/hide never report — same sentinel protection applies.
                kbGuard = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { kbGuard = false }
            }
            .onChange(of: jumpToBottom) { _, go in
                if go {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        proxy.scrollTo("cr-bottom", anchor: .bottom)
                    }
                    jumpToBottom = false
                }
            }
        }
    }
}
