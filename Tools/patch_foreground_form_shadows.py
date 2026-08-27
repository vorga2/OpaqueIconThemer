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

# Insert independently from the exact offset block because earlier build patches may rewrite the
# surrounding comments/spacing. The output marker is stable and immediately precedes the pixel pass.
if "let tileSafetyInset" not in shadow:
    output_marker = "        var output = renderedPixels\n"
    safety = '''        // Keep the outer square app-icon tile perfectly clean. Foreground-form
        // shadows are forcibly zero inside this perimeter band, so there can be no side shadow
        // or drop shadow around the tile itself.
        let tileSafetyInset = max(4, Int((4.5 * designScale).rounded()))

'''
    shadow = replace_once(shadow, output_marker, safety + output_marker, "tile safety inset")

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

                // Visible shadow around the detected APP/LOGO FORM. This is a soft blurred
                // contact shadow, not a stroke and not a silhouette bevel. The shifted terms add
                // a small downward depth while the unshifted halo keeps the form readable.
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

# Keep any existing internal bevel very subtle: the requested visible depth comes from the shadow
# around the form, not from drawing an outline on the form itself.
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
if "logoShadows: true" not in ui:
    marker = "logoShadows: snapshot.resolvedMode == .smartLogo || snapshot.tintVariant == .advanced"
    if marker in ui:
        ui = ui.replace(marker, "logoShadows: true", 1)
    else:
        # Be resilient to line wrapping introduced by earlier runtime patches.
        import re
        ui, count = re.subn(
            r"logoShadows:\s*snapshot\.resolvedMode\s*==\s*\.smartLogo\s*\|\|\s*snapshot\.tintVariant\s*==\s*\.advanced",
            "logoShadows: true",
            ui,
            count=1,
        )
        if count == 0:
            raise SystemExit("form-shadow runtime verification failed: logoShadows call marker missing")

# If the user explicitly enabled Shadows, keep them visible even at Tint 100% + Background 100%.
if "guard snapshot.shadowsEnabled else {" not in ui:
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
