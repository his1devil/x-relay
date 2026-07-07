import SwiftUI

/// Platform-native timeline list — the claude-code-app architecture:
/// ScrollView + LazyVStack + scrollPosition(id:). History prepends are held
/// stable by the SYSTEM (spike-verified: 100 variable-height rows prepend →
/// 0.1pt anchor drift), so there is no estimation, no reloadData, no offset
/// compensation — the whole class of history-mount jumps cannot exist here.
/// Mount trigger mirrors claude code: reaching the TOP reveals a spinner row;
/// only while it is visible does the next page mount.
struct NativeTimelineList: View {
    let items: [TimelineItem]
    let agent: AgentKind
    let theme: Theme
    let optimisticText: String?
    let hasMoreHistory: Bool
    let onReachTop: () -> Void
    let onAtBottomChanged: (Bool) -> Void
    @Binding var jumpToBottom: Bool

    @State private var posID: String?
    @State private var atBottom = true
    @State private var topSpinnerVisible = false
    /// Until the user drags, the viewport is PINNED to the newest message:
    /// opening lands at the bottom and back-filled history grows silently
    /// above. First drag hands control to the user (spinner paging takes
    /// over at the top).
    @State private var userHasScrolled = false

    var body: some View {
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hasMoreHistory {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small).tint(theme.sub)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .id("cr-top-loading")
                        // onAppear alone fires ONCE: after the first mount the
                        // spinner stays resident at the top of the lazy stack
                        // and never "appears" again — paging silently stopped
                        // after page one. Track actual visibility instead and
                        // CHAIN mounts while it stays on screen.
                        .overlay {
                            GeometryReader { g in
                                Color.clear
                                    .onChange(of: g.frame(in: .global).minY, initial: true) { _, y in
                                        topSpinnerVisible = y > -40 && y < UIScreen.main.bounds.height
                                        if topSpinnerVisible { onReachTop() }
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
                        .onDisappear { atBottom = false; onAtBottomChanged(false) }
                }
                .frame(minHeight: geo.size.height, alignment: .bottom)   // short threads hug the composer
                .scrollTargetLayout()
            }
            .scrollPosition(id: $posID, anchor: .top)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(theme.screen)
            .onChange(of: items.first?.id) { _, _ in
                // History page landed. Before the user's first drag, CLEAR
                // the position anchor so defaultScrollAnchor(.bottom) keeps
                // the viewport glued to the newest message (scrollTo is a
                // no-op for lazily-unrealized rows; scrollPosition would
                // "helpfully" pin us to the OLD content instead). After the
                // first drag, posID takes over and prepends hold position.
                if !userHasScrolled {
                    posID = nil
                }
                // Parked at the top spinner → chain the next page until the
                // buffer runs dry (claude-code feel).
                if userHasScrolled, topSpinnerVisible, hasMoreHistory {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onReachTop() }
                }
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in userHasScrolled = true }
            )
            .onChange(of: items.last?.id) { _, newLast in
                // Follow the stream only when parked at the bottom.
                if atBottom, let newLast {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("cr-bottom", anchor: .bottom)
                    }
                    _ = newLast
                }
            }
            .onChange(of: optimisticText) { _, v in
                if v != nil {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("cr-bottom", anchor: .bottom)
                    }
                }
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
}
