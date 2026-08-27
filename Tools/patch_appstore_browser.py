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

required = [
    "@StateObject private var appStore = AppStoreCatalogStore()",
    "appStore.loadFeaturedIfNeeded()",
    "private var appStoreSection: some View",
    "Найти приложение по названию",
    "ForEach(appStore.displayedApps)",
]
for token in required:
    if token not in text:
        raise SystemExit(f"App Store browser patch verification failed: {token}")

path.write_text(text, encoding="utf-8")
print("App Store browser installed: popular ready apps + live name search + direct customizer navigation")
