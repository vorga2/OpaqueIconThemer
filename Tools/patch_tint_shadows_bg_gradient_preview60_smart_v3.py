from pathlib import Path
import re

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")


def must_replace(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"Tint/Smart v3 patch failed: {label} marker not found")
    return text.replace(old, new, 1)


# -----------------------------------------------------------------------------
# 60 Hz live preview scheduler.
# -----------------------------------------------------------------------------
ui = ui.replace(
    "private let liquidPreviewTicker = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()",
    "private let liquidPreviewTicker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()",
    1,
)
ui = ui.replace(
    "DispatchQueue.global(qos: .userInitiated).async {",
    "DispatchQueue.global(qos: .userInteractive).async {",
    1,
)

completion_old = '''                renderedRevision = revision
                renderInFlight = false
'''
completion_new = '''                renderedRevision = revision
                renderInFlight = false

                // If the user moved a slider again while the previous frame was rendering,
                // immediately start the newest frame instead of waiting for another debounce.
                // Combined with the 60 Hz ticker this makes the custom preview track controls at
                // display cadence whenever the renderer can keep up.
                if previewRevision != renderedRevision {
                    refreshPreviewIfNeeded(force: true)
                }
'''
ui = must_replace(ui, completion_old, completion_new, "preview completion")


# -----------------------------------------------------------------------------
# Background-gradient UI model: 2/3/4 colours + three requested directions.
# -----------------------------------------------------------------------------
enum_marker = "private enum LGLTintVariant: String, CaseIterable, Hashable {\n"
if "private enum LGLBackgroundGradientDirection" not in ui:
    enum_code = '''private enum LGLBackgroundGradientDirection: String, CaseIterable, Hashable {
    case bottomToTop
    case topToBottom
    case rightToLeft

    var title: String {
        switch self {
        case .bottomToTop: return "Снизу вверх"
        case .topToBottom: return "Сверху вниз"
        case .rightToLeft: return "Справа налево"
        }
    }
}

'''
    if enum_marker not in ui:
        raise SystemExit("Tint/Smart v3 patch failed: tint variant enum marker not found")
    ui = ui.replace(enum_marker, enum_code + enum_marker, 1)

# Snapshot fields are added after the final Tint+ v4 gradient fields.
snapshot_marker = "        let gradientTint: UIColor\n"
if "let backgroundGradientEnabled: Bool" not in ui:
    ui = must_replace(
        ui,
        snapshot_marker,
        snapshot_marker + '''        let backgroundGradientEnabled: Bool
        let backgroundGradientColors: [UIColor]
        let backgroundGradientDirection: LGLBackgroundGradientDirection
''',
        "background-gradient snapshot fields",
    )

state_marker = "    @State private var gradientTintColor: Color = .blue\n"
if "@State private var backgroundGradientEnabled" not in ui:
    ui = must_replace(
        ui,
        state_marker,
        state_marker + '''    @State private var backgroundGradientEnabled = false
    @State private var backgroundGradientColor2: Color = .purple
    @State private var backgroundGradientColor3: Color = .cyan
    @State private var backgroundGradientColor4: Color = .blue
    @State private var backgroundGradientColorCount = 2
    @State private var backgroundGradientDirection: LGLBackgroundGradientDirection = .topToBottom
''',
        "background-gradient states",
    )

key_marker = "    private var gradientTintColorKey: String { UIColor(gradientTintColor).description }\n"
if "backgroundGradientColor2Key" not in ui:
    ui = must_replace(
        ui,
        key_marker,
        key_marker + '''    private var backgroundGradientColor2Key: String { UIColor(backgroundGradientColor2).description }
    private var backgroundGradientColor3Key: String { UIColor(backgroundGradientColor3).description }
    private var backgroundGradientColor4Key: String { UIColor(backgroundGradientColor4).description }
''',
        "background-gradient colour keys",
    )

change_marker = "        .onChange(of: gradientTintColorKey) { _ in markPreviewDirty() }\n"
if ".onChange(of: backgroundGradientEnabled)" not in ui:
    ui = must_replace(
        ui,
        change_marker,
        change_marker + '''        .onChange(of: backgroundGradientEnabled) { _ in markPreviewDirty() }
        .onChange(of: backgroundGradientColor2Key) { _ in markPreviewDirty() }
        .onChange(of: backgroundGradientColor3Key) { _ in markPreviewDirty() }
        .onChange(of: backgroundGradientColor4Key) { _ in markPreviewDirty() }
        .onChange(of: backgroundGradientColorCount) { _ in markPreviewDirty() }
        .onChange(of: backgroundGradientDirection) { _ in markPreviewDirty() }
''',
        "background-gradient onChange handlers",
    )

