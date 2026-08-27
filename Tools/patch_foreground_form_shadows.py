from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"form-shadow patch failed: {label} marker not found")
    return text.replace(old, new, 1)


shadow_path = Path("OpaqueIconThemer/IconShadowProcessor.swift")
shadow = shadow_path.read_text(encoding="utf-8")

# Keep the 60 FPS preview cheap: process at the actual rendered size (256 px in live preview),
# while full export naturally uses its own real bitmap dimensions.
shadow = shadow.replace(
    "        let width = 512\n        let height = 512\n",
    "        let width = max(64, rendered.cgImage?.width ?? 512)\n        let height = max(64, rendered.cgImage?.height ?? 512)\n",
    1,
)

# An older Tint+ cleanup intentionally removed all outside-logo shadow/glow. Recreate a safe
# contact+ambient shadow only around detected foreground artwork after every no-rim patch has run.
if "let contactBlur = boxBlur(" not in shadow:
    marker = "        let innerBlur = boxBlur(\n"
    block = '''        let contactBlur = boxBlur(
            logoMask,
            width: width,
            height: height,
            radius: max(1, Int((5.0 * designScale).rounded()))
        )
        let ambientBlur = boxBlur(
            logoMask,
            width: width,
            height: height,
            radius: max(1, Int((12.0 * designScale).rounded()))
        )
'''
    shadow = replace_once(shadow, marker, block + marker, "contact blur insertion")

if "let contactOffset =" not in shadow:
    marker = "        let darkInnerOffset = max(1, Int((1.0 * designScale).rounded()))\n"
    block = '''        let contactOffset = max(1, Int((2.0 * designScale).rounded()))
        let ambientOffset = max(1, Int((5.0 * designScale).rounded()))
'''
    shadow = replace_once(shadow, marker, block + marker, "contact offset insertion")

if "let tileSafetyInset" not in shadow:
    marker = "        var output = renderedPixels\n"
    block = '''        // Absolute no-tile-shadow guarantee: the outer square icon perimeter is a dead zone
        // for this pass. Only internal app/logo forms may cast a visible shadow.
        let tileSafetyInset = max(4, Int((4.5 * designScale).rounded()))

'''
    shadow = replace_once(shadow, marker, block + marker, "tile safety inset")

if "let formHalo = contactBlur[i]" not in shadow:
    marker = "                let logo = clamp(logoMask[i], 0, 1)\n\n"
    block = '''                let contact = sample(
                    contactBlur,
                    width: width,
                    height: height,
                    x: x,
                    y: y - contactOffset
                )
                let ambient = sample(
                    ambientBlur,
                    width: width,
                    height: height,
                    x: x,
                    y: y - ambientOffset
                )
                let outside = 1 - logo
                let insideTileSafetyBand = x < tileSafetyInset ||
                    x >= width - tileSafetyInset ||
                    y < tileSafetyInset ||
                    y >= height - tileSafetyInset

                // Visible soft shadow outlining the APPLICATION/LOGO FORM, not the icon tile.
                // Unshifted halo defines the form; 2px contact + 5px ambient add depth downward.
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
    shadow = replace_once(shadow, marker, marker + block, "foreground form shadow insertion")

# Prevent the effect from turning back into a bevel/AA contour. Cast shadow carries the volume.
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
    "rendered.cgImage?.width",
    "let contactBlur = boxBlur(",
    "let tileSafetyInset",
    "let formHalo = contactBlur[i]",
    "insideTileSafetyBand ? 0 : formShadow",
]:
    if token not in shadow:
        raise SystemExit(f"form-shadow processor verification failed: {token}")

shadow_path.write_text(shadow, encoding="utf-8")


# Final runtime wiring: replace the ENTIRE old IconShadowProcessor call rather than depending on
# whatever logoShadows expression historical patches left behind.
ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")

call_pattern = re.compile(
    r"return\s+IconShadowProcessor\.shared\.apply\(.*?\)\s*\?\?\s*postProcessedOutput",
    re.S,
)
call_replacement = '''return IconShadowProcessor.shared.apply(
            source: snapshot.source,
            rendered: postProcessedOutput,
            surfaceColor: snapshot.backgroundTint,
            shadowColor: snapshot.shadowColor,
            strength: snapshot.shadowStrength,
            tintMix: snapshot.shadowTintMix,
            logoShadows: true
        ) ?? postProcessedOutput'''
ui, call_count = call_pattern.subn(call_replacement, ui, count=1)
if call_count != 1:
    raise SystemExit(f"form-shadow runtime verification failed: final IconShadowProcessor calls replaced={call_count}")

# Shadows toggle is authoritative. Remove historical bypasses for solid Tint / outline-free Tint+;
# outer-tile safety now lives inside the processor itself.
ui, guard_count = re.subn(
    r"guard\s+snapshot\.shadowsEnabled(?:\s*&&[^\{]+)?\s+else\s*\{",
    "guard snapshot.shadowsEnabled else {",
    ui,
    count=1,
)
if guard_count == 0 and "guard snapshot.shadowsEnabled else {" not in ui:
    raise SystemExit("form-shadow runtime verification failed: shadow guard missing")

if "logoShadows: true" not in ui or "rendered: postProcessedOutput" not in ui:
    raise SystemExit("form-shadow runtime verification failed: final all-mode shadow call incomplete")

ui_path.write_text(ui, encoding="utf-8")
print("Foreground form shadows wired in all modes: visible around app/logo forms, zero on outer tile sides/perimeter, 256px live-preview pass preserved")
