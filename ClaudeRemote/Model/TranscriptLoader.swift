import Foundation

/// Off-main loader that keeps a transcript's decoded records and a byte offset,
/// so live updates only decode the newly-appended bytes instead of re-reading
/// and re-parsing the whole (possibly multi-MB) file each time. Being an `actor`
/// keeps all file I/O + JSON decode off the main thread automatically.
actor TranscriptLoader {
    private let url: URL
    private let codex: Bool        // Codex rollout → CodexTranscript instead of TranscriptParser
    private var records: [RawRecord] = []   // Claude
    private var codexData = Data()           // Codex: accumulated complete-line bytes
    private var pending = Data()   // bytes after the last newline (a partial line)
    private var offset: UInt64 = 0

    init(url: URL, codex: Bool = false) { self.url = url; self.codex = codex }

    private func buildTimeline() -> ChatTimeline {
        codex ? CodexTranscript.timeline(from: codexData) : TranscriptParser.build(records).timeline
    }

    /// Bytes of tail to read for large transcripts — bounds the first parse so a
    /// multi-MB session opens instantly to its recent messages instead of reading
    /// (and building) the whole file. `appended()` then live-tails from EOF.
    private let tailCap = 2_000_000

    /// First open: whole file when small, else just the tail.
    func initial() -> ChatTimeline {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil

        if let size, size > tailCap, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(size - tailCap))
            var data = (try? handle.readToEnd()) ?? Data()
            // The tail starts mid-line — drop the leading partial.
            if let nl = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: data.index(after: nl) ..< data.endIndex)
            }
            offset = UInt64(size)
            ingest(data)
        } else if let data = try? Data(contentsOf: url) {
            offset = UInt64(data.count)
            ingest(data)
        } else {
            return ChatTimeline(items: [])
        }
        return buildTimeline()
    }

    /// Read only what was appended since the last load; nil if nothing changed.
    func appended() -> ChatTimeline? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { return nil }
            offset += UInt64(data.count)
            ingest(data)
            return buildTimeline()
        } catch {
            return nil
        }
    }

    /// Append bytes, decode every complete line in bulk, retain the trailing
    /// partial line for next time.
    private func ingest(_ data: Data) {
        pending.append(data)
        guard let lastNL = pending.lastIndex(of: 0x0A) else { return }
        let cut = pending.index(after: lastNL)
        let complete = pending.subdata(in: pending.startIndex ..< cut)
        pending.removeSubrange(pending.startIndex ..< cut)
        if codex {
            codexData.append(complete)
        } else {
            records.append(contentsOf: TranscriptParser.decodeLines(complete))
        }
    }
}