# Show the new card in every Tint mode, directly after the colour card.
body_marker = '''                        colorCard

                        if resolvedMode == .smartLogo ||
'''
if "backgroundGradientCard" not in ui[ui.find("LazyVStack"):ui.find("private var appHeader")]:
    ui = must_replace(
        ui,
        body_marker,
        '''                        colorCard

                        if resolvedMode == .tint {
                            backgroundGradientCard
                        }

                        if resolvedMode == .smartLogo ||
''',
        "background-gradient card visibility",
    )

# Insert the card before the existing icon/logo gradient card.
card_marker = "    private var gradientCard: some View {\n"
if "private var backgroundGradientCard" not in ui:
    card = '''    private var backgroundGradientCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Градиент фона", symbol: "rectangle.split.3x1")
            LGLGlassCard {
                VStack(spacing: 18) {
                    Toggle("Градиент фона", isOn: $backgroundGradientEnabled)
                        .font(.body.weight(.medium))

                    if backgroundGradientEnabled {
                        Divider().opacity(0.35)

                        LGLSegmentedControl(
                            values: [2, 3, 4],
                            selection: $backgroundGradientColorCount,
                            title: { "\\($0) цвета" }
                        )

                        Divider().opacity(0.35)
                        ColorPicker("Цвет 1", selection: $tintColor, supportsOpacity: false)
                            .font(.body.weight(.medium))
                        Divider().opacity(0.35)
                        ColorPicker("Цвет 2", selection: $backgroundGradientColor2, supportsOpacity: false)
                            .font(.body.weight(.medium))

                        if backgroundGradientColorCount >= 3 {
                            Divider().opacity(0.35)
                            ColorPicker("Цвет 3", selection: $backgroundGradientColor3, supportsOpacity: false)
                                .font(.body.weight(.medium))
                        }

                        if backgroundGradientColorCount >= 4 {
                            Divider().opacity(0.35)
                            ColorPicker("Цвет 4", selection: $backgroundGradientColor4, supportsOpacity: false)
                                .font(.body.weight(.medium))
                        }

                        Divider().opacity(0.35)
                        Text("Направление")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LGLSegmentedControl(
                            values: LGLBackgroundGradientDirection.allCases,
                            selection: $backgroundGradientDirection,
                            title: { $0.title }
                        )
                    }

                    Text("Фоновый градиент меняет только материал фона и не трогает геометрию/край иконки.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

'''
    if card_marker not in ui:
        raise SystemExit("Tint/Smart v3 patch failed: gradientCard marker not found")
    ui = ui.replace(card_marker, card + card_marker, 1)

# Persist gradient state in RenderSnapshot.
make_start = ui.find("    private func makeRenderSnapshot() -> RenderSnapshot?")
make_end = ui.find("    private static func render(_ snapshot: RenderSnapshot)", make_start)
if make_start < 0 or make_end < 0:
    raise SystemExit("Tint/Smart v3 patch failed: makeRenderSnapshot range not found")
make_block = ui[make_start:make_end]
if "backgroundGradientEnabled: backgroundGradientEnabled" not in make_block:
    marker = "            gradientTint: customGradientColorEnabled ? UIColor(gradientTintColor) : backgroundTint,\n"
    addition = '''            backgroundGradientEnabled: backgroundGradientEnabled,
            backgroundGradientColors: Array([
                backgroundTint,
                UIColor(backgroundGradientColor2),
                UIColor(backgroundGradientColor3),
                UIColor(backgroundGradientColor4)
            ].prefix(max(2, min(4, backgroundGradientColorCount)))),
            backgroundGradientDirection: backgroundGradientDirection,
'''
    if marker not in make_block:
        raise SystemExit("Tint/Smart v3 patch failed: final gradientTint constructor marker not found")
    make_block = make_block.replace(marker, marker + addition, 1)
    ui = ui[:make_start] + make_block + ui[make_end:]


# -----------------------------------------------------------------------------
# Advanced Tint+: background gradient lives inside the same strict no-rim compositor.
# Disable its old subtle shadow implementation; one final interior-only shadow pass below owns
# shadows for BOTH ordinary Tint and Tint+, so the UI has a clearly visible and consistent effect.
# -----------------------------------------------------------------------------
render_start = ui.find("    private static func render(_ snapshot: RenderSnapshot)")
render_end = ui.find("    private func renderCurrentIcon()", render_start)
if render_start < 0 or render_end < 0:
    raise SystemExit("Tint/Smart v3 patch failed: render range not found")
