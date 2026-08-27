from pathlib import Path

store_path = Path("OpaqueIconThemer/AppStoreCatalogStore.swift")
store = store_path.read_text(encoding="utf-8")

old_featured = '''                    let old = featured[index]\n                    featured[index] = InstalledAppInfo(\n                        bundleIdentifier: old.bundleIdentifier,\n                        displayName: old.displayName,\n                        icon: image,\n                        applicationToken: old.applicationToken\n                    )\n'''
new_featured = '''                    let old = featured[index]\n                    var nextFeatured = featured\n                    nextFeatured[index] = InstalledAppInfo(\n                        bundleIdentifier: old.bundleIdentifier,\n                        displayName: old.displayName,\n                        icon: image,\n                        applicationToken: old.applicationToken\n                    )\n                    // Reassign the whole @Published array. Subscript-only mutation can leave\n                    // SwiftUI LazyVStack/NavigationLink rows visually stale until another state\n                    // change (for example typing in search) forces the list to rebuild.\n                    featured = nextFeatured\n'''

old_results = '''                    let old = results[index]\n                    results[index] = InstalledAppInfo(\n                        bundleIdentifier: old.bundleIdentifier,\n                        displayName: old.displayName,\n                        icon: image,\n                        applicationToken: old.applicationToken\n                    )\n'''
new_results = '''                    let old = results[index]\n                    var nextResults = results\n                    nextResults[index] = InstalledAppInfo(\n                        bundleIdentifier: old.bundleIdentifier,\n                        displayName: old.displayName,\n                        icon: image,\n                        applicationToken: old.applicationToken\n                    )\n                    results = nextResults\n'''

if old_featured not in store:
    raise SystemExit("App Store live refresh patch failed: featured icon update block not found")
if old_results not in store:
    raise SystemExit("App Store live refresh patch failed: search-result icon update block not found")

store = store.replace(old_featured, new_featured, 1)
store = store.replace(old_results, new_results, 1)
store_path.write_text(store, encoding="utf-8")

# App Store rows also get a tiny local identity change when placeholder -> real icon happens.
# This is intentionally applied only to the App Store section, not to the installed-app list.
ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")
section_start = ui.find("    private var appStoreSection: some View")
section_end = ui.find("    private var emptyCard: some View", section_start)
if section_start < 0 or section_end < 0:
    raise SystemExit("App Store live refresh patch failed: App Store section not found")
section = ui[section_start:section_end]

old_row = '''                    .buttonStyle(.plain)\n'''
new_row = '''                    .buttonStyle(.plain)\n                    // Force only this row to rebuild once its async thumbnail arrives.\n                    .id(app.bundleIdentifier + (app.icon == nil ? ":placeholder" : ":thumbnail"))\n'''
if ":placeholder" not in section:
    if old_row not in section:
        raise SystemExit("App Store live refresh patch failed: App Store row marker not found")
    section = section.replace(old_row, new_row, 1)
    ui = ui[:section_start] + section + ui[section_end:]

required_store = [
    "var nextFeatured = featured",
    "featured = nextFeatured",
    "var nextResults = results",
    "results = nextResults",
]
for token in required_store:
    if token not in store:
        raise SystemExit(f"App Store live refresh verification failed: {token}")
if ':placeholder' not in ui or ':thumbnail' not in ui:
    raise SystemExit("App Store live refresh verification failed: row identity marker missing")

ui_path.write_text(ui, encoding="utf-8")
print("App Store thumbnail live refresh fixed: whole-array @Published updates + per-row placeholder/thumbnail identity")
