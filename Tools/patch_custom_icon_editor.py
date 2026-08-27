from pathlib import Path

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")
helper_path = Path("OpaqueIconThemer/ShortcutHelper.swift")
helper = helper_path.read_text(encoding="utf-8")


def must_replace(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"custom icon patch failed: {label} marker not found")
    return text.replace(old, new, 1)


# -----------------------------------------------------------------------------
# Imports for Photos picker + Files importer.
# -----------------------------------------------------------------------------
if "import PhotosUI" not in ui:
    ui = must_replace(
        ui,
        "import SwiftUI\n",
        "import SwiftUI\nimport PhotosUI\nimport UniformTypeIdentifiers\n",
        "PhotosUI imports",
    )

# -----------------------------------------------------------------------------
# App browser: add a first-class custom-icon entry point.
# -----------------------------------------------------------------------------
state_marker = "    @StateObject private var appStore = AppStoreCatalogStore()\n"
if "@State private var customPhotoItem" not in ui:
    ui = must_replace(
        ui,
        state_marker,
        state_marker + '''    @State private var customPhotoItem: PhotosPickerItem?\n    @State private var customImage: UIImage?\n    @State private var showCustomEditor = false\n    @State private var showCustomFileImporter = false\n    @State private var customImportError: String?\n''',
        "custom browser state",
    )

stack_marker = '''                    LazyVStack(spacing: 16) {
                        searchCard
'''
if "customIconSection" not in ui[ui.find("private struct LGLAppsBrowserView"):ui.find("private struct LGLAppRow")]:
    ui = must_replace(
        ui,
        stack_marker,
        '''                    LazyVStack(spacing: 16) {
                        customIconSection
                        searchCard
''',
        "custom section placement",
    )

# Attach picker/import/navigation behaviour to the browser's existing modifier chain.
appear_marker = '''            .onAppear {
                if store.apps.isEmpty && !store.scanning {
                    store.scan()
                }
                appStore.loadFeaturedIfNeeded()
            }
'''
if ".fileImporter(isPresented: $showCustomFileImporter" not in ui:
    appear_new = appear_marker + '''            .onChange(of: customPhotoItem) { item in
                guard let item else { return }
                Task { @MainActor in
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else {
                            customImportError = "Не удалось прочитать выбранное изображение."
                            return
                        }
                        openCustomImage(image)
                    } catch {
                        customImportError = "Не удалось открыть изображение: \\(error.localizedDescription)"
                    }
                }
            }
            .fileImporter(
                isPresented: $showCustomFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        let data = try Data(contentsOf: url)
                        guard let image = UIImage(data: data) else {
                            customImportError = "Файл не удалось распознать как изображение."
                            return
                        }
                        openCustomImage(image)
                    } catch {
                        customImportError = "Не удалось открыть файл: \\(error.localizedDescription)"
                    }
                case .failure(let error):
                    customImportError = "Не удалось выбрать файл: \\(error.localizedDescription)"
                }
            }
            .navigationDestination(isPresented: $showCustomEditor) {
                if let customImage {
                    LGLAppTintView(
                        app: InstalledAppInfo(
                            bundleIdentifier: "__oit_custom_icon__",
                            displayName: "Своя иконка",
                            icon: customImage,
                            applicationToken: nil
                        )
                    )
                }
            }
'''
    ui = must_replace(ui, appear_marker, appear_new, "browser picker modifiers")

