from pathlib import Path

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")


def must_replace(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"App Store browser patch failed: {label} marker not found")
    text = text.replace(old, new, 1)


browser_state = '''private struct LGLAppsBrowserView: View {
    @StateObject private var store = InstalledAppsStore()
    let revokeConsent: () -> Void
'''
if "@StateObject private var appStore = AppStoreCatalogStore()" not in text:
    browser_state_new = '''private struct LGLAppsBrowserView: View {
    @StateObject private var store = InstalledAppsStore()
    @StateObject private var appStore = AppStoreCatalogStore()
    let revokeConsent: () -> Void
'''
    must_replace(browser_state, browser_state_new, "App Store state")

# Keep the installed-app browser exactly as-is and add App Store underneath it.
if "appStoreSection" not in text[text.find("private struct LGLAppsBrowserView"):text.find("private struct LGLAppRow")]:
    end_installed = '''                            if !store.status.isEmpty {
                                Text(store.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
'''
    end_installed_new = '''                            if !store.status.isEmpty {
                                Text(store.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                            }
                        }

                        appStoreSection
                    }
                    .padding(.horizontal, 16)
'''
    must_replace(end_installed, end_installed_new, "section placement")

appear_old = '''            .onAppear {
                if store.apps.isEmpty && !store.scanning {
                    store.scan()
                }
            }
'''
appear_new = '''            .onAppear {
                if store.apps.isEmpty && !store.scanning {
                    store.scan()
                }
                appStore.loadFeaturedIfNeeded()
            }
'''
if "appStore.loadFeaturedIfNeeded()" not in text:
    must_replace(appear_old, appear_new, "App Store initial load")

if "private var appStoreSection: some View" not in text:
    card_marker = "    private var emptyCard: some View {\n"
    card = '''    private var appStoreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LGLSectionTitle("App Store", symbol: "apple.logo")
                Spacer()
                if appStore.loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            LGLGlassCard(cornerRadius: 24, interactive: true) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Найти приложение по названию", text: $appStore.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { appStore.searchNow() }
                    if !appStore.search.isEmpty {
                        Button {
                            appStore.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if appStore.displayedApps.isEmpty && appStore.loading {
                LGLGlassCard(cornerRadius: 24) {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Загружаю приложения из App Store…")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                }
            } else if appStore.displayedApps.isEmpty {
                LGLGlassCard(cornerRadius: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "app.badge")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Приложения не найдены")
                            .font(.headline)
                        Text("Попробуй другое название.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(appStore.displayedApps) { app in
                    NavigationLink {
                        LGLAppTintView(app: app)
                    } label: {
                        LGLGlassCard(cornerRadius: 24, interactive: true) {
                            LGLAppRow(app: app)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !appStore.status.isEmpty {
                Text(appStore.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
    }

'''
    if card_marker not in text:
        raise SystemExit("App Store browser patch failed: emptyCard marker missing")
    text = text.replace(card_marker, card + card_marker, 1)

# -----------------------------------------------------------------------------
# List rows use tiny artworkUrl100 thumbnails. Only the opened editor upgrades to 512px.
# This keeps scrolling/search instant without reducing final icon/export quality.
# -----------------------------------------------------------------------------
editor_start = text.find("private struct LGLAppTintView: View {")
editor_end = len(text)
if editor_start < 0:
    raise SystemExit("App Store browser patch failed: editor marker missing")

editor = text[editor_start:editor_end]
state_marker = "    let app: InstalledAppInfo\n"
if "@State private var highResolutionIcon: UIImage?" not in editor:
    if state_marker not in editor:
        raise SystemExit("App Store browser patch failed: editor app state marker missing")
    editor = editor.replace(
        state_marker,
        state_marker + '''    @State private var highResolutionIcon: UIImage?

    private var editorSource: UIImage? {
        highResolutionIcon ?? app.icon
    }
''',
        1,
    )

# Export uses HD when available, while fast live preview still uses its cached 256px derivative.
editor = editor.replace(
    "guard let source = sourceOverride ?? app.icon else { return nil }",
    "guard let source = sourceOverride ?? highResolutionIcon ?? app.icon else { return nil }",
    1,
)

# The visible original preview should also upgrade once HD arrives.
editor = editor.replace(
    "                    if let source = app.icon {\n                        previewCard(source: source)",
    "                    if let source = editorSource {\n                        previewCard(source: source)",
    1,
)

# Add one background HD lookup to the existing editor onAppear after its initial 100px setup.
editor_appear = '''        .onAppear {
            if let source = app.icon {
                fastPreviewSource = Self.makeFastPreviewSource(source)
                autoResolvedMode = IconStyleRenderer.shared.resolvedMode(source: source, requested: .auto)
            }
            markPreviewDirty()
            refreshPreviewIfNeeded(force: true)
        }
'''
if "App Store HD upgrade" not in editor:
    editor_appear_new = '''        .onAppear {
            if let source = app.icon {
                fastPreviewSource = Self.makeFastPreviewSource(source)
                autoResolvedMode = IconStyleRenderer.shared.resolvedMode(source: source, requested: .auto)
            }
            markPreviewDirty()
            refreshPreviewIfNeeded(force: true)

            // App Store HD upgrade: list thumbnails stay tiny/fast; the selected app alone gets
            // 512px artwork for the editor and final export.
            Task { @MainActor in
                let result = await AppStoreArtworkProvider.shared.lookup(bundleIdentifier: app.bundleIdentifier)
                guard let hd = result.image else { return }

                let oldPixels = max(
                    (editorSource?.size.width ?? 0) * (editorSource?.scale ?? 1),
                    (editorSource?.size.height ?? 0) * (editorSource?.scale ?? 1)
                )
                let hdPixels = max(hd.size.width * hd.scale, hd.size.height * hd.scale)
                guard hdPixels > oldPixels else { return }

                highResolutionIcon = hd
                fastPreviewSource = Self.makeFastPreviewSource(hd)
                autoResolvedMode = IconStyleRenderer.shared.resolvedMode(source: hd, requested: .auto)
                markPreviewDirty()
                refreshPreviewIfNeeded(force: true)
            }
        }
'''
    if editor_appear not in editor:
        raise SystemExit("App Store browser patch failed: fast-preview editor onAppear marker missing")
    editor = editor.replace(editor_appear, editor_appear_new, 1)

text = text[:editor_start] + editor

required = [
    "@StateObject private var appStore = AppStoreCatalogStore()",
    "appStore.loadFeaturedIfNeeded()",
    "private var appStoreSection: some View",
    "Найти приложение по названию",
    "ForEach(appStore.displayedApps)",
    "@State private var highResolutionIcon: UIImage?",
    "highResolutionIcon ?? app.icon",
    "App Store HD upgrade",
    "AppStoreArtworkProvider.shared.lookup(bundleIdentifier: app.bundleIdentifier)",
]
for token in required:
    if token not in text:
        raise SystemExit(f"App Store browser patch verification failed: {token}")

path.write_text(text, encoding="utf-8")
print("App Store browser installed: rows render immediately, 100px icons load in parallel, selected app upgrades to 512px in editor")
