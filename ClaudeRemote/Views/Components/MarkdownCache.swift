import Foundation

/// Caches parsed markdown blocks by source text so `RichText` never re-parses the
/// same prose on each `LazyVStack` row re-evaluation while scrolling.
enum MarkdownCache {
    private final class Box { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }
    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 800
        return c
    }()

    static func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let box = cache.object(forKey: key) { return box.blocks }
        let blocks = MarkdownBlock.parse(text)
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }
}
