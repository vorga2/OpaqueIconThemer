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
    private var featuredTask: Task<Void, Never>?
    private var featuredLoaded = false
    private var searchGeneration = 0

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

    private struct LookupResponse: Decodable {
        let resultCount: Int
        let results: [SearchItem]
    }

    private struct CatalogMetadata: Sendable {
        let bundleID: String
        let displayName: String
        let thumbnailURL: String?
    }

    // Stable, well-known apps shown before the user types anything. Only bundle IDs/names are
    // shipped; current names and artwork are resolved live from Apple's public catalog.
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
        featuredTask?.cancel()
        loading = true
        status = "Загружаю популярные приложения…"

        featuredTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let metadata = await Self.fetchFeaturedMetadata()
            guard !Task.isCancelled else { return }

            // Publish rows BEFORE any artwork download. The list becomes usable immediately.
            featured = metadata.map {
                InstalledAppInfo(
                    bundleIdentifier: $0.bundleID,
                    displayName: $0.displayName,
                    icon: nil,
                    applicationToken: nil
                )
            }
            loading = false
            status = metadata.isEmpty
                ? "Не удалось получить каталог App Store. Проверь интернет."
                : "Готовые приложения загружены. Иконки догружаются параллельно."

            await loadThumbnails(metadata, intoFeatured: true, generation: 0)
            guard !Task.isCancelled else { return }
            if !featured.isEmpty {
                status = "Можно выбрать готовое приложение или найти другое по названию."
            }
        }
    }

    func searchNow() {
        searchTask?.cancel()
        performSearch(query: search.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            results = []
            loading = false
            status = featured.isEmpty ? "" : "Можно выбрать готовое приложение или найти другое по названию."
            return
        }

        guard query.count >= 2 else {
            results = []
            loading = false
            status = "Введи хотя бы 2 символа."
            return
        }

        let generation = searchGeneration
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.performSearch(query: query, generation: generation)
        }
    }

    private func performSearch(query: String, generation: Int? = nil) {
        guard query.count >= 2 else { return }
        let activeGeneration = generation ?? {
            searchGeneration += 1
            return searchGeneration
        }()

        searchTask?.cancel()
        loading = true
        status = "Ищу «\(query)» в App Store…"

        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let metadata = await Self.fetchSearchMetadata(term: query)
            guard !Task.isCancelled, activeGeneration == searchGeneration else { return }

            // Names/rows appear as soon as the tiny JSON search response arrives. We deliberately
            // do NOT wait for 24 image requests before rendering the list.
            results = metadata.map {
                InstalledAppInfo(
                    bundleIdentifier: $0.bundleID,
                    displayName: $0.displayName,
                    icon: nil,
                    applicationToken: nil
                )
            }
            loading = false
            status = metadata.isEmpty
                ? "В App Store ничего не найдено."
                : "Найдено: \(metadata.count). Иконки загружаются параллельно…"

            await loadThumbnails(metadata, intoFeatured: false, generation: activeGeneration)
            guard !Task.isCancelled, activeGeneration == searchGeneration else { return }
            if !results.isEmpty {
                status = "Найдено: \(results.count). Для запуска через Команду приложение должно быть установлено."
            }
        }
    }

    private func loadThumbnails(
        _ metadata: [CatalogMetadata],
        intoFeatured: Bool,
        generation: Int
    ) async {
        // artworkUrl100 is intentionally used for list rows: it is tiny and visually sufficient at
        // 50 pt. Full 512px artwork is fetched only after opening an app in the editor.
        await withTaskGroup(of: (String, Data?).self) { group in
            for item in metadata {
                group.addTask {
                    let data = await Self.fetchArtworkData(item.thumbnailURL)
                    return (item.bundleID, data)
                }
            }

            for await (bundleID, data) in group {
                if Task.isCancelled { group.cancelAll(); return }
                if !intoFeatured && generation != searchGeneration {
                    group.cancelAll()
                    return
                }
                guard let data, let image = UIImage(data: data) else { continue }

                if intoFeatured {
                    guard let index = featured.firstIndex(where: {
                        $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
                    }) else { continue }
                    let old = featured[index]
                    featured[index] = InstalledAppInfo(
                        bundleIdentifier: old.bundleIdentifier,
                        displayName: old.displayName,
                        icon: image,
                        applicationToken: old.applicationToken
                    )
                } else {
                    guard let index = results.firstIndex(where: {
                        $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
                    }) else { continue }
                    let old = results[index]
                    results[index] = InstalledAppInfo(
                        bundleIdentifier: old.bundleIdentifier,
                        displayName: old.displayName,
                        icon: image,
                        applicationToken: old.applicationToken
                    )
                }
            }
        }
    }

    private nonisolated static func fetchFeaturedMetadata() async -> [CatalogMetadata] {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        return await withTaskGroup(of: (Int, CatalogMetadata?).self, returning: [CatalogMetadata].self) { group in
            for (index, seed) in featuredSeeds.enumerated() {
                group.addTask {
                    let item = await lookupMetadata(
                        bundleID: seed.bundleID,
                        fallbackName: seed.fallbackName,
                        region: region
                    )
                    return (index, item)
                }
            }

            var indexed: [(Int, CatalogMetadata)] = []
            for await (index, item) in group {
                if let item { indexed.append((index, item)) }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private nonisolated static func lookupMetadata(
        bundleID: String,
        fallbackName: String,
        region: String
    ) async -> CatalogMetadata? {
        let regions = region == "us" ? ["us"] : [region, "us"]
        for region in regions {
            guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { continue }
            components.queryItems = [
                URLQueryItem(name: "bundleId", value: bundleID),
                URLQueryItem(name: "country", value: region),
                URLQueryItem(name: "entity", value: "software")
            ]
            guard let url = components.url else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 6
                request.cachePolicy = .returnCacheDataElseLoad
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }
                let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
                if let item = decoded.results.first {
                    return CatalogMetadata(
                        bundleID: item.bundleId ?? bundleID,
                        displayName: item.trackName ?? fallbackName,
                        thumbnailURL: item.artworkUrl100 ?? item.artworkUrl512
                    )
                }
            } catch {
                continue
            }
        }

        // Keep the ready card even if one catalog lookup fails temporarily.
        return CatalogMetadata(bundleID: bundleID, displayName: fallbackName, thumbnailURL: nil)
    }

    private nonisolated static func fetchSearchMetadata(term: String) async -> [CatalogMetadata] {
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
                request.timeoutInterval = 8
                request.cachePolicy = .returnCacheDataElseLoad
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { continue }

                let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
                let output = decoded.results.prefix(24).compactMap { item -> CatalogMetadata? in
                    guard let bundleID = item.bundleId,
                          let name = item.trackName,
                          !bundleID.isEmpty,
                          !name.isEmpty else { return nil }
                    return CatalogMetadata(
                        bundleID: bundleID,
                        displayName: name,
                        thumbnailURL: item.artworkUrl100 ?? item.artworkUrl512
                    )
                }
                if !output.isEmpty { return output }
            } catch {
                continue
            }
        }
        return []
    }

    private nonisolated static func fetchArtworkData(_ value: String?) async -> Data? {
        guard let value, let url = URL(string: value) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
