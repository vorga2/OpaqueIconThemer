from pathlib import Path
import re

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")


def must_replace(old: str, new: str, label: str, count: int = 1) -> None:
    global text
    if old not in text:
        raise SystemExit(f"default preset patch failed: {label} marker not found")
    text = text.replace(old, new, count)


# -----------------------------------------------------------------------------
# Requested default preset.
# Background #4581B7, icon #C9FFFB, both tint strengths 100%.
# Icon gradient ON, background gradient OFF, custom gradient colour OFF.
# Gradient starts at 50%, strength 30%.
# Element shadows ON, black, 25%, tint mix 0%.
# -----------------------------------------------------------------------------
must_replace(
    "    @State private var tintColor: Color = .blue\n",
    "    @State private var tintColor: Color = Color(red: 69.0 / 255.0, green: 129.0 / 255.0, blue: 183.0 / 255.0)\n",
    "background tint default",
)
must_replace(
    "    @State private var iconTintColor: Color = .blue\n",
    "    @State private var iconTintColor: Color = Color(red: 201.0 / 255.0, green: 1.0, blue: 251.0 / 255.0)\n",
    "icon tint default",
)

# Historical patches may still carry the original numeric defaults. Normalize exact state lines
# late in the build so later renderer/UI patches cannot silently restore old values.
text, n = re.subn(r"    @State private var tintIntensity: Double = [0-9.]+\n", "    @State private var tintIntensity: Double = 1.0\n", text, count=1)
if n != 1:
    raise SystemExit("default preset patch failed: tintIntensity state missing")
text, n = re.subn(r"    @State private var backgroundIntensity: Double = [0-9.]+\n", "    @State private var backgroundIntensity: Double = 1.0\n", text, count=1)
if n != 1:
    raise SystemExit("default preset patch failed: backgroundIntensity state missing")
text, n = re.subn(r"    @State private var gradientStart: Double = [0-9.]+\n", "    @State private var gradientStart: Double = 0.50\n", text, count=1)
if n != 1:
    raise SystemExit("default preset patch failed: gradientStart state missing")
text, n = re.subn(r"    @State private var gradientStrength: Double = [0-9.]+\n", "    @State private var gradientStrength: Double = 0.30\n", text, count=1)
if n != 1:
    raise SystemExit("default preset patch failed: gradientStrength state missing")
text, n = re.subn(r"    @State private var shadowStrength: Double = [0-9.]+\n", "    @State private var shadowStrength: Double = 0.25\n", text, count=1)
if n != 1:
    raise SystemExit("default preset patch failed: shadowStrength state missing")
text, n = re.subn(r"    @State private var shadowTintMix: Double = [0-9.]+\n", "    @State private var shadowTintMix: Double = 0.0\n", text, count=1)
if n != 1:
    raise SystemExit("default preset patch failed: shadowTintMix state missing")

# Explicit boolean defaults. These are already the intended values in most historical builds, but
# enforce them here so this patch is the canonical requested preset.
text = re.sub(r"    @State private var shadowsEnabled = (?:true|false)\n", "    @State private var shadowsEnabled = true\n", text, count=1)
text = re.sub(r"    @State private var gradientEnabled = (?:true|false)\n", "    @State private var gradientEnabled = true\n", text, count=1)
text = re.sub(r"    @State private var customGradientColorEnabled = (?:true|false)\n", "    @State private var customGradientColorEnabled = false\n", text, count=1)
text = re.sub(r"    @State private var backgroundGradientEnabled = (?:true|false)\n", "    @State private var backgroundGradientEnabled = false\n", text, count=1)
text = re.sub(r"    @State private var shadowColor: Color = .*\n", "    @State private var shadowColor: Color = .black\n", text, count=1)


