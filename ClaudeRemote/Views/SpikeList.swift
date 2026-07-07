#if DEBUG
import SwiftUI

/// SPIKE (CR_SPIKE=1): does ScrollView+LazyVStack+scrollPosition(id:) keep
/// the anchored row VISUALLY FIXED across a 100-row variable-height prepend?
/// iOS 17 API. Prints [spike] BEFORE/AFTER with the anchor row's minY.
struct SpikeRow: Identifiable {
    let id: Int
    let h: CGFloat
}

struct SpikeList: View {
    @State private var rows: [SpikeRow] = (1000..<1040).map { SpikeRow(id: $0, h: CGFloat(40 + ($0 * 37) % 260)) }
    @State private var posID: Int?
    @State private var anchorY: CGFloat = -1

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { r in
                    Text("row \(r.id)")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: r.h, maxHeight: r.h)
                        .background(r.id % 2 == 0 ? Color(white: 0.22) : Color(white: 0.15))
                        .foregroundStyle(.white)
                        .overlay(alignment: .topLeading) {
                            if r.id == 1000 {
                                GeometryReader { g in
                                    Color.clear.onChange(of: g.frame(in: .global).minY) { _, y in
                                        anchorY = y
                                    }
                                    .onAppear { anchorY = g.frame(in: .global).minY }
                                }
                            }
                        }
                        .id(r.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $posID, anchor: .top)
        .background(Color.black)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                posID = 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let before = anchorY
                    NSLog("[spike] BEFORE prepend anchor minY=%.1f posID=%@", before, String(describing: posID))
                    rows.insert(contentsOf: (0..<100).map { SpikeRow(id: $0, h: CGFloat(40 + ($0 * 53) % 260)) }, at: 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        NSLog("[spike] AFTER prepend anchor minY=%.1f drift=%.1f posID=%@ %@",
                              anchorY, anchorY - before, String(describing: posID),
                              abs(anchorY - before) < 2 ? "PASS" : "FAIL")
                    }
                }
            }
        }
    }
}
#endif
