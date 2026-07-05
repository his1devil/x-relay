import UIKit

/// Re-enable the native left-edge swipe-to-go-back gesture.
///
/// SwiftUI's `NavigationStack` drives a `UINavigationController`, but hiding the
/// nav bar (which every screen here does, to draw its own Discord-style header)
/// also disables the interactive pop gesture. Re-pointing its delegate at the
/// nav controller restores the smooth edge swipe on every pushed screen, and the
/// `count > 1` guard keeps it from firing on the root.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