search_marker = "    private var searchCard: some View {\n"
if "private var customIconSection: some View" not in ui:
    custom_section = '''    private var customIconSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LGLSectionTitle("Своя иконка", symbol: "photo.badge.plus")

            LGLGlassCard(cornerRadius: 24, interactive: true) {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.pencil")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Редактировать свою картинку")
                                .font(.headline)
                            Text("Фото или PNG/JPG из Файлов — затем тот же Tint+/Apple Mono редактор.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Divider().opacity(0.35)

                    PhotosPicker(selection: $customPhotoItem, matching: .images) {
                        Label("Выбрать из Фото", systemImage: "photo.on.rectangle")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        showCustomFileImporter = true
                    } label: {
                        Label("Выбрать из Файлов", systemImage: "folder")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("Неквадратное изображение автоматически обрежется по центру до 1:1. После редактирования можно просто сохранить результат в Фото — без Команды и bundle ID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let customImportError {
                        Text(customImportError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func openCustomImage(_ image: UIImage) {
        customImage = Self.prepareCustomIcon(image)
        customImportError = nil
        customPhotoItem = nil
        showCustomEditor = true
    }

    private static func prepareCustomIcon(_ image: UIImage) -> UIImage {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }

        // App icons are square. Aspect-fill into a 1024x1024 canvas so arbitrary photos/files can
        // enter the existing icon renderer without stretching or changing its material pipeline.
        let target = CGSize(width: 1024, height: 1024)
        let scale = max(target.width / sourceSize.width, target.height / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = CGRect(
            x: (target.width - drawSize.width) * 0.5,
            y: (target.height - drawSize.height) * 0.5,
            width: drawSize.width,
            height: drawSize.height
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: drawRect)
        }
    }

'''
    ui = must_replace(ui, search_marker, custom_section + search_marker, "custom section body")

# -----------------------------------------------------------------------------
# Editor: custom images use the exact same visual pipeline, but saving is image-only.
# -----------------------------------------------------------------------------
editor_source_marker = '''    private var editorSource: UIImage? {
        highResolutionIcon ?? app.icon
    }
'''
if "private var isCustomIcon" not in ui:
    ui = must_replace(
        ui,
        editor_source_marker,
        editor_source_marker + '''
    private var isCustomIcon: Bool {
        app.bundleIdentifier == "__oit_custom_icon__"
    }
''',
        "custom editor identity",
    )

# Custom imported images are already full-resolution; never query App Store for the sentinel ID.
if "guard !isCustomIcon else { return }" not in ui:
    ui = must_replace(
        ui,
        '''            Task { @MainActor in
                let result = await AppStoreArtworkProvider.shared.lookup(bundleIdentifier: app.bundleIdentifier)
''',
        '''            Task { @MainActor in
                guard !isCustomIcon else { return }
                let result = await AppStoreArtworkProvider.shared.lookup(bundleIdentifier: app.bundleIdentifier)
''',
        "skip HD lookup for custom icon",
    )

ui = ui.replace(
    ".navigationTitle(app.displayName)",
    ".navigationTitle(isCustomIcon ? \"Своя иконка\" : app.displayName)",
    1,
)

if "if !isCustomIcon {\n                            homeScreenCard" not in ui:
    ui = must_replace(
        ui,
        '''                        actionCard
                        homeScreenCard
''',
        '''                        actionCard
                        if !isCustomIcon {
                            homeScreenCard
                        }
''',
        "hide Home Screen instructions for custom icon",
    )

header_old = '''    private var appHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Приложение", symbol: "app")
            LGLGlassCard {
                LGLAppRow(app: app)
            }
        }
    }
'''
header_new = '''    private var appHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle(isCustomIcon ? "Своя иконка" : "Приложение", symbol: isCustomIcon ? "photo" : "app")
            LGLGlassCard {
                if isCustomIcon, let source = editorSource {
                    HStack(spacing: 14) {
                        Image(uiImage: source)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Своя иконка")
                                .font(.headline)
                            Text("Редактирование без привязки к приложению")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    LGLAppRow(app: app)
                }
            }
        }
    }
'''
if header_old in ui:
    ui = ui.replace(header_old, header_new, 1)
elif "Редактирование без привязки к приложению" not in ui:
    raise SystemExit("custom icon patch failed: editor header marker not found")

