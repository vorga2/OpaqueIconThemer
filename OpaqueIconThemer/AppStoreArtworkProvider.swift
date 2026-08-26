import Foundation
import UIKit

actor AppStoreArtworkProvider {
    static let shared = AppStoreArtworkProvider()

    struct Result {
        let displayName: String?
        let image: UIImage?
    }

    private struct LookupResponse: Decodable {
        let resultCount: Int
        let results: [LookupItem]
    }

    private struct LookupItem: Decodable {
        let trackName: String?
        let artworkUrl512: String?
        let artworkUrl100: String?
    }

    private var cache: [String: Result] = [:]

    func lookup(bundleIdentifier: String) async -> Result {
        let key = bundleIdentifier.lowercased()
        if let cached = cache[key] {
            return cached
        }

        let currentRegion = Locale.current.region?.identifier ?? "US"
        let regions = currentRegion.uppercased() == "US" ? ["US"] : [currentRegion, "US"]

        for region in regions {
            if let result = await lookup(bundleIdentifier: bundleIdentifier, region: region),
               result.displayName != nil || result.image != nil {
                cache[key] = result
                return result
            }
        }

        let empty = Result(displayName: nil, image: nil)
        cache[key] = empty
        return empty
    }

    private func lookup(bundleIdentifier: String, region: String) async -> Result? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "country", value: region.lowercased()),
            URLQueryItem(name: "entity", value: "software")
        ]

        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.cachePolicy = .returnCacheDataElseLoad

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
            guard decoded.resultCount > 0, let item = decoded.results.first else { return nil }

            let artworkString = item.artworkUrl512 ?? item.artworkUrl100
            var image: UIImage?

            if let artworkString,
               let artworkURL = highResolutionArtworkURL(from: artworkString) {
                var artworkRequest = URLRequest(url: artworkURL)
                artworkRequest.timeoutInterval = 10
                artworkRequest.cachePolicy = .returnCacheDataElseLoad
                let (artworkData, artworkResponse) = try await URLSession.shared.data(for: artworkRequest)
                if let http = artworkResponse as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    image = UIImage(data: artworkData)
                }
            }

            return Result(displayName: item.trackName, image: image)
        } catch {
            return nil
        }
    }

    private func highResolutionArtworkURL(from value: String) -> URL? {
        // Apple artwork CDN URLs normally contain a size token such as 512x512bb.
        // 512 px is already more than enough for a Home Screen icon and avoids
        // blowing up memory when many installed apps are shown at once.
        guard let regex = try? NSRegularExpression(pattern: "[0-9]+x[0-9]+bb") else {
            return URL(string: value)
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let upgraded = regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: "512x512bb"
        )
        return URL(string: upgraded)
    }
}
