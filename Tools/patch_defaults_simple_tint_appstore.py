from pathlib import Path

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")


def must_replace(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"defaults/AppStore patch failed: {label} marker not found")
    text = text.replace(old, new, 1)


# -----------------------------------------------------------------------------
# Requested defaults for Tint+ / Apple Mono material controls.
# -----------------------------------------------------------------------------
replacements = [
    ("    @State private var tintColor: Color = .blue\n",
     "    @State private var tintColor: Color = Color(red: 69.0 / 255.0, green: 129.0 / 255.0, blue: 183.0 / 255.0)\n",
     "background tint #4581B7"),
    ("    @State private var iconTintColor: Color = .blue\n",
     "    @State private var iconTintColor: Color = Color(red: 201.0 / 255.0, green: 255.0 / 255.0, blue: 251.0 / 255.0)\n",
     "icon tint #C9FFFB"),
    ("    @State private var tintVariant: LGLTintVariant = .simple\n",
     "    @State private var tintVariant: LGLTintVariant = .advanced\n",
     "Tint+ default variant"),
    ("    @State private var tintIntensity: Double = 0.88\n",
     "    @State private var tintIntensity: Double = 1.0\n",
     "tint strength 100"),
    ("    @State private var backgroundIntensity: Double = 0.72\n",
     "    @State private var backgroundIntensity: Double = 1.0\n",
     "background intensity 100"),
    ("    @State private var gradientStart: Double = 0.0\n",
     "    @State private var gradientStart: Double = 0.50\n",
     "gradient start 50"),
    ("    @State private var gradientStrength: Double = 0.45\n",
     "    @State private var gradientStrength: Double = 0.30\n",
     "gradient intensity 30"),
    ("    @State private var shadowStrength: Double = 0.90\n",
     "    @State private var shadowStrength: Double = 0.25\n",
     "shadow strength 25"),
    ("    @State private var shadowTintMix: Double = 0.30\n",
     "    @State private var shadowTintMix: Double = 0.0\n",
     "shadow tint mix 0"),
]
for old, new, label in replacements:
    if new not in text:
        must_replace(old, new, label)

# These requested defaults should remain explicit even if earlier patches change their defaults.
text = text.replace("    @State private var gradientEnabled = false\n", "    @State private var gradientEnabled = true\n", 1)
text = text.replace("    @State private var customGradientColorEnabled = true\n", "    @State private var customGradientColorEnabled = false\n", 1)
text = text.replace("    @State private var backgroundGradientEnabled = true\n", "    @State private var backgroundGradientEnabled = false\n", 1)
text = text.replace("    @State private var shadowsEnabled = false\n", "    @State private var shadowsEnabled = true\n", 1)

# -----------------------------------------------------------------------------
# Simple Tint = ONE global tint only. No split background intensity, gradients or shadows.
# -----------------------------------------------------------------------------
# Hide split background-intensity control in Simple Tint.
old_bg_slider = '''                    Divider().opacity(0.35)
                    LGLSliderRow(
                        title: "Интенсивность фона",
                        value: $backgroundIntensity,
                        range: 0...1,
                        onEditingChanged: sliderEditingChanged
                    )

                    if resolvedMode == .tint {
'''
new_bg_slider = '''                    if resolvedMode != .tint || tintVariant == .advanced {
                        Divider().opacity(0.35)
                        LGLSliderRow(
                            title: "Интенсивность фона",
                            value: $backgroundIntensity,
                            range: 0...1,
                            onEditingChanged: sliderEditingChanged
                        )
                    }

                    if resolvedMode == .tint {
'''
if old_bg_slider in text:
    text = text.replace(old_bg_slider, new_bg_slider, 1)

# Advanced-only background gradient; simple Tint must have no extra material effects.
text = text.replace(
    "                        if resolvedMode == .tint {\n                            backgroundGradientCard\n                        }",
    "                        if resolvedMode == .tint && tintVariant == .advanced {\n                            backgroundGradientCard\n                        }",
    1,
)

# Hide element shadows for Simple Tint. Smart Logo and Tint+ keep the shadow controls.
text = text.replace(
    "                        shadowsCard\n                        actionCard",
    "                        if resolvedMode != .tint || tintVariant == .advanced {\n                            shadowsCard\n                        }\n                        actionCard",
    1,
)

# Make the renderer rule absolute: Simple Tint returns the global tinted bitmap immediately.
render_marker = '''        let renderer = ReferenceAppleMonotoneRenderer.shared
        let baseOutput: UIImage?
'''
if "Simple Tint is intentionally only one global tint" not in text:
    render_insert = '''        let renderer = ReferenceAppleMonotoneRenderer.shared

        // Simple Tint is intentionally only one global tint. It does not use separate
        // background/icon material, background intensity, gradients or element shadows.
        if snapshot.resolvedMode == .tint && snapshot.tintVariant == .simple {
            return renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.backgroundTint,
                intensity: snapshot.tintIntensity
            )
        }

        let baseOutput: UIImage?
'''
    must_replace(render_marker, render_insert, "simple Tint global render")

text = text.replace(
    ': "Обычный Tint: один цвет для всей иконки с раздельной силой фона и тинта."',
    ': "Обычный Tint: только один общий цвет и одна сила тинта для всей иконки."',
    1,
)
text = text.replace(
    'return "При 100% + 100% обычный Tint становится ровно выбранным цветом."',
    'return "Обычный Tint применяет только общий тинт ко всей иконке — без раздельного фона, градиентов и теней."',
    1,
)

# -----------------------------------------------------------------------------
# App Store browser: ready popular apps + normal name search, no bundle ID typing.
# -----------------------------------------------------------------------------
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
    must_replace(browser_state, browser_state_new, "App Store state object")

# Put the App Store section after the local-installed-app block and before LazyVStack padding.
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
    must_replace(end_installed, end_installed_new, "App Store section placement")

# Load popular cards automatically.
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
    must_replace(appear_old, appear_new, "App Store onAppear")

# Insert self-contained App Store search/results UI before the existing emptyCard helper.
if "private var appStoreSection: some View" not in text:
    card_marker = "    private var emptyCard: some View {\n"
    app_store_card = '''    private var appStoreSection: some View {
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
        raise SystemExit("defaults/AppStore patch failed: emptyCard insertion marker missing")
    text = text.replace(card_marker, app_store_card + card_marker, 1)

# Hard verification: don't silently ship partial defaults/UI.
required = [
    "69.0 / 255.0, green: 129.0 / 255.0, blue: 183.0 / 255.0",
    "201.0 / 255.0, green: 255.0 / 255.0, blue: 251.0 / 255.0",
    "@State private var tintVariant: LGLTintVariant = .advanced",
    "@State private var tintIntensity: Double = 1.0",
    "@State private var backgroundIntensity: Double = 1.0",
    "@State private var gradientStart: Double = 0.50",
    "@State private var gradientStrength: Double = 0.30",
    "@State private var shadowStrength: Double = 0.25",
    "@State private var shadowTintMix: Double = 0.0",
    "Simple Tint is intentionally only one global tint",
    "@StateObject private var appStore = AppStoreCatalogStore()",
    "private var appStoreSection: some View",
    "Найти приложение по названию",
]
for token in required:
    if token not in text:
        raise SystemExit(f"defaults/AppStore patch verification failed: {token}")

path.write_text(text, encoding="utf-8")
print("Requested defaults installed; Simple Tint reduced to global tint only; App Store ready-app browser/search added")
