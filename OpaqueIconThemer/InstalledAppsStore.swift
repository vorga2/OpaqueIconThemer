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

    var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBundleIDSearch: Bool {
        Self.looksLikeBundleIdentifier(trimmedSearch)
    }

    var filteredApps: [InstalledAppInfo] {
        let query = trimmedSearch
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

        Task { @MainActor [weak self] in
            guard let self else { return }

            if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                status = "Жду системное разрешение…"
                _ = await ATTrackingManager.requestTrackingAuthorization()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            status = "Проверяю все доступные источники внутри iPhone…"
            runNativeScanOffMainThread()
        }
    }

    func lookupSearchNow() {
        directLookupTask?.cancel()
        let query = trimmedSearch
        guard Self.looksLikeBundleIdentifier(query) else {
            status = "Для прямого поиска введи полный bundle ID, например com.apple.Preferences"
            return
        }
        resolveBundleID(query)
    }

    private func runNativeScanOffMainThread() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let primaryRaw = OITPrivateAppScanner.installedApplications()
            let primaryStatus = OITPrivateAppScanner.scanStatus()

            let deepRaw = OITOnDeviceAppDiscovery.discoverApplications()
            let deepStatus = OITOnDeviceAppDiscovery.status()

            var merged: [String: InstalledAppInfo] = [:]
            for raw in primaryRaw + deepRaw {
                let candidate = InstalledAppInfo(
                    bundleIdentifier: raw.bundleIdentifier,
                    displayName: raw.displayName,
                    icon: raw.icon
                )

                if let existing = merged[candidate.bundleIdentifier] {
                    let existingHasUsefulName = existing.displayName != existing.bundleIdentifier
                    let candidateHasUsefulName = candidate.displayName != candidate.bundleIdentifier
                    merged[candidate.bundleIdentifier] = InstalledAppInfo(
                        bundleIdentifier: candidate.bundleIdentifier,
                        displayName: (!existingHasUsefulName && candidateHasUsefulName) ? candidate.displayName : existing.displayName,
                        icon: existing.icon ?? candidate.icon
                    )
                } else {
                    merged[candidate.bundleIdentifier] = candidate
                }
            }

            let discovered = merged.values.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                for app in discovered {
                    self.merge(app)
                }

                if self.apps.isEmpty {
                    self.status = "\(primaryStatus) · \(deepStatus)"
                } else {
                    self.status = "Найдено: \(self.apps.count) · \(deepStatus)"
                }
                self.scanning = false

                // Search may have changed while the slow native scan was running.
                self.scheduleDirectBundleLookup()
            }
        }
    }

    private func scheduleDirectBundleLookup() {
        directLookupTask?.cancel()

        let query = trimmedSearch
        guard Self.looksLikeBundleIdentifier(query) else { return }

        directLookupTask = Task { @MainActor [weak self] in
            // Short debounce: enough to avoid probing every keystroke, but feels instant.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, let self else { return }
            self.resolveBundleID(query)
        }
    }

    private func resolveBundleID(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeBundleIdentifier(normalized) else { return }

        status = "Ищу \(normalized)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = OITPrivateAppScanner.installedApplication(forBundleIdentifier: normalized)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Ignore an old lookup if the user has already typed another bundle ID.
                guard self.trimmedSearch.caseInsensitiveCompare(normalized) == .orderedSame else { return }

                guard let raw else {
                    self.status = "Прямой lookup \(normalized) ничего не вернул — iOS фильтрует этот запрос"
                    return
                }

                let item = InstalledAppInfo(
                    bundleIdentifier: raw.bundleIdentifier,
                    displayName: raw.displayName,
                    icon: raw.icon
                )
                self.merge(item)
                self.status = "Найдено напрямую: \(item.bundleIdentifier)"
            }
        }
    }

    private func merge(_ candidate: InstalledAppInfo) {
        if let index = apps.firstIndex(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(candidate.bundleIdentifier) == .orderedSame
        }) {
            let existing = apps[index]
            let existingHasUsefulName = existing.displayName != existing.bundleIdentifier
            let candidateHasUsefulName = candidate.displayName != candidate.bundleIdentifier
            apps[index] = InstalledAppInfo(
                bundleIdentifier: existing.bundleIdentifier,
                displayName: (!existingHasUsefulName && candidateHasUsefulName) ? candidate.displayName : existing.displayName,
                icon: existing.icon ?? candidate.icon
            )
        } else {
            apps.append(candidate)
        }

        apps.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func looksLikeBundleIdentifier(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 4,
              value.contains("."),
              !value.contains(" "),
              !value.contains("/") else {
            return false
        }
        return true
    }
}
