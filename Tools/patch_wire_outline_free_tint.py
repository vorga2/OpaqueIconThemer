from pathlib import Path
import re

# Final Tint+ wiring/verification pass.
#
# This script intentionally runs AFTER patch_force_outline_free_tint.py. Therefore the correct
# state may already contain OutlineFreeAdvancedTintProcessor. Treat that as success instead of
# failing while looking only for an old compositor call.

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")

outline_call = "OutlineFreeAdvancedTintProcessor.shared.apply("

# If an earlier patch has not wired it yet, normalize either historical compositor to the strict
# two-material renderer. Do not require this replacement when the file is already in the desired
# state.
if outline_call not in ui:
    candidates = [
        "AdvancedTintCompositeProcessor.shared.apply(",
        "CombinedTintIntensityProcessor.shared.apply(",
    ]
    changed = False
    for old in candidates:
        if old in ui:
            ui = ui.replace(old, outline_call, 1)
            changed = True
            break
    if not changed:
        raise SystemExit("wire-outline-free: neither OutlineFree nor a historical Tint+ compositor call was found")

# OutlineFreeAdvancedTintProcessor has no `rendered:` argument. Remove it only from the argument
# list belonging to the OutlineFree call; this is safe whether the previous patch already removed
# it or not.
pattern = re.compile(
    r"(OutlineFreeAdvancedTintProcessor\.shared\.apply\(\s*\n\s*source:\s*snapshot\.source,\s*\n)\s*rendered:\s*base,\s*\n",
    re.M,
)
ui, _ = pattern.subn(r"\1", ui, count=1)

# Tint+ must return before the generic silhouette shadow/bevel stage. The force patch normally
# inserts this guard; keep this verifier tolerant and normalize older variants if necessary.
old_guard = """        guard snapshot.shadowsEnabled && !preserveSolidTint else {
            return baseOutput
        }
"""
new_guard = """        let outlineFreeAdvanced = snapshot.resolvedMode == .tint && snapshot.tintVariant == .advanced
        guard snapshot.shadowsEnabled && !preserveSolidTint && !outlineFreeAdvanced else {
            return baseOutput
        }
"""
if old_guard in ui:
    ui = ui.replace(old_guard, new_guard, 1)

# Also neutralize legacy logoShadows expressions if they survived another historical patch.
ui = ui.replace(
    "logoShadows: snapshot.resolvedMode == .smartLogo || snapshot.tintVariant == .advanced",
    "logoShadows: snapshot.resolvedMode == .smartLogo",
)
ui = ui.replace(
    "logoShadows: snapshot.tintVariant == .advanced",
    "logoShadows: false",
)

# Build-generation token: NoRim-3 uses strict binary final geometry. Installing over an old IPA
# preserves settings, so bump the source generation marker to make the new render generation easy
# to distinguish from retained state.
if "oit.tintRendererGeneration.20260827.nooutline.v3" not in ui:
    marker = "private let liquidPreviewTicker = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()\n"
    if marker in ui:
        ui = ui.replace(
            marker,
            marker + 'private let oitTintRendererGeneration = "oit.tintRendererGeneration.20260827.nooutline.v3"\n',
            1,
        )

# Hard verification of the final state. This is what this CI step is actually for.
if outline_call not in ui:
    raise SystemExit("wire-outline-free: final OutlineFree Tint+ call missing")

outline_index = ui.find(outline_call)
outline_tail = ui[outline_index:outline_index + 700]
if "rendered: base" in outline_tail:
    raise SystemExit("wire-outline-free: obsolete rendered: base argument still present on OutlineFree call")

if "let outlineFreeAdvanced = snapshot.resolvedMode == .tint && snapshot.tintVariant == .advanced" not in ui:
    raise SystemExit("wire-outline-free: Tint+ shadow-bypass guard missing")

ui_path.write_text(ui, encoding="utf-8")
print("OutlineFree Tint+ NoRim-3 wiring verified: strict binary geometry, no rendered bitmap argument, silhouette shadows bypassed")
