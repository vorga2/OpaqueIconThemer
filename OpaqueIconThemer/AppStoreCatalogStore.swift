import Foundation
import UIKit

@MainActor
final class AppStoreCatalogStore: ObservableObject {
    @Published var search = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var featured: [InstalledAppInfo] = []
    @Published private(set) var results: [InstalledAppInfo] = []
    @Published private(set) var loading = false
    @Published private(set) var status = ""

    private var searchTask: Task<Void, Never>?
    private var featuredLoaded = false

    var displayedApps: [InstalledAppInfo] {
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? featured : results
    }

    private struct SearchResponse: Decodable {
        let resultCount: Int
        let results: [SearchItem]
    }

    private struct SearchItem: Decodable {
        let bundleId: String?
        let trackName: String?
        let artworkUrl512: String?
        let artworkUrl100: String?
    }

    // Stable, well-known App Store apps shown before the user types anything.
    // Artwork/name are resolved live from Apple's catalog, so no third-party icons are bundled.
    private static let featuredSeeds: [(bundleID: String, fallbackName: String)] = [
        ("ph.telegra.Telegraph", "Telegram"),
        ("com.google.ios.youtube", "YouTube"),
        ("com.zhiliaoapp.musically", "TikTok"),
        ("com.burbn.instagram", "Instagram"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.hammerandchisel.discord", "Discord"),
        ("com.spotify.client", "Spotify"),
        ("com.reddit.Reddit", "Reddit"),
        ("com.google.chrome.ios", "Chrome"),
        ("com.google.Gmail", "Gmail")
    ]

    func loadFeaturedIfNeeded() {
        guard !featuredLoaded else { return }
        featuredLoaded = true
        loading = true
        status = "Загружаю популярные приложения…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            var loaded: [InstalledAppInfo] = []

            for seed in Self.featuredSeeds {
                if Task.isCancelled { return }
                let item = await AppStoreArtworkProvider.shared.lookup(bundleIdentifier: seed.bundleID)
                if item.displayName != nil || item.image != nil {
                    loaded.append(
                        InstalledAppInfo(
                            bundleIdentifier: seed.bundleID,
                            displayName: item.displayName ?? seed.fallbackName,
                            icon: item.image,
                            applicationToken: nil
                        )
                    )
                }
            }

            featured = loaded
            loading = false
            status = loaded.isEmpty
                ? "Не удалось получить каталог App Store. Проверь интернет."
                : "Можно выбрать готовое приложение или найти другое по названию."
        }
    }

    func searchNow() {
        searchTask?.cancel()
        performSearch(query: search.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            results = []
            status = featured.isEmpty ? "" : "Можно выбрать готовое приложение или найти другое по названию."
            return
        }

        guard query.count >= 2 else {
            results = []
            status = "Введи хотя бы 2 символа."
            return
        }

        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.performSearch(query: query)
        }
    }

    private func performSearch(query: String) {
        guard query.count >= 2 else { return }
        loading = true
        status = "Ищу «\(query)» в App Store…"

        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let apps = await Self.fetchApps(term: query)
            guard !Task.isCancelled else { return }
            results = apps
            loading = false
            status = apps.isEmpty
                ? "В App Store ничего не найдено."
                : "Найдено: \(apps.count). Для запуска через Команду приложение должно быть установлено."
        }
    }

    private static func fetchApps(term: String) async -> [InstalledAppInfo] {
        let currentRegion = Locale.current.region?.identifier.lowercased() ?? "us"
        let regions = currentRegion == "us" ? ["us"] : [currentRegion, "us"]

        for region in regions {
            guard var components = URLComponents(string: "https://itunes.apple.com/search") else { continue }
            components.queryItems = [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "country", value: region),
                URLQueryItem(name: "entity", value: "software"),
                URLQueryItem(name: "limit", value: "24")
            ]
            guard let url = components.url else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                request.cachePolicy = .returnCacheDataElseLoad
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }

                let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
                var output: [InstalledAppInfo] = []

                // Keep this sequential: InstalledAppInfo contains UIImage/ApplicationToken and is
                // intentionally not Sendable. This avoids Swift 6 strict-concurrency violations.
                for item in decoded.results.prefix(24) {
                    if Task.isCancelled { return [] }
                    guard let bundleID = item.bundleId,
                          let name = item.trackName,
                          !bundleID.isEmpty,
                          !name.isEmpty else { continue }

                    let image = await fetchArtwork(item.artworkUrl512 ?? item.artworkUrl100)
                    output.append(
                        InstalledAppInfo(
                            bundleIdentifier: bundleID,
                            displayName: name,
                            icon: image,
                            applicationToken: nil
                        )
                    )
                }

                if !output.isEmpty { return output }
            } catch {
                continue
            }
        }
        return []
    }

    private nonisolated static func fetchArtwork(_ value: String?) async -> UIImage? {
        guard let value else { return nil }
        let upgraded: String
        if let regex = try? NSRegularExpression(pattern: "[0-9]+x[0-9]+bb") {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            upgraded = regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: "512x512bb"
            )
        } else {
            upgraded = value
        }

        guard let url = URL(string: upgraded) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