# -----------------------------------------------------------------------------
# Simple Tint means ONLY global whole-image tint.
# No switch back to split background/foreground tuning, no background gradient, no icon gradient,
# no element-shadow material pass. Tint+ / Apple Mono keep all advanced controls.
# -----------------------------------------------------------------------------
# Keep the historical state only for source compatibility, but make it permanently true and hide
# its toggle. Rendering is also hard-wired below, so stale state cannot re-enable split mode.
text = text.replace("    @State private var editUnifiedTint = true\n", "    @State private var editUnifiedTint = true\n", 1)

# Remove the visible `Редактировать общий тинт` toggle from the Simple Tint colour card.
toggle_pattern = re.compile(
    r'''\n\s*if resolvedMode == \.tint && tintVariant == \.simple \{\n\s*Toggle\(isOn: \$editUnifiedTint\) \{.*?\n\s*Divider\(\)\.opacity\(0\.35\)\n\s*\}\n''',
    re.S,
)
text, toggle_count = toggle_pattern.subn("\n", text, count=1)
if toggle_count != 1:
    raise SystemExit(f"default preset patch failed: simple tint toggle removals={toggle_count}")

# Simple mode's single picker is always the global tint picker.
old_label = '''                        resolvedMode == .tint && tintVariant == .advanced
                            ? "Цвет фона"
                            : (resolvedMode == .tint && tintVariant == .simple && editUnifiedTint
                                ? "Общий тинт"
                                : "Цвет тинта"),
'''
new_label = '''                        resolvedMode == .tint && tintVariant == .advanced
                            ? "Цвет фона"
                            : (resolvedMode == .tint && tintVariant == .simple
                                ? "Общий тинт"
                                : "Цвет тинта"),
'''
must_replace(old_label, new_label, "simple tint picker label")

# Always show exactly one intensity slider in Simple Tint. Advanced/Mono retain their own controls.
text = text.replace(
    "if resolvedMode == .tint && tintVariant == .simple && editUnifiedTint {",
    "if resolvedMode == .tint && tintVariant == .simple {",
    1,
)

# Hard-wire snapshot semantics: Simple Tint is always global tint and its strength is the single
# synchronized value. There is no path back to CombinedTintIntensityProcessor for Simple Tint.
old_unified = "        let unifiedSimpleTint = resolvedMode == .tint && tintVariant == .simple && editUnifiedTint\n"
new_unified = "        let unifiedSimpleTint = resolvedMode == .tint && tintVariant == .simple\n"
must_replace(old_unified, new_unified, "simple global tint snapshot")

# Hide background-gradient card in Simple Tint. It belongs to Tint+ only.
text = text.replace(
    '''                        if resolvedMode == .tint {
                            backgroundGradientCard
                        }
''',
    '''                        if resolvedMode == .tint && tintVariant == .advanced {
                            backgroundGradientCard
                        }
''',
    1,
)

# Hide all element-shadow controls in Simple Tint. Shadows remain available in Tint+ / Apple Mono.
body_start = text.find("                LazyVStack(spacing: 18) {")
body_end = text.find("    private var appHeader: some View", body_start)
if body_start < 0 or body_end < 0:
    raise SystemExit("default preset patch failed: editor body range not found")
body = text[body_start:body_end]
if "if !(resolvedMode == .tint && tintVariant == .simple)" not in body:
    if "                        shadowsCard\n" not in body:
        raise SystemExit("default preset patch failed: shadowsCard body marker missing")
    body = body.replace(
        "                        shadowsCard\n",
        '''                        if !(resolvedMode == .tint && tintVariant == .simple) {
                            shadowsCard
                        }
''',
        1,
    )
    text = text[:body_start] + body + text[body_end:]

# The icon/logo gradient card should never appear for Simple Tint. Normalize the common late-build
# condition if an older patch left a broad Tint condition behind.
text = text.replace(
    "                        if resolvedMode == .smartLogo || resolvedMode == .tint {\n                            gradientCard\n                        }\n",
    "                        if resolvedMode == .smartLogo || (resolvedMode == .tint && tintVariant == .advanced) {\n                            gradientCard\n                        }\n",
    1,
)

