from pathlib import Path

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"fast preview patch failed: {label} marker not found")
    return text.replace(old, new, 1)


# Keep the scheduler at display cadence even if an older source revision is used.
ui = ui.replace(
    "private let liquidPreviewTicker = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()",
    "private let liquidPreviewTicker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()",
    1,
)

# Cache a small source used only by the live editor. Export keeps app.icon at full resolution.
state_marker = "    @State private var previewIcon: UIImage?\n"
if "@State private var fastPreviewSource: UIImage?" not in ui:
    ui = replace_once(
        ui,
        state_marker,
        state_marker + "    @State private var fastPreviewSource: UIImage?\n",
        "preview state",
    )

# Allow preview and export to share exactly the same renderer while choosing a different source size.
old_signature = "    private func makeRenderSnapshot() -> RenderSnapshot? {\n        guard let source = app.icon else { return nil }\n"
new_signature = "    private func makeRenderSnapshot(sourceOverride: UIImage? = nil) -> RenderSnapshot? {\n        guard let source = sourceOverride ?? app.icon else { return nil }\n"
if old_signature in ui:
    ui = ui.replace(old_signature, new_signature, 1)
elif "private func makeRenderSnapshot(sourceOverride: UIImage? = nil)" not in ui:
    raise SystemExit("fast preview patch failed: makeRenderSnapshot marker not found")

# The preview card is only ~104 pt. A 256 px working source dramatically reduces all per-pixel
# mask/gradient/shadow passes while remaining visually sharp. This does not touch the final export.
render_marker = "    private static func render(_ snapshot: RenderSnapshot) -> UIImage? {\n"
if "private static func makeFastPreviewSource" not in ui:
    helper = '''    private static func makeFastPreviewSource(_ source: UIImage, maxPixel: CGFloat = 256) -> UIImage {
        let pixelWidth = max(1.0, source.size.width * source.scale)
        let pixelHeight = max(1.0, source.size.height * source.scale)
        let maxDimension = max(pixelWidth, pixelHeight)
        guard maxDimension > maxPixel else { return source }

        let ratio = maxPixel / maxDimension
        let targetSize = CGSize(
            width: max(1.0, (pixelWidth * ratio).rounded()),
            height: max(1.0, (pixelHeight * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

'''
    ui = replace_once(ui, render_marker, helper + render_marker, "render helper")

# Prepare the thumbnail once when entering the editor, never on slider movement.
appear_old = '''        .onAppear {
            if let source = app.icon {
                autoResolvedMode = IconStyleRenderer.shared.resolvedMode(source: source, requested: .auto)
            }
'''
appear_new = '''        .onAppear {
            if let source = app.icon {
                fastPreviewSource = Self.makeFastPreviewSource(source)
                autoResolvedMode = IconStyleRenderer.shared.resolvedMode(source: source, requested: .auto)
            }
'''
if appear_old in ui:
    ui = ui.replace(appear_old, appear_new, 1)
elif "fastPreviewSource = Self.makeFastPreviewSource(source)" not in ui:
    raise SystemExit("fast preview patch failed: onAppear marker not found")

# Only the asynchronous live-preview path uses the small source. renderCurrentIcon() deliberately
# keeps calling makeRenderSnapshot() with no override, so saved PNG/Shortcut output is unchanged.
refresh_start = ui.find("    private func refreshPreviewIfNeeded(force: Bool = false)")
refresh_end = ui.find("    private func sliderEditingChanged", refresh_start)
if refresh_start < 0 or refresh_end < 0:
    raise SystemExit("fast preview patch failed: refreshPreviewIfNeeded range not found")
refresh = ui[refresh_start:refresh_end]
refresh = refresh.replace(
    "        guard let snapshot = makeRenderSnapshot() else { return }\n",
    "        guard let snapshot = makeRenderSnapshot(sourceOverride: fastPreviewSource ?? app.icon) else { return }\n",
    1,
)

# Prefer latency over throughput for a visible interaction.
refresh = refresh.replace(
    "DispatchQueue.global(qos: .userInitiated).async {",
    "DispatchQueue.global(qos: .userInteractive).async {",
    1,
)

# If another control event arrived while the frame was being rendered, immediately process only the
# newest revision. This coalesces stale frames and avoids an extra display-tick of latency.
completion_old = '''                renderedRevision = revision
                renderInFlight = false
'''
completion_new = '''                renderedRevision = revision
                renderInFlight = false
                if previewRevision != renderedRevision {
                    refreshPreviewIfNeeded(force: true)
                }
'''
if "if previewRevision != renderedRevision" not in refresh:
    if completion_old not in refresh:
        raise SystemExit("fast preview patch failed: completion marker not found")
    refresh = refresh.replace(completion_old, completion_new, 1)

if "sourceOverride: fastPreviewSource ?? app.icon" not in refresh:
    raise SystemExit("fast preview patch failed: preview source override was not installed")
ui = ui[:refresh_start] + refresh + ui[refresh_end:]

# Final safety checks: export remains full-resolution and no visual processors are replaced here.
current_start = ui.find("    private func renderCurrentIcon()")
current_end = ui.find("    private func markPreviewDirty", current_start)
if current_start < 0 or current_end < 0:
    raise SystemExit("fast preview patch failed: renderCurrentIcon range not found")
current = ui[current_start:current_end]
if "makeRenderSnapshot()" not in current or "sourceOverride" in current:
    raise SystemExit("fast preview patch failed: full-resolution export path changed unexpectedly")

ui_path.write_text(ui, encoding="utf-8")
print("Fast live preview installed: 60 Hz scheduler, 256px cached preview source, latest-frame coalescing; export stays full-resolution")
