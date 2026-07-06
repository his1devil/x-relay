import SwiftUI
import PhotosUI

/// Minimal profile editor (mature-IM pattern, nothing more): tap the big
/// avatar to pick a photo, type a nickname, Done. Shown from the rail's
/// user footer.
struct ProfileSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profile = ProfileStore.shared
    @State private var pickedItem: PhotosPickerItem?
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        UserAvatar(size: 96)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(theme.blurple, in: Circle())
                            .overlay(Circle().stroke(theme.screen, lineWidth: 2.5))
                    }
                }
                .buttonStyle(PressableStyle())

                VStack(alignment: .leading, spacing: 7) {
                    Text("NICKNAME")
                        .font(AppFont.mono(10.5, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(theme.faint)
                    TextField("You", text: $name)
                        .textFieldStyle(.plain)
                        .font(AppFont.sans(16, .semibold))
                        .foregroundStyle(theme.ink)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 24)

                Text("Shown next to your messages on this device. Never sent to the agent.")
                    .font(AppFont.sans(12))
                    .foregroundStyle(theme.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()
            }
            .padding(.top, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.screen)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.blurple)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.screen)
        .onAppear { name = profile.nickname }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    profile.setAvatar(from: img)
                    Haptics.success()
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.nickname = trimmed.isEmpty ? "You" : trimmed
        dismiss()
    }
}
