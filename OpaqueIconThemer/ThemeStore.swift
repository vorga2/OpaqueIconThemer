import Foundation
import UIKit

@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var theme: [String: Data] = [:]
    @Published private(set) var bridgeReady = false
    @Published private(set) var bridgeStatus = "Проверка…"
    @Published private(set) var busy = false
    @Published var log: String?

    private let bridge = SpringBoardBridgeClient.shared

    var bundleIDs: [String] { theme.keys.sorted() }
    var iconCount: Int { theme.count }

    init() { loadDraft() }

    func refresh() {
        bridgeReady = bridge.ping()
        bridgeStatus = bridgeReady ? bridge.status() : "Bridge не загружен в SpringBoard"
    }

    func preview(_ id: String) -> UIImage? {
        guard let data = theme[id] else { return nil }
        return UIImage(data: data)
    }

    func importFolder(_ result: Result<[URL], Error>) {
        do {
            guard let folder = try result.get().first else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

            let files = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            var loaded: [String: Data] = [:]
            for file in files where file.pathExtension.lowercased() == "png" {
                let id = file.deletingPathExtension().lastPathComponent
                guard Self.validBundleID(id) else { continue }
                let data = try Data(contentsOf: file)
                guard data.count <= 2_000_000, UIImage(data: data) != nil else { continue }
                loaded[id] = data
            }

            theme = loaded
            saveDraft()
            log = "Импортировано \(loaded.count) иконок."
        } catch {
            log = error.localizedDescription
        }
    }

    func apply() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            log = try bridge.apply(theme)
        } catch {
            log = error.localizedDescription
        }
        refresh()
    }

    func clear() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            log = try bridge.clear()
        } catch {
            log = error.localizedDescription
        }
        refresh()
    }

    private static func validBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { ch in
                ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
            }
        }
    }

    private var draftURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ThemeDraft.plist")
    }

    private func saveDraft() {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: theme,
            format: .binary,
            options: 0
        ) else { return }
        try? data.write(to: draftURL, options: .atomic)
    }

    private func loadDraft() {
        guard let data = try? Data(contentsOf: draftURL),
              let obj = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dict = obj as? [String: Data] else { return }
        theme = dict
    }
}
