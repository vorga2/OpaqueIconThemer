from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"form-shadow patch failed: {label} marker not found")
    return text.replace(old, new, 1)


# -----------------------------------------------------------------------------
# Strengthen shadows around the detected FOREGROUND FORM only.
# No shadow is ever allowed to reach the outer app-icon/tile perimeter.
# -----------------------------------------------------------------------------
shadow_path = Path("OpaqueIconThemer/IconShadowProcessor.swift")
shadow = shadow_path.read_text(encoding="utf-8")

# Slightly broader contact/ambient masks. These values are still expressed in the existing
# 180px design space and therefore scale with the processor resolution.
shadow = shadow.replace("(4.0 * designScale)", "(5.0 * designScale)", 1)
shadow = shadow.replace("(10.0 * designScale)", "(12.0 * designScale)", 1)

old_offsets = '''        let contactOffset = max(1, Int((2.0 * designScale).rounded()))
        let ambientOffset = max(1, Int((5.0 * designScale).rounded()))
        let darkInnerOffset = max(1, Int((1.0 * designScale).rounded()))
        let lightInnerOffset = max(1, Int((1.0 * designScale).rounded()))

        var output = renderedPixels
'''
new_offsets = '''        let contactOffset = max(1, Int((2.0 * designScale).rounded()))
        let ambientOffset = max(1, Int((5.0 * designScale).rounded()))
        let darkInnerOffset = max(1, Int((1.0 * designScale).rounded()))
        let lightInnerOffset = max(1, Int((1.0 * designScale).rounded()))

        // Absolute guarantee requested by the UI: the outer app-icon tile must stay perfectly
        // clean. Even if foreground detection touches a corner, no form shadow may be painted in
        // this safety band, so there are never side/perimeter shadows around the square icon.
        let tileSafetyInset = max(4, Int((4.5 * designScale).rounded()))

        var output = renderedPixels
'''
if "let tileSafetyInset" not in shadow:
    shadow = replace_once(shadow, old_offsets, new_offsets, "tile safety inset")

old_drop = '''                let outside = 1 - logo
                let logoDrop = outside * amount * (contact * 0.30 + ambient * 0.12)
                if logoDrop > 0.0001 {
                    result = mix(result, effectiveShadowLinear, amount: clamp(logoDrop, 0, 0.48))
                }
'''
new_drop = '''                let outside = 1 - logo
                let insideTileSafetyBand = x < tileSafetyInset ||
                    x >= width - tileSafetyInset ||
                    y < tileSafetyInset ||
                    y >= height - tileSafetyInset

                // A soft unshifted halo makes the APP/LOGO FORM itself read clearly against the
                // background. This is deliberately not a stroke: it is a blurred contact shadow.
                // The two shifted terms then add the small 0/2/5 style depth used by iOS-like art.
                let formHalo = contactBlur[i]
                let formShadow = outside * amount * (
                    formHalo * 0.30 +
                    contact * 0.42 +
                    ambient * 0.16
                )
                let logoDrop = insideTileSafetyBand ? 0 : formShadow
                if logoDrop > 0.0001 {
                    result = mix(result, effectiveShadowLinear, amount: clamp(logoDrop, 0, 0.62))
                }
'''
if "let formHalo = contactBlur[i]" not in shadow:
    shadow = replace_once(shadow, old_drop, new_drop, "foreground form shadow")

# Keep the requested effect focused on the form shadow. The old bevel stays subtle and cannot
# become an outline; the visible depth now comes primarily from the blurred shadow around the form.
shadow = shadow.replace(
    "let darkBevel = logo * (1 - insideBelow) * 0.18 * amount",
    "let darkBevel = logo * (1 - insideBelow) * 0.10 * amount",
    1,
)
shadow = shadow.replace(
    "let lightBevel = logo * (1 - insideAbove) * 0.45 * amount",
    "let lightBevel = logo * (1 - insideAbove) * 0.18 * amount",
    1,
)

for token in [
    "let tileSafetyInset",
    "let formHalo = contactBlur[i]",
    "insideTileSafetyBand ? 0 : formShadow",
    "formHalo * 0.30",
]:
    if token not in shadow:
        raise SystemExit(f"form-shadow processor verification failed: {token}")

shadow_path.write_text(shadow, encoding="utf-8")


# -----------------------------------------------------------------------------
# Final runtime wiring. Run after all Tint+/Mono/no-rim and fast-preview patches.
# Every mode gets the same foreground-form shadow pass when the Shadows toggle is enabled.
# -----------------------------------------------------------------------------
ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")

# Shadows should work in ordinary Tint too, not only Smart Logo / Tint+.
ui = ui.replace(
    "logoShadows: snapshot.resolvedMode == .smartLogo || snapshot.tintVariant == .advanced",
    "logoShadows: true",
    1,
)

# If the user explicitly enabled Shadows, keep them visible even at Tint 100% + Background 100%.
# This changes only foreground-form depth; the tile perimeter remains protected by the processor.
ui = ui.replace(
    "guard snapshot.shadowsEnabled && !preserveSolidTint else {",
    "guard snapshot.shadowsEnabled else {",
    1,
)

if "logoShadows: true" not in ui:
    raise SystemExit("form-shadow runtime verification failed: all-mode shadow wiring missing")
if "guard snapshot.shadowsEnabled else {" not in ui:
    raise SystemExit("form-shadow runtime verification failed: enabled-shadow guard missing")

ui_path.write_text(ui, encoding="utf-8")
print("Visible foreground-form shadows restored for Mono/Tint/Tint+; outer tile sides/perimeter remain shadow-free")