render_block = ui[render_start:render_end]

call_start = render_block.find("OutlineFreeAdvancedTintProcessor.shared.apply(")
if call_start < 0:
    raise SystemExit("Tint/Smart v3 patch failed: final OutlineFree Tint+ call not found")
call_tail = render_block[call_start:call_start + 1800]

# Normalize the shadow flag in the advanced call. Shadows are applied once after the base image.
call_tail = call_tail.replace("shadowsEnabled: snapshot.shadowsEnabled", "shadowsEnabled: false", 1)
if "backgroundGradientEnabled: snapshot.backgroundGradientEnabled" not in call_tail:
    old = "                shadowTintMix: snapshot.shadowTintMix\n"
    new = '''                shadowTintMix: snapshot.shadowTintMix,
                backgroundGradientEnabled: snapshot.backgroundGradientEnabled,
                backgroundGradientColors: snapshot.backgroundGradientColors,
                backgroundGradientDirectionRaw: snapshot.backgroundGradientDirection.rawValue
'''
    if old not in call_tail:
        raise SystemExit("Tint/Smart v3 patch failed: Tint+ shadowTintMix call marker not found")
    call_tail = call_tail.replace(old, new, 1)
render_block = render_block[:call_start] + call_tail + render_block[call_start + 1800:]

# After the final base renderer, add background gradient to simple Tint and one safe shadow pass to
# every Tint variant. This processor never touches the outer silhouette boundary.
guard_marker = "        guard let baseOutput else { return nil }\n"
if "var postProcessedOutput = baseOutput" not in render_block:
    addition = '''
        var postProcessedOutput = baseOutput

        if snapshot.resolvedMode == .tint &&
            snapshot.tintVariant != .advanced &&
            snapshot.backgroundGradientEnabled {
            postProcessedOutput = OutlineFreeTintBackgroundGradientProcessor.shared.apply(
                source: snapshot.source,
                rendered: postProcessedOutput,
                colors: snapshot.backgroundGradientColors,
                directionRaw: snapshot.backgroundGradientDirection.rawValue,
                backgroundIntensity: snapshot.backgroundIntensity
            ) ?? postProcessedOutput
        }

        if snapshot.resolvedMode == .tint && snapshot.shadowsEnabled {
            postProcessedOutput = OutlineFreeInteriorTintShadowProcessor.shared.apply(
                source: snapshot.source,
                rendered: postProcessedOutput,
                shadowColor: snapshot.shadowColor,
                strength: snapshot.shadowStrength,
                tintMix: snapshot.shadowTintMix,
                surfaceColor: snapshot.backgroundTint
            ) ?? postProcessedOutput
        }
'''
    if guard_marker not in render_block:
        raise SystemExit("Tint/Smart v3 patch failed: baseOutput guard marker not found")
    render_block = render_block.replace(guard_marker, guard_marker + addition, 1)

# The existing shadow-bypass guard must return our final Tint material, not the pre-shadow base.
render_block = render_block.replace("            return baseOutput\n        }", "            return postProcessedOutput\n        }", 1)
# Generic IconShadowProcessor is retained for Smart Logo only. Feed it the postprocessed image so
# ordinary Tint cannot accidentally lose the new gradient/shadow result.
render_block = render_block.replace("            rendered: baseOutput,", "            rendered: postProcessedOutput,", 1)
render_block = render_block.replace(") ?? baseOutput\n", ") ?? postProcessedOutput\n", 1)

ui = ui[:render_start] + render_block + ui[render_end:]
ui_path.write_text(ui, encoding="utf-8")


# -----------------------------------------------------------------------------
# Final advanced compositor: calculate background target from 2/3/4-colour palette.
# -----------------------------------------------------------------------------
advanced_path = Path("OpaqueIconThemer/OutlineFreeAdvancedTintProcessor.swift")
advanced = advanced_path.read_text(encoding="utf-8")

sig_old = '''        shadowColor: UIColor = .black,
        shadowStrength: CGFloat = 0.90,
        shadowTintMix: CGFloat = 0.30
    ) -> UIImage? {
'''
sig_new = '''        shadowColor: UIColor = .black,
        shadowStrength: CGFloat = 0.90,
        shadowTintMix: CGFloat = 0.30,
        backgroundGradientEnabled: Bool = false,
        backgroundGradientColors: [UIColor] = [],
        backgroundGradientDirectionRaw: String = "topToBottom"
    ) -> UIImage? {
'''
if "backgroundGradientEnabled: Bool = false" not in advanced:
    advanced = must_replace(advanced, sig_old, sig_new, "advanced background-gradient signature")

