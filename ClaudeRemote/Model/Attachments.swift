import SwiftUI
import UIKit
import CryptoKit
import UniformTypeIdentifiers

/// One attachment queued in the composer (already prepped: images are compressed
/// JPEGs, files are raw bytes).
struct PickedAttachment: Identifiable {
    let id = UUID().uuidString
    let name: String
    let mime: String
    let data: Data
    let thumbnail: UIImage?
    var isImage: Bool { mime.hasPrefix("image/") }
}

/// Turn picker results into upload-ready attachments. Images are downscaled to a
/// 2048px long edge and re-encoded as JPEG (the "default compress" choice) —
/// plenty for Claude to read a screenshot/design while keeping transfers small.
enum AttachmentPrep {
    static func fromImage(_ image: UIImage, name: String?) -> PickedAttachment? {
        let capped = resize(image, maxEdge: 2048)
        guard let data = capped.jpegData(compressionQuality: 0.82) else { return nil }
        let base = (name.map { ($0 as NSString).deletingPathExtension } ?? "image")
        return PickedAttachment(name: (base.isEmpty ? "image" : base) + ".jpg",
                                mime: "image/jpeg", data: data, thumbnail: resize(capped, maxEdge: 220))
    }

    static func fromFile(url: URL) -> PickedAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // Route picked images through the compressor too.
        if mime.hasPrefix("image/"), let img = UIImage(data: data) {
            return fromImage(img, name: url.lastPathComponent)
        }
        return PickedAttachment(name: url.lastPathComponent, mime: mime, data: data, thumbnail: nil)
    }

    private static func resize(_ img: UIImage, maxEdge: CGFloat) -> UIImage {
        let m = max(img.size.width, img.size.height)
        guard m > maxEdge, m > 0 else { return img }
        let s = maxEdge / m
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Chunk-uploads attachments over the encrypted relay channel and awaits vibTTY's
/// per-attachment assembly ack. Chunks are 64KB (well under the relay's 8MB frame
/// cap + token bucket); every payload is SHA-256 verified on the far side before it
/// lands as a file. Returns the ids to hand to `sendMessage`, or throws so the
/// caller can surface the failure instead of sending a message with missing files.
@MainActor
enum AttachmentUploader {
    static let chunkSize = 64 * 1024

    enum Failure: LocalizedError {
        case failed(String, String), timeout
        var errorDescription: String? {
            switch self {
            case let .failed(name, e): return "\(name) — \(e)"
            case .timeout: return "upload timed out"
            }
        }
    }

    static func upload(_ items: [PickedAttachment], session: String, via relay: RelayClient) async throws -> [String] {
        for a in items {
            let sha = SHA256.hash(data: a.data).map { String(format: "%02x", $0) }.joined()
            let total = max(1, Int((Double(a.data.count) / Double(chunkSize)).rounded(.up)))
            relay.announceAttachment(id: a.id, session: session, name: a.name, mime: a.mime,
                                     size: a.data.count, sha: sha, total: total)
            for seq in 0 ..< total {
                let lo = seq * chunkSize, hi = min(lo + chunkSize, a.data.count)
                relay.sendChunk(id: a.id, seq: seq, base64: a.data.subdata(in: lo ..< hi).base64EncodedString())
                if seq % 8 == 7 { try? await Task.sleep(nanoseconds: 25_000_000) }   // pace the token bucket
            }
        }
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            var allDone = true
            for a in items {
                switch relay.attachStates[a.id] {
                case .complete: continue
                case let .failed(e): throw Failure.failed(a.name, e)
                default: allDone = false
                }
            }
            if allDone {
                items.forEach { relay.clearAttachState($0.id) }
                return items.map(\.id)
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        throw Failure.timeout
    }
}
