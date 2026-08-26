import Foundation
import UIKit
import AppTrackingTransparency

struct InstalledAppInfo: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    let icon: UIImage?

    var id: String { bundleIdentifier }

    static func == (lhs: InstalledAppInfo, rhs: InstalledAppInfo) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }
}

@MainActor
final class InstalledAppsStore: ObservableObject {
    @Published private(set) var apps: [InstalledAppInfo] = []
    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    @Published var search = ""

    var filteredApps: [InstalledAppInfo] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        status = "Сканирую локально…"

        Task { @MainActor in
            if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                status = "Жду системное разрешение…"
                _ = await ATTrackingManager.requestTrackingAuthorization()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            status = "Проверяю LaunchServices…"
            await Task.yield()

            let raw = OITPrivateAppScanner.installedApplications()
            apps = raw.map {
                InstalledAppInfo(
                    bundleIdentifier: $0.bundleIdentifier,
                    displayName: $0.displayName,
                    icon: $0.icon
                )
            }
            status = OITPrivateAppScanner.scanStatus()
            scanning = false
        }
    }
}
