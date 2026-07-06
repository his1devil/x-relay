import SwiftUI
import UIKit

/// The user's local identity: a nickname and an avatar, shown on every message
/// they send (Discord-style author header). Stored locally — the agent side
/// never sees it, so nothing ships over the relay.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var nickname: String {
        didSet { UserDefaults.standard.set(nickname, forKey: "cr.profile.nickname") }
    }
    @Published var avatar: UIImage? {
        didSet {
            if let data = avatar?.jpegData(compressionQuality: 0.85) {
                UserDefaults.standard.set(data, forKey: "cr.profile.avatar")
            } else {
                UserDefaults.standard.removeObject(forKey: "cr.profile.avatar")
            }
        }
    }

    private init() {
        nickname = UserDefaults.standard.string(forKey: "cr.profile.nickname") ?? "You"
        if let data = UserDefaults.standard.data(forKey: "cr.profile.avatar") {
            avatar = UIImage(data: data)
        }
    }

    /// Downscale + center-crop a picked photo to a small square before storing.
    func setAvatar(from image: UIImage) {
        let side: CGFloat = 160
        let scale = max(side / image.size.width, side / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        avatar = renderer.image { _ in
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
    }
}

/// Circular avatar for the user: the picked photo, or an initial on a tinted
/// disc as the default (the pattern every IM falls back to).
struct UserAvatar: View {
    @ObservedObject var profile = ProfileStore.shared
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let img = profile.avatar {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(hex: 0x5865F2))
                    Text(String(profile.nickname.prefix(1)).uppercased())
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
