import SwiftUI

/// Publishes keyboard show/hide together with the SYSTEM's own animation duration.
///
/// SwiftUI already moves a `safeAreaInset` composer with the keyboard natively, but a
/// `ScrollView` won't re-anchor its content to the bottom when the keyboard changes the
/// viewport — so the last messages slide behind the keyboard ("not in sync"). Views can
/// observe `tick` and scroll to the bottom inside `withAnimation(.easeOut(duration:))`
/// using `duration`, so the list moves on the SAME beat as the keyboard instead of
/// snapping after it settles.
final class KeyboardObserver: ObservableObject {
    /// Bumped on every keyboard show/hide — a change signal to re-anchor against.
    @Published var tick = 0
    /// The system keyboard's animation duration for the latest transition.
    private(set) var duration: Double = 0.25

    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        // Delivered on .main, so mutating @Published here is safe.
        let handle: (Notification) -> Void = { [weak self] note in
            guard let self else { return }
            self.duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            self.tick &+= 1
        }
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main, using: handle))
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main, using: handle))
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
