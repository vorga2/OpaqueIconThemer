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

    func importFiles(_ result: Result<[URL], Error>) {
        do {
            let files = try result.get()
            guard !files.isEmpty else { return }

            var updated = theme
            var imported = 0
            var skipped: [String] = []

            for file in files {
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }

                guard file.pathExtension.lowercased() == "png" else {
                    skipped.append(file.lastPathComponent)
                    continue
                }

                let bundleID = file.deletingPathExtension().lastPathComponent
                guard Self.validBundleID(bundleID) else {
                    skipped.append(file.lastPathComponent + " — имя не похоже на bundle ID")
                    continue
                }

                let data = try Data(contentsOf: file)
                guard data.count <= 2_000_000,
                      let image = UIImage(data: data),
                      image.size.width >= 32,
                      image.size.height >= 32 else {
                    skipped.append(file.lastPathComponent + " — PNG не читается")
                    continue
                }

                updated[bundleID] = data
                imported += 1
            }

            theme = updated
            saveDraft()

            if skipped.isEmpty {
                log = "Импортировано \(imported) иконок."
            } else {
                log = "Импортировано \(imported). Пропущено \(skipped.count):\n" + skipped.joined(separator: "\n")
            }
        } catch {
            log = error.localizedDescription
        }
    }

    func remove(_ bundleID: String) {
        theme.removeValue(forKey: bundleID)
        saveDraft()
        log = "Удалено из темы: \(bundleID)"
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
