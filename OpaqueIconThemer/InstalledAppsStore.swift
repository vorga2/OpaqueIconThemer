import Foundation
import UIKit
import SwiftUI
import FamilyControls
import ManagedSettings

struct InstalledAppInfo: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    let icon: UIImage?
    let applicationToken: ApplicationToken?

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
    private var screenTimeUnavailableForSession = false

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
        status = "Проверяю доступные способы определения приложений…"

        Task { @MainActor [weak self] in
            guard let self else { return }

            var familyCount = 0
            var familyStatus = "Screen Time API недоступен"
            var familyBundleIDs: [String] = []

            if !screenTimeUnavailableForSession {
                if #available(iOS 26.4, *) {
                    do {
                        if AuthorizationCenter.shared.authorizationStatus == .notDetermined {
                            status = "Запрашиваю доступ к использованию приложений…"
                            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                        }

                        let auth = AuthorizationCenter.shared.authorizationStatus
                        if auth == .approvedWithDataAccess {
                            status = "Читаю приложения через разрешение «Использование приложений»…"
                            let installed = try await FamilyActivityData.shared.installedApplications

                            var seen = Set<String>()

                            for application in installed {
                                guard let bundleID = application.bundleIdentifier,
                                      Self.looksLikeBundleIdentifier(bundleID) else { continue }

                                let key = bundleID.lowercased()
                                guard seen.insert(key).inserted else { continue }
                                familyBundleIDs.append(bundleID)

                                // Keep every app Screen Time reports. No App Store-only filter:
                                // development, sideloaded and custom apps remain in the list too.
                                let token = application.token
                                let tokenIcon = token.flatMap { Self.renderTokenIcon($0) }

                                merge(InstalledAppInfo(
                                    bundleIdentifier: bundleID,
                                    displayName: bundleID,
                                    icon: tokenIcon,
                                    applicationToken: token
                                ))
                            }

                            familyCount = familyBundleIDs.count
                            familyStatus = "Screen Time:\(familyCount)"

                            if !familyBundleIDs.isEmpty {
                                enrichFamilyApps(familyBundleIDs)
                                enrichAppStoreApps(familyBundleIDs)
                            }
                        } else {
                            familyStatus = "Screen Time: \(String(describing: auth))"
                        }
                    } catch {
                        let message = error.localizedDescription
                        if message.localizedCaseInsensitiveContains("helper application") ||
                            message.localizedCaseInsensitiveContains("communicate with a helper") {
                            // This normally means the sideload provisioning profile did not
                            // grant Apple's restricted Family Controls data entitlement.
                            screenTimeUnavailableForSession = true
                            familyStatus = "Screen Time недоступен для текущей sideload-подписи"
                        } else {
                            familyStatus = "Screen Time error: \(message)"
                        }
                    }
                } else {
                    familyStatus = "Screen Time list требует iOS 26.4+"
                }
            } else {
                familyStatus = "Screen Time отключён на эту сессию: helper недоступен"
            }

            status = familyCount > 0
                ? "Получено по разрешению: \(familyCount). Проверяю названия и HD-иконки…"
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
                    icon: raw.icon,
                    applicationToken: nil
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

    private func enrichAppStoreApps(_ bundleIDs: [String]) {
        let uniqueBundleIDs = Array(Set(bundleIDs.map { $0.lowercased() }))

        Task { @MainActor [weak self] in
            guard let self else { return }

            for bundleID in uniqueBundleIDs {
                let result = await AppStoreArtworkProvider.shared.lookup(bundleIdentifier: bundleID)
                guard result.displayName != nil || result.image != nil else { continue }

                let existing = self.apps.first(where: {
                    $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
                })

                let canonicalBundleID = existing?.bundleIdentifier ?? bundleID
                let displayName = result.displayName ?? existing?.displayName ?? canonicalBundleID

                self.merge(
                    InstalledAppInfo(
                        bundleIdentifier: canonicalBundleID,
                        displayName: displayName,
                        icon: result.image,
                        applicationToken: existing?.applicationToken
                    ),
                    preferCandidateIcon: result.image != nil
                )
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
                    icon: raw.icon,
                    applicationToken: nil
                )

                let key = candidate.bundleIdentifier.lowercased()
                if let existing = merged[key] {
                    let existingHasUsefulName = existing.displayName != existing.bundleIdentifier
                    let candidateHasUsefulName = candidate.displayName != candidate.bundleIdentifier
                    merged[key] = InstalledAppInfo(
                        bundleIdentifier: candidate.bundleIdentifier,
                        displayName: (!existingHasUsefulName && candidateHasUsefulName) ? candidate.displayName : existing.displayName,
                        icon: Self.preferredIcon(existing.icon, candidate.icon),
                        applicationToken: existing.applicationToken ?? candidate.applicationToken
                    )
                } else {
                    merged[key] = candidate
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

                if !discovered.isEmpty {
                    self.enrichAppStoreApps(discovered.map(\.bundleIdentifier))
                }

                if self.apps.isEmpty {
                    self.status = "\(familyStatus) · \(primaryStatus) · \(deepStatus)"
                } else {
                    self.status = "Найдено: \(self.apps.count) · \(familyStatus) · HD-иконки App Store догружаются"
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
            enrichAppStoreApps([normalized])
            return
        }

        status = "Ищу \(normalized)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = OITPrivateAppScanner.installedApplication(forBundleIdentifier: normalized)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.trimmedSearch.caseInsensitiveCompare(normalized) == .orderedSame else { return }

                guard let raw else {
                    self.status = "\(normalized) не найден прямым lookup. Если это App Store-приложение, нужен список от Screen Time или другой источник bundle ID."
                    return
                }

                let item = InstalledAppInfo(
                    bundleIdentifier: raw.bundleIdentifier,
                    displayName: raw.displayName,
                    icon: raw.icon,
                    applicationToken: nil
                )
                self.merge(item)
                self.enrichAppStoreApps([item.bundleIdentifier])
                self.status = "Найдено напрямую: \(item.bundleIdentifier). Проверяю HD-иконку…"
            }
        }
    }

    private func merge(_ candidate: InstalledAppInfo, preferCandidateIcon: Bool = false) {
        if let index = apps.firstIndex(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(candidate.bundleIdentifier) == .orderedSame
        }) {
            let existing = apps[index]
            let existingHasUsefulName = existing.displayName != existing.bundleIdentifier
            let candidateHasUsefulName = candidate.displayName != candidate.bundleIdentifier

            let icon: UIImage?
            if preferCandidateIcon, let candidateIcon = candidate.icon {
                icon = candidateIcon
            } else {
                icon = Self.preferredIcon(existing.icon, candidate.icon)
            }

            apps[index] = InstalledAppInfo(
                bundleIdentifier: existing.bundleIdentifier,
                displayName: (!existingHasUsefulName && candidateHasUsefulName) ? candidate.displayName : existing.displayName,
                icon: icon,
                applicationToken: existing.applicationToken ?? candidate.applicationToken
            )
        } else {
            apps.append(candidate)
        }

        apps.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    @MainActor
    private static func renderTokenIcon(_ token: ApplicationToken) -> UIImage? {
        // The old 128pt token snapshot was visibly soft after the tint engine
        // enlarged it to 1024px. Render a 512px source instead.
        let view = Label(token)
            .labelStyle(.iconOnly)
            .frame(width: 256, height: 256)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage
    }

    private static func preferredIcon(_ first: UIImage?, _ second: UIImage?) -> UIImage? {
        guard let first else { return second }
        guard let second else { return first }
        return pixelCount(second) > pixelCount(first) ? second : first
    }

    private static func pixelCount(_ image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.width * cgImage.height
        }
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        return max(1, width * height)
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
