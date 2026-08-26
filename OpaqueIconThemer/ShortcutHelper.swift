import Foundation
import SwiftUI
import UIKit

@MainActor
final class ShortcutHelper: NSObject, ObservableObject, UIDocumentInteractionControllerDelegate {
    @Published var status: String?
    @Published var busy = false

    private var documentController: UIDocumentInteractionController?

    func generateReadyShortcut(_ image: UIImage, appName: String, bundleIdentifier: String) {
        guard !busy else { return }

        busy = true
        status = "Собираю готовую Команду…"

        Task {
            do {
                let fileURL = try await makeSignedShortcut(
                    icon: image,
                    appName: appName,
                    bundleIdentifier: bundleIdentifier
                )

                status = "Готово: внутри уже одно действие «Открыть приложение» и встроенная иконка. Открой файл через «Команды», импортируй его и нажми «На экран Домой»."
                presentShortcutFile(fileURL)
                busy = false
            } catch {
                busy = false
                status = "Не удалось создать Команду: \(error.localizedDescription)"
            }
        }
    }

    private func makeSignedShortcut(icon: UIImage, appName: String, bundleIdentifier: String) async throws -> URL {
        guard let iconData = icon.pngData() else {
            throw ShortcutError.iconEncodingFailed
        }

        let selectedApp: [String: Any] = [
            "BundleIdentifier": bundleIdentifier,
            "Name": appName
        ]

        let openAppAction: [String: Any] = [
            "WFWorkflowActionIdentifier": "is.workflow.actions.openapp",
            "WFWorkflowActionParameters": [
                "UUID": UUID().uuidString.uppercased(),
                "WFAppIdentifier": bundleIdentifier,
                "WFSelectedApp": selectedApp
            ]
        ]

        let workflow: [String: Any] = [
            "WFWorkflowClientVersion": "3107.0.8.2",
            "WFWorkflowClientRelease": "22.1",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowName": appName,
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": 2846468607,
                "WFWorkflowIconGlyphNumber": 59511,
                "WFWorkflowIconImageData": iconData
            ],
            "WFWorkflowImportQuestions": [],
            "WFWorkflowActions": [openAppAction],
            "WFWorkflowTypes": [],
            "WFQuickActionSurfaces": [],
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowInputContentItemClasses": ["WFAppStoreAppContentItem"]
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: workflow,
            format: .xml,
            options: 0
        )

        guard let plistString = String(data: plistData, encoding: .utf8) else {
            throw ShortcutError.plistEncodingFailed
        }

        let payload: [String: Any] = [
            "shortcutName": appName,
            "shortcut": plistString
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        guard let endpoint = URL(string: "https://hubsign.routinehub.services/sign") else {
            throw ShortcutError.invalidSigningURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("cherri/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://routinehub.co", forHTTPHeaderField: "Origin")
        request.setValue("https://routinehub.co/", forHTTPHeaderField: "Referer")

        let (signedData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ShortcutError.signingFailed(code)
        }

        guard signedData.count >= 4,
              signedData.prefix(4) == Data([0x41, 0x45, 0x41, 0x31]) else {
            throw ShortcutError.invalidSignature
        }

        let safeName = sanitizedFileName(appName)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension("shortcut")

        try signedData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func presentShortcutFile(_ fileURL: URL) {
        guard let presenter = topViewController() else {
            status = "Команда создана, но не удалось открыть системное меню импорта."
            return
        }

        let controller = UIDocumentInteractionController(url: fileURL)
        controller.delegate = self
        documentController = controller

        let sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.maxY - 1,
            width: 1,
            height: 1
        )

        if !controller.presentOpenInMenu(from: sourceRect, in: presenter.view, animated: true) {
            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = sourceRect
            }
            presenter.present(activity, animated: true)
        }
    }

    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        topViewController() ?? UIViewController()
    }

    private func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let root: UIViewController?
        if let base {
            root = base
        } else {
            root = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController
        }

        if let navigation = root as? UINavigationController {
            return topViewController(base: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = root?.presentedViewController {
            return topViewController(base: presented)
        }
        return root
    }

    private func sanitizedFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let pieces = value.components(separatedBy: forbidden)
        let joined = pieces.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "OpaqueIcon" : joined
    }
}

private enum ShortcutError: LocalizedError {
    case iconEncodingFailed
    case plistEncodingFailed
    case invalidSigningURL
    case signingFailed(Int)
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .iconEncodingFailed:
            return "не удалось закодировать иконку"
        case .plistEncodingFailed:
            return "не удалось собрать файл Команды"
        case .invalidSigningURL:
            return "неверный адрес сервиса подписи"
        case .signingFailed(let code):
            return "сервис подписи вернул HTTP \(code)"
        case .invalidSignature:
            return "сервис вернул неподписанный или повреждённый файл"
        }
    }
}
