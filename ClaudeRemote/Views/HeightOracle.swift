import SwiftUI
import UIKit

/// Off-screen row-height pre-measurement. Agent transcripts have ~100x height
/// variance between rows (a markdown table vs one sentence) — UITableView's
/// estimate-then-correct sizing bounced the scroll past every freshly
/// inserted history page. Rows measured here feed the list EXACT heights via
/// `rowHeightProvider`, so estimation (and its correction jumps) never runs
/// for covered rows. Unmeasured rows fall back to self-sizing.
@MainActor
final class HeightOracle {
    private var cache: [String: CGFloat] = [:]
    private let host = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))

    private func key(_ id: String, _ width: CGFloat) -> String { "\(id)|\(Int(width))" }

    func height(id: String, width: CGFloat) -> CGFloat? {
        cache[key(id, width)]
    }

    /// Measure one row's twin view at the given width (no-op when cached).
    func measure(id: String, width: CGFloat, @ViewBuilder twin: () -> some View) {
        let k = key(id, width)
        guard cache[k] == nil, width > 0 else { return }
        host.rootView = AnyView(twin().frame(width: width, alignment: .leading))
        host.view.bounds = CGRect(x: 0, y: 0, width: width, height: 10)
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        cache[k] = size.height
    }

    /// Streaming rows change content under a cached height — drop them.
    func invalidate(id: String) {
        cache = cache.filter { !$0.key.hasPrefix("\(id)|") }
    }

    func invalidateAll() { cache.removeAll() }
}
