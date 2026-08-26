import SwiftUI
import AppTrackingTransparency

@main
struct OpaqueIconThemerApp: App {
    @StateObject private var store = ThemeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    _ = await ATTrackingManager.requestTrackingAuthorization()
                }
        }
    }
}
