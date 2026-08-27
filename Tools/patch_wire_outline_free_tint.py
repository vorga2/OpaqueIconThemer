from pathlib import Path

# Final Tint+ wiring pass.
#
# Earlier no-rim work added OutlineFreeAdvancedTintProcessor, but the runtime render path still
# called AdvancedTintCompositeProcessor. That means installing a fresh IPA could look identical to
# the previous build even though the new processor compiled into the app. This patch runs LAST and
# makes the no-outline compositor the actual Tint+ renderer.

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")

old_calls = [
    "baseOutput = AdvancedTintCompositeProcessor.shared.apply(\n                source: snapshot.source,\n                rendered: base,",
    "baseOutput = CombinedTintIntensityProcessor.shared.apply(\n                source: snapshot.source,\n                rendered: base,",
]

replacement = "baseOutput = OutlineFreeAdvancedTintProcessor.shared.apply(\n                source: snapshot.source,"

changed = False
for old in old_calls:
    if old in ui:
        ui = ui.replace(old, replacement, 1)
        changed = True
        break

if not changed:
    raise SystemExit("wire-outline-free: Tint+ compositor call not found")

# OutlineFreeAdvancedTintProcessor does not accept a pre-rendered bitmap. Remove the now-invalid
# rendered/base argument if a previous patch left it behind after the call rewrite.
ui = ui.replace("                rendered: base,\n", "", 1)

# Keep Tint+ completely away from the generic silhouette shadow/bevel processor. Internal depth for
# other modes may still exist, but Tint+ must not get any contour stroke from this stage.
ui = ui.replace(
    "logoShadows: snapshot.resolvedMode == .smartLogo || snapshot.tintVariant == .advanced",
    "logoShadows: snapshot.resolvedMode == .smartLogo",
)
ui = ui.replace(
    "logoShadows: snapshot.tintVariant == .advanced",
    "logoShadows: false",
)

# Bump a persisted render-generation token. The value itself is not important; changing the key
# forces a new preview generation after installing over an older build and prevents retained UI
# state from being mistaken for the new renderer.
if "oit.tintRendererGeneration.20260827.nooutline.v1" not in ui:
    marker = "private let liquidPreviewTicker = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()\n"
    if marker in ui:
        ui = ui.replace(
            marker,
            marker + 'private let oitTintRendererGeneration = "oit.tintRendererGeneration.20260827.nooutline.v1"\n',
            1,
        )

ui_path.write_text(ui, encoding="utf-8")
print("OutlineFreeAdvancedTintProcessor is now the active Tint+ renderer; generic Tint+ silhouette shadows disabled")
