from pathlib import Path

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")


def insert_once(marker: str, addition: str, label: str) -> None:
    global ui
    if addition.strip() in ui:
        return
    if marker not in ui:
        raise SystemExit(f"Smart Logo patch failed: {label} marker not found")
    ui = ui.replace(marker, marker + addition, 1)


# One master switch controls the gradient for both Smart Logo and Advanced Tint+.
insert_once(
    "        let gradientStrength: CGFloat\n",
    "        let gradientEnabled: Bool\n",
    "RenderSnapshot gradientEnabled",
)
insert_once(
    "    @State private var gradientStrength: Double = 0.45\n",
    "    @State private var gradientEnabled = true\n",
    "gradientEnabled state",
)
insert_once(
    "        .onChange(of: gradientStrength) { _ in markPreviewDirty() }\n",
    "        .onChange(of: gradientEnabled) { _ in markPreviewDirty() }\n",
    "gradientEnabled onChange",
)

# Add the visible master switch at the top of the existing gradient card. Later Tint+ controls
# (including the custom gradient colour switch) stay available, but the renderer receives zero
# gradient strength whenever this switch is off.
gradient_start = ui.find("    private var gradientCard: some View {")
gradient_end = ui.find("    private var shadowsCard: some View {", gradient_start)
if gradient_start < 0 or gradient_end < 0:
    raise SystemExit("Smart Logo patch failed: gradientCard range not found")

gradient_block = ui[gradient_start:gradient_end]
if 'Toggle("Градиент", isOn: $gradientEnabled)' not in gradient_block:
    marker = "                VStack(spacing: 18) {\n"
    replacement = '''                VStack(spacing: 18) {\n                    Toggle("Градиент", isOn: $gradientEnabled)\n                        .font(.body.weight(.medium))\n\n                    Divider().opacity(0.35)\n'''
    if marker not in gradient_block:
        raise SystemExit("Smart Logo patch failed: gradientCard VStack marker not found")
    gradient_block = gradient_block.replace(marker, replacement, 1)
    ui = ui[:gradient_start] + gradient_block + ui[gradient_end:]

# Persist the switch into the render snapshot.
make_start = ui.find("    private func makeRenderSnapshot() -> RenderSnapshot?")
make_end = ui.find("    private static func render(_ snapshot: RenderSnapshot)", make_start)
if make_start < 0 or make_end < 0:
    raise SystemExit("Smart Logo patch failed: makeRenderSnapshot range not found")

make_block = ui[make_start:make_end]
if "gradientEnabled: gradientEnabled" not in make_block:
    old = "            gradientStrength: CGFloat(gradientStrength),\n"
    new = old + "            gradientEnabled: gradientEnabled,\n"
    if old not in make_block:
        raise SystemExit("Smart Logo patch failed: snapshot gradientStrength marker not found")
    make_block = make_block.replace(old, new, 1)
    ui = ui[:make_start] + make_block + ui[make_end:]

# The switch is intentionally independent of all tint/intensity sliders. It simply makes the
# effective gradient strength zero. Apply it to both Smart Logo and the final OutlineFree Tint+.
render_start = ui.find("    private static func render(_ snapshot: RenderSnapshot)")
render_end = ui.find("    private func renderCurrentIcon()", render_start)
if render_start < 0 or render_end < 0:
    raise SystemExit("Smart Logo patch failed: render range not found")

render_block = ui[render_start:render_end]
needle = "gradientStrength: snapshot.gradientStrength"
occurrences = render_block.count(needle)
if occurrences < 2:
    raise SystemExit(f"Smart Logo patch failed: expected >=2 gradientStrength calls, found {occurrences}")
render_block = render_block.replace(
    needle,
    "gradientStrength: snapshot.gradientEnabled ? snapshot.gradientStrength : 0.0",
)

# Smart Logo gets a strict final two-material edge pass after background intensity and BEFORE the
# internal-depth pass. This scrubs source AA fringe, white remnants and coloured gradient fringe.
# AppleMonoDepthProcessor is then allowed to work only inside the logo and cannot touch the edge.
old_mono_depth = '''            baseOutput = AppleMonoDepthProcessor.shared.apply(\n                source: snapshot.source,\n                rendered: backgroundAdjusted,\n                strength: 1.0\n            ) ?? backgroundAdjusted\n'''
new_mono_depth = '''            let outlineFreeSmartLogo = OutlineFreeSmartLogoProcessor.shared.apply(\n                source: snapshot.source,\n                rendered: backgroundAdjusted\n            ) ?? backgroundAdjusted\n\n            baseOutput = AppleMonoDepthProcessor.shared.apply(\n                source: snapshot.source,\n                rendered: outlineFreeSmartLogo,\n                strength: 1.0\n            ) ?? outlineFreeSmartLogo\n'''
if old_mono_depth not in render_block:
    raise SystemExit("Smart Logo patch failed: AppleMonoDepthProcessor render block not found")
render_block = render_block.replace(old_mono_depth, new_mono_depth, 1)
ui = ui[:render_start] + render_block + ui[render_end:]

ui_path.write_text(ui, encoding="utf-8")

# The old Mono depth pass forcibly mixed WHITE back across the entire soft logo mask. That was the
# remaining reason a coloured Smart Logo gradient/tint acquired a white contour: the base renderer
# made a coloured edge, then the depth pass whitened that same edge again. The base Smart Logo body
# is already white when gradient is off, so this forced fill is no longer needed. All actual depth
# signals are already restricted to eroded interiorSupport by the preceding Mono patches.
depth_path = Path("OpaqueIconThemer/AppleMonoDepthProcessor.swift")
depth = depth_path.read_text(encoding="utf-8")

old_fill = '''                // The body is white. Saturate the detector's soft AA coverage quickly enough\n                // that the old gray base ramp cannot remain visible as a rim, while keeping the\n                // last fractional edge pixels antialiased against the blue background.\n                let cleanFillCoverage = smoothstep(\n                    edge0: 0.012,\n                    edge1: 0.42,\n                    value: clamp(logo, 0, 1)\n                )\n                result = mix(result, white, amount: cleanFillCoverage)\n\n'''
new_fill = '''                // The final Smart Logo edge was already resolved by OutlineFreeSmartLogoProcessor.\n                // Do NOT force white back through the soft mask here: doing so would manufacture a\n                // white contour whenever the logo material is tinted/gradient-coloured. Depth below\n                // is interior-only, so the finalized boundary stays untouched.\n\n'''
if old_fill not in depth:
    raise SystemExit("Smart Logo patch failed: final Mono white-fill block not found")
depth = depth.replace(old_fill, new_fill, 1)
depth_path.write_text(depth, encoding="utf-8")

# Hard verification so CI cannot silently build the old behaviour.
checks = [
    ("let gradientEnabled: Bool", ui),
    ("@State private var gradientEnabled = true", ui),
    ('Toggle("Градиент", isOn: $gradientEnabled)', ui),
    ("OutlineFreeSmartLogoProcessor.shared.apply(", ui),
    ("snapshot.gradientEnabled ? snapshot.gradientStrength : 0.0", ui),
]
for token, haystack in checks:
    if token not in haystack:
        raise SystemExit(f"Smart Logo patch failed verification: {token}")
if "cleanFillCoverage" in depth:
    raise SystemExit("Smart Logo patch failed verification: forced cleanFillCoverage survived")

print("Smart Logo no-rim tint path applied; master gradient toggle wired for Smart Logo and Tint+")
