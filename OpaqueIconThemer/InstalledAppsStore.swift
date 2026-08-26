import Foundation
import UIKit
import FamilyControls

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
        status = "Запрашиваю доступ к использованию приложений…"

        Task { @MainActor [weak self] in
            guard let self else { return }

            var familyCount = 0
            var familyStatus = "Screen Time API недоступен"

            if #available(iOS 26.4, *) {
                do {
                    if AuthorizationCenter.shared.authorizationStatus == .notDetermined {
                        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                    }

                    let auth = AuthorizationCenter.shared.authorizationStatus
                    if auth == .approvedWithDataAccess {
                        status = "Читаю список через разрешение «Использование приложений»…"
                        let installed = try await FamilyActivityData.shared.installedApplications

                        var bundleIDs: [String] = []
                        var seen = Set<String>()
                        for application in installed {
                            guard let bundleID = application.bundleIdentifier,
                                  Self.looksLikeBundleIdentifier(bundleID) else { continue }
                            let key = bundleID.lowercased()
                            guard seen.insert(key).inserted else { continue }
                            bundleIDs.append(bundleID)
                        }

                        familyCount = bundleIDs.count
                        familyStatus = "Screen Time:\(familyCount)"

                        for bundleID in bundleIDs {
                            merge(InstalledAppInfo(
                                bundleIdentifier: bundleID,
                                displayName: bundleID,
                                icon: nil
                            ))
                        }

                        if !bundleIDs.isEmpty {
                            enrichFamilyApps(bundleIDs)
                        }
                    } else {
                        familyStatus = "Screen Time: \(String(describing: auth))"
                    }
                } catch {
                    familyStatus = "Screen Time error: \(error.localizedDescription)"
                }
            } else {
                familyStatus = "Screen Time list требует iOS 26.4+"
            }

            status = familyCount > 0
                ? "Получено по разрешению: \(familyCount). Дополняю названия и иконки…"
                : "\(familyStatus). Проверяю запасные способы…"

            runNativeScanOffMainThread(familyStatus: familyStatus)
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

    private func enrichFamilyApps(_ bundleIDs: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var enriched: [InstalledAppInfo] = []
            for bundleID in bundleIDs {
                guard let raw = OITPrivateAppScanner.installedApplication(forBundleIdentifier: bundleID) else { continue }
                enriched.append(InstalledAppInfo(
                    bundleIdentifier: raw.bundleIdentifier,
                    displayName: raw.displayName,
                    icon: raw.icon
                ))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for app in enriched {
                    self.merge(app)
                }
            }
        }
    }

    private func runNativeScanOffMainThread(familyStatus: String) {
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
                    self.status = "\(familyStatus) · \(primaryStatus) · \(deepStatus)"
                } else {
                    self.status = "Найдено: \(self.apps.count) · \(familyStatus) · \(deepStatus)"
                }
                self.scanning = false
                self.scheduleDirectBundleLookup()
            }
        }
    }

    private func scheduleDirectBundleLookup() {
        directLookupTask?.cancel()

        let query = trimmedSearch
        guard Self.looksLikeBundleIdentifier(query) else { return }

        directLookupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, let self else { return }
            self.resolveBundleID(query)
        }
    }

    private func resolveBundleID(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeBundleIdentifier(normalized) else { return }

        if apps.contains(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            status = "Найдено в списке: \(normalized)"
            return
        }

        status = "Ищу \(normalized)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = OITPrivateAppScanner.installedApplication(forBundleIdentifier: normalized)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.trimmedSearch.caseInsensitiveCompare(normalized) == .orderedSame else { return }

                guard let raw else {
                    self.status = "\(normalized) не найден прямым lookup. Если разрешение Screen Time выдано, ищи его в полном списке."
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
