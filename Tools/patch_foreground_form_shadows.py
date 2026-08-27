from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"form-shadow patch failed: {label} marker not found")
    return text.replace(old, new, 1)


shadow_path = Path("OpaqueIconThemer/IconShadowProcessor.swift")
shadow = shadow_path.read_text(encoding="utf-8")

# Live preview is 256 px; export stays at the renderer's real size. Using the actual rendered
# dimensions keeps the shadow pass fast in preview instead of upscaling every frame to 512 px.
shadow = shadow.replace(
    "        let width = 512\n        let height = 512\n",
    "        let width = max(64, rendered.cgImage?.width ?? 512)\n        let height = max(64, rendered.cgImage?.height ?? 512)\n",
    1,
)

# patch_tint_strength_fill_only.py intentionally removes the old outside contact/drop shadow.
# Recreate it here AFTER every no-rim patch, but only for the detected foreground form.
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
    block = '''        // Hard exclusion band around the entire app-icon tile. Shadows are allowed around
        // internal artwork only; they are forcibly zero near all four outer sides/corners.
        let tileSafetyInset = max(4, Int((4.5 * designScale).rounded()))

'''
    shadow = replace_once(shadow, marker, block + marker, "tile safety inset")

# Insert the visible form-shadow block immediately after the logo coverage is read. This location
# survives the old cleanup patch because only the removed outside-shadow block changed.
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

                // Soft shadow around the detected APPLICATION/LOGO FORM itself. This is not a
                // stroke: the unshifted halo is blurred, while the 2 px + 5 px shifted terms create
                // visible contact/ambient depth. Nothing is painted on the outer tile perimeter.
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

# Keep internal bevels subtle; the requested volume comes from the form's cast/contact shadow.
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


# Final runtime wiring: Shadows toggle must control the foreground-form pass in every mode.
ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")

if "logoShadows: true" not in ui:
    ui, count = re.subn(
        r"logoShadows:\s*snapshot\.resolvedMode\s*==\s*\.smartLogo\s*\|\|\s*snapshot\.tintVariant\s*==\s*\.advanced",
        "logoShadows: true",
        ui,
        count=1,
    )
    if count == 0:
        raise SystemExit("form-shadow runtime verification failed: logoShadows marker missing")

# Older no-rim logic may contain extra conditions such as !preserveSolidTint or
# !outlineFreeAdvanced. Once the user explicitly enables Shadows, the final shadow pass should run;
# tile safety is enforced inside IconShadowProcessor instead.
ui, guard_count = re.subn(
    r"guard\s+snapshot\.shadowsEnabled(?:\s*&&[^\{]+)?\s+else\s*\{",
    "guard snapshot.shadowsEnabled else {",
    ui,
    count=1,
)
if guard_count == 0 and "guard snapshot.shadowsEnabled else {" not in ui:
    raise SystemExit("form-shadow runtime verification failed: shadow guard missing")

if "logoShadows: true" not in ui or "guard snapshot.shadowsEnabled else {" not in ui:
    raise SystemExit("form-shadow runtime verification failed: final shadow wiring incomplete")

ui_path.write_text(ui, encoding="utf-8")
print("Foreground form shadows restored after no-rim cleanup: visible around app/logo shapes, zero on tile perimeter, preview uses native 256px shadow pass")
