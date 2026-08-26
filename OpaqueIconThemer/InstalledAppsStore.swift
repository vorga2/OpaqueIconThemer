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
    @Published var search = "" {
        didSet {
            scheduleDirectBundleLookup()
        }
    }

    private var directLookupTask: Task<Void, Never>?

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

            status = "Проверяю LaunchServices, MobileInstallation и app-каталоги…"
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

            if apps.isEmpty {
                scheduleDirectBundleLookup()
            }
        }
    }

    private func scheduleDirectBundleLookup() {
        directLookupTask?.cancel()

        guard !scanning, apps.isEmpty else { return }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 4, query.contains("."), !query.contains(" ") else { return }

        directLookupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.resolveBundleID(query)
        }
    }

    private func resolveBundleID(_ query: String) {
        guard let raw = OITPrivateAppScanner.installedApplication(forBundleIdentifier: query) else {
            status = "Массовый список закрыт; прямой lookup \(query) тоже ничего не вернул"
            return
        }

        let item = InstalledAppInfo(
            bundleIdentifier: raw.bundleIdentifier,
            displayName: raw.displayName,
            icon: raw.icon
        )
        apps = [item]
        status = "Найдено напрямую: \(item.bundleIdentifier)"
    }
}
