import Foundation
import CryptoKit

struct PairingInfo {
    let url: URL
    let room: String
    let key: SymmetricKey
}

/// AES-256-GCM matching the Node agent's envelope: `base64( iv[12] | tag[16] | ciphertext )`.
/// (CryptoKit's `combined` uses nonce|ciphertext|tag, so we lay bytes out by hand.)
enum RelayCrypto {
    static func parsePairing(_ string: String) -> PairingInfo? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outer = Data(base64Encoded: trimmed),
              let obj = try? JSONSerialization.jsonObject(with: outer) as? [String: Any],
              let urlStr = obj["url"] as? String, let url = URL(string: urlStr),
              let room = obj["room"] as? String,
              let keyB64 = obj["key"] as? String,
              let keyData = Data(base64Encoded: keyB64), keyData.count == 32
        else { return nil }
        return PairingInfo(url: url, room: room, key: SymmetricKey(data: keyData))
    }

    static func decrypt(_ b64: String, key: SymmetricKey) -> Data? {
        guard let buf = Data(base64Encoded: b64), buf.count > 28 else { return nil }
        let iv = buf.subdata(in: 0 ..< 12)
        let tag = buf.subdata(in: 12 ..< 28)
        let ct = buf.subdata(in: 28 ..< buf.count)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }

    static func encrypt(_ data: Data, key: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.seal(data, using: key) else { return nil }
        var out = Data(box.nonce)
        out.append(box.tag)
        out.append(box.ciphertext)
        return out.base64EncodedString()
    }
}
