import Photos
import UIKit

@MainActor
final class ShortcutHelper: ObservableObject {
    @Published var status: String?
    @Published var busy = false

    func saveIconAndOpenShortcuts(_ image: UIImage, appName: String) {
        guard !busy else { return }
        busy = true
        status = nil

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorization in
            guard authorization == .authorized || authorization == .limited else {
                DispatchQueue.main.async {
                    self.busy = false
                    self.status = "Нет разрешения сохранить иконку в Фото."
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    self.busy = false

                    guard success else {
                        self.status = error?.localizedDescription ?? "Не удалось сохранить иконку."
                        return
                    }

                    UIPasteboard.general.string = appName
                    self.status = "Иконка сохранена в Фото, название приложения скопировано."

                    guard let url = URL(string: "shortcuts://create-shortcut") else { return }
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}