# Guarantee that Simple Tint exits immediately after GlobalColorTintProcessor produced baseOutput.
# This prevents late background-gradient/shadow passes from altering the supposedly simple mode.
render_start = text.find("    private static func render(_ snapshot: RenderSnapshot)")
render_end = text.find("    private func renderCurrentIcon()", render_start)
if render_start < 0 or render_end < 0:
    raise SystemExit("default preset patch failed: render range not found")
render_block = text[render_start:render_end]
return_marker = "        guard let baseOutput else { return nil }\n"
if "Simple Tint is strictly global-only" not in render_block:
    if return_marker not in render_block:
        raise SystemExit("default preset patch failed: baseOutput guard missing")
    render_block = render_block.replace(
        return_marker,
        return_marker + '''
        // Simple Tint is strictly global-only: one colour + one whole-image tint strength.
        // No layer segmentation, background gradient, icon gradient or element-shadow pass may
        // modify this result. Advanced material controls belong exclusively to Tint+/Apple Mono.
        if snapshot.resolvedMode == .tint && snapshot.tintVariant == .simple {
            return baseOutput
        }
''',
        1,
    )
text = text[:render_start] + render_block + text[render_end:]

# Update descriptions so the UI no longer advertises a split Simple Tint mode.
text = text.replace(
    '''                : (editUnifiedTint
                    ? "Общий Tint как в LunaPic: один оттенок красит всю картинку целиком без разделения на фон и элементы, сохраняя светлоту, блики, тени и объём."
                    : "Обычный Tint: один цвет, но силу фона и элементов можно править раздельно.")
''',
    '''                : "Обычный Tint: один общий оттенок красит всю иконку целиком без разделения на фон и элементы."
''',
    1,
)
text = text.replace(
    '''            return editUnifiedTint
                ? "Как Color Tint в LunaPic: оттенок применяется ко всей иконке. При 100% белые детали остаются светлыми, тёмные — тёмными, поэтому рельеф не превращается в плоскую заливку."
                : "Раздельный режим оставляет один цвет, но позволяет отдельно настроить фон и элементы."
''',
    '''            return "Один общий tint применяется ко всей иконке. Раздельные фон/элементы, градиенты и тени доступны только в расширенных режимах."
''',
    1,
)

# Final verification: fail CI rather than shipping a partially-applied preset.
required = [
    "69.0 / 255.0, green: 129.0 / 255.0, blue: 183.0 / 255.0",
    "201.0 / 255.0, green: 1.0, blue: 251.0 / 255.0",
    "@State private var tintIntensity: Double = 1.0",
    "@State private var backgroundIntensity: Double = 1.0",
    "@State private var gradientStart: Double = 0.50",
    "@State private var gradientStrength: Double = 0.30",
    "@State private var gradientEnabled = true",
    "@State private var customGradientColorEnabled = false",
    "@State private var backgroundGradientEnabled = false",
    "@State private var shadowsEnabled = true",
    "@State private var shadowColor: Color = .black",
    "@State private var shadowStrength: Double = 0.25",
    "@State private var shadowTintMix: Double = 0.0",
    "let unifiedSimpleTint = resolvedMode == .tint && tintVariant == .simple",
    "Simple Tint is strictly global-only",
    "if resolvedMode == .tint && tintVariant == .advanced {\n                            backgroundGradientCard",
    "if !(resolvedMode == .tint && tintVariant == .simple) {\n                            shadowsCard",
]
for token in required:
    if token not in text:
        raise SystemExit(f"default preset patch failed verification: {token}")
if "Редактировать общий тинт" in text:
    raise SystemExit("default preset patch failed verification: legacy Simple Tint toggle survived")

path.write_text(text, encoding="utf-8")
print("Requested defaults applied; Simple Tint locked to one global whole-image tint with no advanced material effects")
