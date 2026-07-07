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

    var body: some View {
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
                        .onAppear { onReachTop() }
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
                .scrollTargetLayout()
            }
            .scrollPosition(id: $posID, anchor: .top)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(theme.screen)
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
