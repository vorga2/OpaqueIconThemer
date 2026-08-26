import SwiftUI

@main
struct OpaqueIconThemerApp: App {
    @StateObject private var store = ThemeStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
    }
}
