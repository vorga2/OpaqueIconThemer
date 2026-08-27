from pathlib import Path
import re

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")


def insert_once(marker: str, addition: str, label: str) -> None:
    global text
    if addition.strip() in text:
        return
    if marker not in text:
        raise SystemExit(f"Tint+ v4 patch failed: {label} marker not found")
    text = text.replace(marker, marker + addition, 1)


# Snapshot values used by the final advanced compositor.
insert_once(
    "        let gradientStrength: CGFloat\n",
    "        let customGradientColorEnabled: Bool\n        let gradientTint: UIColor\n",
    "RenderSnapshot gradient fields",
)

# UI state. Custom gradient colour is OFF by default, so the gradient continues to use the
# background colour unless the user explicitly enables the custom picker.
insert_once(
    "    @State private var gradientStrength: Double = 0.45\n",
    "    @State private var customGradientColorEnabled = false\n    @State private var gradientTintColor: Color = .blue\n",
    "gradient state",
)

insert_once(
    "    private var shadowColorKey: String { UIColor(shadowColor).description }\n",
    "    private var gradientTintColorKey: String { UIColor(gradientTintColor).description }\n",
    "gradient colour key",
)

insert_once(
    "        .onChange(of: gradientStrength) { _ in markPreviewDirty() }\n",
    "        .onChange(of: customGradientColorEnabled) { _ in markPreviewDirty() }\n        .onChange(of: gradientTintColorKey) { _ in markPreviewDirty() }\n",
    "gradient onChange",
)

# Add the switch + picker only to Advanced Tint+. Mono keeps its existing gradient controls.
gradient_start = text.find("    private var gradientCard: some View {")
gradient_end = text.find("    private var shadowsCard: some View {", gradient_start)
if gradient_start < 0 or gradient_end < 0:
    raise SystemExit("Tint+ v4 patch failed: gradientCard range not found")

gradient_block = text[gradient_start:gradient_end]
if "Кастомный цвет градиента" not in gradient_block:
    marker = "                VStack(spacing: 18) {\n"
    addition = '''                VStack(spacing: 18) {\n                    if resolvedMode == .tint && tintVariant == .advanced {\n                        Toggle(\"Кастомный цвет градиента\", isOn: $customGradientColorEnabled)\n                            .font(.body.weight(.medium))\n\n                        if customGradientColorEnabled {\n                            Divider().opacity(0.35)\n                            ColorPicker(\"Цвет градиента\", selection: $gradientTintColor, supportsOpacity: false)\n                                .font(.body.weight(.medium))\n                        }\n\n                        Divider().opacity(0.35)\n                    }\n'''
    if marker not in gradient_block:
        raise SystemExit("Tint+ v4 patch failed: gradientCard VStack marker not found")
    gradient_block = gradient_block.replace(marker, addition, 1)
    text = text[:gradient_start] + gradient_block + text[gradient_end:]

# Add snapshot values in makeRenderSnapshot only.
make_start = text.find("    private func makeRenderSnapshot() -> RenderSnapshot?")
make_end = text.find("    private static func render(_ snapshot: RenderSnapshot)", make_start)
if make_start < 0 or make_end < 0:
    raise SystemExit("Tint+ v4 patch failed: makeRenderSnapshot range not found")

make_block = text[make_start:make_end]
if "customGradientColorEnabled: customGradientColorEnabled" not in make_block:
    old = "            gradientStrength: CGFloat(gradientStrength),\n"
    new = old + "            customGradientColorEnabled: customGradientColorEnabled,\n            gradientTint: customGradientColorEnabled ? UIColor(gradientTintColor) : backgroundTint,\n"
    if old not in make_block:
        raise SystemExit("Tint+ v4 patch failed: RenderSnapshot constructor gradient marker not found")
    make_block = make_block.replace(old, new, 1)
    text = text[:make_start] + make_block + text[make_end:]

# Final runtime call: pass custom gradient colour and restore shadows INSIDE the outline-free
# compositor. The generic IconShadowProcessor remains bypassed for advanced Tint+ because its
# silhouette bevel is exactly the kind of contour we do not want.
call_start = text.find("OutlineFreeAdvancedTintProcessor.shared.apply(")
if call_start < 0:
    raise SystemExit("Tint+ v4 patch failed: OutlineFreeAdvancedTintProcessor call not found")
call_end = text.find(")", call_start)
call_tail = text[call_start:call_start + 1400]
if "customGradientColorEnabled: snapshot.customGradientColorEnabled" not in call_tail:
    old = "                gradientStrength: snapshot.gradientStrength\n"
    new = '''                gradientStrength: snapshot.gradientStrength,\n                customGradientColorEnabled: snapshot.customGradientColorEnabled,\n                gradientTint: snapshot.gradientTint,\n                shadowsEnabled: snapshot.shadowsEnabled,\n                shadowColor: snapshot.shadowColor,\n                shadowStrength: snapshot.shadowStrength,\n                shadowTintMix: snapshot.shadowTintMix\n'''
    scoped = text[call_start:call_start + 1400]
    if old not in scoped:
        raise SystemExit("Tint+ v4 patch failed: OutlineFree call gradientStrength marker not found")
    scoped = scoped.replace(old, new, 1)
    text = text[:call_start] + scoped + text[call_start + 1400:]

# Update the visible runtime marker and source generation token so an install over the previous IPA
# can be distinguished immediately.
text = text.replace("Tint+ NoRim-3", "Tint+ NoRim-4")
text = text.replace("Tint+ NoRim-2", "Tint+ NoRim-4")
text = text.replace("oit.tintRendererGeneration.20260827.nooutline.v3", "oit.tintRendererGeneration.20260827.nooutline.v4")
text = text.replace("oit.tintRendererGeneration.20260827.nooutline.v2", "oit.tintRendererGeneration.20260827.nooutline.v4")

# Clarify the Advanced Tint gradient description without touching Mono text.
text = text.replace(
    '"Градиент применяется только к иконке, берёт цвет фона и не зависит от «Силы тинта»."',
    '"Градиент применяется только к материалу иконки и не зависит от «Силы тинта». По умолчанию используется цвет фона; кастомный цвет включается переключателем выше."',
)

# Hard verification.
required = [
    "let customGradientColorEnabled: Bool",
    "let gradientTint: UIColor",
    "@State private var customGradientColorEnabled = false",
    "Кастомный цвет градиента",
    "customGradientColorEnabled: snapshot.customGradientColorEnabled",
    "gradientTint: snapshot.gradientTint",
    "shadowsEnabled: snapshot.shadowsEnabled",
]
for item in required:
    if item not in text:
        raise SystemExit(f"Tint+ v4 patch failed final verification: {item}")

path.write_text(text, encoding="utf-8")
print("Tint+ NoRim-4 UI/runtime wired: custom gradient colour default-off, internal shadows restored, final compositor owns all advanced effects")
