import SwiftUI

@main
struct ClaudeRemoteApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var themeController = ThemeController()
    @StateObject private var hub = RelayHub()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(themeController)
                .environmentObject(hub)
        }
    }
}