palette_marker = "        let bgTintLinear = srgbToLinear(rgb(from: backgroundTint))\n"
if "let backgroundGradientPalette" not in advanced:
    advanced = must_replace(
        advanced,
        palette_marker,
        palette_marker + '''        let backgroundGradientPalette = backgroundGradientColors.prefix(4).map {
            srgbToLinear(rgb(from: $0))
        }
''',
        "advanced background-gradient palette",
    )

bg_old = "                let backgroundMaterial = mix(originalBackground, bgTintLinear, amount: bgStrength)\n"
bg_new = '''                let backgroundTarget: RGB
                if backgroundGradientEnabled && backgroundGradientPalette.count >= 2 {
                    let position = backgroundGradientPosition(
                        x: xNorm,
                        y: yNorm,
                        directionRaw: backgroundGradientDirectionRaw
                    )
                    backgroundTarget = backgroundGradientColor(
                        backgroundGradientPalette,
                        position: position
                    )
                } else {
                    backgroundTarget = bgTintLinear
                }
                let backgroundMaterial = mix(originalBackground, backgroundTarget, amount: bgStrength)
'''
if "backgroundGradientPosition(" not in advanced[advanced.find("let corners"):]:
    advanced = must_replace(advanced, bg_old, bg_new, "advanced background material")

helper_marker = "    // MARK: - Background\n"
if "private func backgroundGradientPosition" not in advanced:
    helpers = '''    private func backgroundGradientPosition(
        x: CGFloat,
        y: CGFloat,
        directionRaw: String
    ) -> CGFloat {
        switch directionRaw {
        case "bottomToTop": return 1 - y
        case "rightToLeft": return 1 - x
        default: return y
        }
    }

    private func backgroundGradientColor(_ colors: [RGB], position: CGFloat) -> RGB {
        guard colors.count > 1 else { return colors.first ?? RGB(r: 0, g: 0.478, b: 1) }
        let t = clamp(position, 0, 1)
        let scaled = t * CGFloat(colors.count - 1)
        let lower = min(colors.count - 1, Int(floor(scaled)))
        let upper = min(colors.count - 1, lower + 1)
        return mix(colors[lower], colors[upper], amount: scaled - CGFloat(lower))
    }

'''
    if helper_marker not in advanced:
        raise SystemExit("Tint/Smart v3 patch failed: advanced Background helper marker not found")
    advanced = advanced.replace(helper_marker, helpers + helper_marker, 1)

advanced_path.write_text(advanced, encoding="utf-8")


# -----------------------------------------------------------------------------
# Smart Logo: NR2 base used 0.75, but the FINAL scrubber widened it back to 0.72. That mismatch
# could literally restore the fringe after the supposedly fixed render. Lock both passes to the
# same strict geometry.
# -----------------------------------------------------------------------------
smart_edge_path = Path("OpaqueIconThemer/OutlineFreeSmartLogoProcessor.swift")
smart_edge = smart_edge_path.read_text(encoding="utf-8")
if "locked[i] >= 0.72" in smart_edge:
    smart_edge = smart_edge.replace("locked[i] >= 0.72", "locked[i] >= 0.75", 1)
if "locked[i] >= 0.75" not in smart_edge:
    raise SystemExit("Tint/Smart v3 patch failed: Smart Logo final strict threshold missing")
smart_edge_path.write_text(smart_edge, encoding="utf-8")


# Hard verification: fail CI instead of silently shipping a partial patch.
checks = [
    ("Timer.publish(every: 1.0 / 60.0", ui),
    ("private var backgroundGradientCard", ui),
    ('Toggle("Градиент фона", isOn: $backgroundGradientEnabled)', ui),
    ("values: [2, 3, 4]", ui),
    ("LGLBackgroundGradientDirection.allCases", ui),
    ("OutlineFreeInteriorTintShadowProcessor.shared.apply(", ui),
    ("OutlineFreeTintBackgroundGradientProcessor.shared.apply(", ui),
    ("backgroundGradientEnabled: snapshot.backgroundGradientEnabled", ui),
    ("backgroundGradientEnabled: Bool = false", advanced),
    ("private func backgroundGradientColor", advanced),
    ("locked[i] >= 0.75", smart_edge),
]
for token, haystack in checks:
    if token not in haystack:
        raise SystemExit(f"Tint/Smart v3 final verification failed: {token}")

print("Tint shadows restored without contour; 2/3/4-colour background gradient wired; Smart Logo final edge locked; preview scheduler set to 60 Hz")
