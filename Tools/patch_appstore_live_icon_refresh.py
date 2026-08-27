from pathlib import Path

store_path = Path("OpaqueIconThemer/AppStoreCatalogStore.swift")
store = store_path.read_text(encoding="utf-8")

# -----------------------------------------------------------------------------
# Live thumbnail refresh.
# Reassign the entire @Published array instead of mutating an element in-place. SwiftUI can keep
# LazyVStack/NavigationLink rows visually stale when the Identifiable id did not change.
# -----------------------------------------------------------------------------
old_featured = '''                    let old = featured[index]\n                    featured[index] = InstalledAppInfo(\n                        bundleIdentifier: old.bundleIdentifier,\n                        displayName: old.displayName,\n                        icon: image,\n                        applicationToken: old.applicationToken\n                    )\n'''
new_featured = '''                    let old = featured[index]\n                    var nextFeatured = featured\n                    nextFeatured[index] = InstalledAppInfo(\n                        bundleIdentifier: old.bundleIdentifier,\n                        displayName: old.displayName,\n                        icon: image,\n                        applicationToken: old.applicationToken\n                    )\n                    featured = nextFeatured\n'''

old_results = '''                    let old = results[index]\n                    results[index] = InstalledAppInfo(\n                        bundleIdentifier: old.bundleIdentifier,\n                        displayName: old.displayName,\n                        icon: image,\n                        applicationToken: old.applicationToken\n                    )\n'''
new_results = '''                    let old = results[index]\n                    var nextResults = results\n                    nextResults[index] = InstalledAppInfo(\n                        bundleIdentifier: old.bundleIdentifier,\n                        displayName: old.displayName,\n                        icon: image,\n                        applicationToken: old.applicationToken\n                    )\n                    results = nextResults\n'''

if old_featured not in store:
    raise SystemExit("App Store live refresh patch failed: featured icon update block not found")
if old_results not in store:
    raise SystemExit("App Store live refresh patch failed: search-result icon update block not found")
store = store.replace(old_featured, new_featured, 1)
store = store.replace(old_results, new_results, 1)

# -----------------------------------------------------------------------------
# Catalog country is fixed to the UK App Store, with US only as a fallback. Never derive the
# catalog from the device/App Store account locale, so a Russian-region phone cannot shrink search
# results or hide apps that are available in the English-language stores.
# -----------------------------------------------------------------------------
store = store.replace(
    '        let region = Locale.current.region?.identifier.lowercased() ?? "us"\n',
    '        let region = "gb"\n',
    1,
)
store = store.replace(
    '        let currentRegion = Locale.current.region?.identifier.lowercased() ?? "us"\n        let regions = currentRegion == "us" ? ["us"] : [currentRegion, "us"]\n',
    '        let regions = ["gb", "us"]\n',
    1,
)

store_path.write_text(store, encoding="utf-8")

provider_path = Path("OpaqueIconThemer/AppStoreArtworkProvider.swift")
provider = provider_path.read_text(encoding="utf-8")
provider_old = '''        let currentRegion = Locale.current.region?.identifier ?? "US"\n        let regions = currentRegion.uppercased() == "US" ? ["US"] : [currentRegion, "US"]\n'''
provider_new = '''        // Always resolve HD artwork through the UK catalog first. US is a fallback only.\n        // Never use Locale.current here: the device/account can be in RU while this browser is\n        // intentionally an English App Store catalog.\n        let regions = ["GB", "US"]\n'''
if provider_old not in provider:
    raise SystemExit("App Store UK patch failed: artwork provider region block not found")
provider = provider.replace(provider_old, provider_new, 1)
provider_path.write_text(provider, encoding="utf-8")

# -----------------------------------------------------------------------------
# Force only the App Store row to rebuild once its placeholder becomes a real async thumbnail.
# -----------------------------------------------------------------------------
ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")
section_start = ui.find("    private var appStoreSection: some View")
section_end = ui.find("    private var emptyCard: some View", section_start)
if section_start < 0 or section_end < 0:
    raise SystemExit("App Store live refresh patch failed: App Store section not found")
section = ui[section_start:section_end]

old_row = '''                    .buttonStyle(.plain)\n'''
new_row = '''                    .buttonStyle(.plain)\n                    .id(app.bundleIdentifier + (app.icon == nil ? ":placeholder" : ":thumbnail"))\n'''
if ":placeholder" not in section:
    if old_row not in section:
        raise SystemExit("App Store live refresh patch failed: App Store row marker not found")
    section = section.replace(old_row, new_row, 1)
    ui = ui[:section_start] + section + ui[section_end:]

# Make the chosen catalog explicit in the UI.
ui = ui.replace(
    'LGLSectionTitle("App Store", symbol: "apple.logo")',
    'LGLSectionTitle("App Store · UK", symbol: "apple.logo")',
    1,
)

required_store = [
    "var nextFeatured = featured",
    "featured = nextFeatured",
    "var nextResults = results",
    "results = nextResults",
    'let region = "gb"',
    'let regions = ["gb", "us"]',
]
for token in required_store:
    if token not in store:
        raise SystemExit(f"App Store patch verification failed: {token}")
if 'let regions = ["GB", "US"]' not in provider:
    raise SystemExit("App Store patch verification failed: HD provider is not GB/US")
if "Locale.current.region" in provider:
    raise SystemExit("App Store patch verification failed: HD provider still depends on device region")
if ':placeholder' not in ui or ':thumbnail' not in ui:
    raise SystemExit("App Store patch verification failed: row identity marker missing")
if 'App Store · UK' not in ui:
    raise SystemExit("App Store patch verification failed: UK UI marker missing")

ui_path.write_text(ui, encoding="utf-8")
print("App Store fixed: thumbnails refresh live; catalog is UK-first with US fallback and never follows RU/device locale")