action_old = '''    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Готово", symbol: "wand.and.stars")
            LGLGlassCard {
                VStack(spacing: 12) {
                    LGLPrimaryButton(disabled: shortcutHelper.busy) {
                        guard let finalIcon = renderCurrentIcon() else { return }
                        previewIcon = finalIcon
                        shortcutHelper.generateReadyShortcut(
                            finalIcon,
                            appName: app.displayName,
                            bundleIdentifier: app.bundleIdentifier
                        )
                    } label: {
                        HStack {
                            if shortcutHelper.busy {
                                ProgressView()
                            }
                            Label("Сохранить и создать Команду", systemImage: "wand.and.stars")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                    }

                    Text("Сохраняет готовую иконку в Фото и создаёт .shortcut с одним действием «Открыть приложение».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
'''
action_new = '''    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle(isCustomIcon ? "Сохранить" : "Готово", symbol: isCustomIcon ? "square.and.arrow.down" : "wand.and.stars")
            LGLGlassCard {
                VStack(spacing: 12) {
                    if isCustomIcon {
                        LGLPrimaryButton(disabled: shortcutHelper.busy) {
                            guard let finalIcon = renderCurrentIcon() else { return }
                            previewIcon = finalIcon
                            shortcutHelper.saveImageOnly(finalIcon)
                        } label: {
                            HStack {
                                if shortcutHelper.busy {
                                    ProgressView()
                                }
                                Label("Сохранить иконку в Фото", systemImage: "square.and.arrow.down")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 10)
                        }

                        Text("Просто сохраняет готовую иконку в Фото. Команда, bundle ID и установленное приложение не нужны.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        LGLPrimaryButton(disabled: shortcutHelper.busy) {
                            guard let finalIcon = renderCurrentIcon() else { return }
                            previewIcon = finalIcon
                            shortcutHelper.generateReadyShortcut(
                                finalIcon,
                                appName: app.displayName,
                                bundleIdentifier: app.bundleIdentifier
                            )
                        } label: {
                            HStack {
                                if shortcutHelper.busy {
                                    ProgressView()
                                }
                                Label("Сохранить и создать Команду", systemImage: "wand.and.stars")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 10)
                        }

                        Text("Сохраняет готовую иконку в Фото и создаёт .shortcut с одним действием «Открыть приложение».")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }
'''
if action_old in ui:
    ui = ui.replace(action_old, action_new, 1)
elif "shortcutHelper.saveImageOnly(finalIcon)" not in ui:
    raise SystemExit("custom icon patch failed: action card marker not found")

# -----------------------------------------------------------------------------
# Shortcut helper gets a save-only path that reuses the existing add-only Photos permission flow.
# -----------------------------------------------------------------------------
if "func saveImageOnly(_ image: UIImage)" not in helper:
    helper_marker = "    private func saveImageToPhotos(_ image: UIImage) async throws {\n"
    save_only = '''    func saveImageOnly(_ image: UIImage) {
        guard !busy else { return }
        busy = true
        status = "Сохраняю готовую иконку в Фото…"

        Task {
            do {
                try await saveImageToPhotos(image)
                status = "Готово: иконка сохранена в Фото."
                busy = false
            } catch {
                status = "Не удалось сохранить иконку: \\(error.localizedDescription)"
                busy = false
            }
        }
    }

'''
    helper = must_replace(helper, helper_marker, save_only + helper_marker, "save-only helper")

# Final verification so CI cannot silently build a partial feature.
required_ui = [
    "import PhotosUI",
    "import UniformTypeIdentifiers",
    "private var customIconSection: some View",
    "Выбрать из Фото",
    "Выбрать из Файлов",
    "__oit_custom_icon__",
    "private var isCustomIcon: Bool",
    "shortcutHelper.saveImageOnly(finalIcon)",
    "Просто сохраняет готовую иконку в Фото",
    "guard !isCustomIcon else { return }",
]
for token in required_ui:
    if token not in ui:
        raise SystemExit(f"custom icon patch verification failed: {token}")
if "func saveImageOnly(_ image: UIImage)" not in helper:
    raise SystemExit("custom icon patch verification failed: saveImageOnly missing")

ui_path.write_text(ui, encoding="utf-8")
helper_path.write_text(helper, encoding="utf-8")
print("Custom icon flow added: Photos/Files import -> same editor -> save image only, no bundle ID/Shortcut")
