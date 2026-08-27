from pathlib import Path

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"patch failed: {label} marker not found")
    text = text.replace(old, new, 1)


replace_once(
'''                .buttonStyle(.plain)
                .foregroundStyle(selection == value ? Color.primary : Color.secondary)
                .background {
                    if selection == value {
                        if #available(iOS 26.0, *) {
                            Color.accentColor.opacity(0.13)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        } else {
                            Capsule().fill(.thinMaterial)
                        }
                    }
                }
''',
'''                .buttonStyle(.plain)
                .foregroundStyle(selection == value ? Color.primary : Color.secondary)
                .background {
                    if selection == value {
                        if #available(iOS 26.0, *) {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                                .glassEffect(
                                    .regular.tint(Color.accentColor.opacity(0.10)).interactive(),
                                    in: .capsule
                                )
                        } else {
                            Capsule().fill(.thinMaterial)
                        }
                    }
                }
                .clipShape(Capsule())
''',
"selected segmented capsule",
)

replace_once(
'''    @State private var mode: IconRenderMode = .auto
    @State private var tintVariant: LGLTintVariant = .simple
    @State private var tintIntensity: Double = 0.88
''',
'''    @State private var mode: IconRenderMode = .auto
    @State private var tintVariant: LGLTintVariant = .simple
    @State private var editUnifiedTint = true
    @State private var tintIntensity: Double = 0.88
''',
"unified tint state",
)

replace_once(
'''    private var backgroundColorKey: String { UIColor(tintColor).description }
    private var iconColorKey: String { UIColor(iconTintColor).description }
    private var shadowColorKey: String { UIColor(shadowColor).description }
''',
'''    private var backgroundColorKey: String { UIColor(tintColor).description }
    private var iconColorKey: String { UIColor(iconTintColor).description }
    private var shadowColorKey: String { UIColor(shadowColor).description }

    private var unifiedTintIntensityBinding: Binding<Double> {
        Binding(
            get: { (backgroundIntensity + tintIntensity) * 0.5 },
            set: { newValue in
                backgroundIntensity = newValue
                tintIntensity = newValue
            }
        )
    }
''',
"unified tint binding",
)

replace_once(
'''        .onChange(of: mode) { _ in markPreviewDirty() }
        .onChange(of: tintVariant) { _ in markPreviewDirty() }
        .onChange(of: backgroundColorKey) { _ in markPreviewDirty() }
''',
'''        .onChange(of: mode) { _ in markPreviewDirty() }
        .onChange(of: tintVariant) { _ in markPreviewDirty() }
        .onChange(of: editUnifiedTint) { enabled in
            if enabled && resolvedMode == .tint && tintVariant == .simple {
                let value = (backgroundIntensity + tintIntensity) * 0.5
                backgroundIntensity = value
                tintIntensity = value
            }
            markPreviewDirty()
        }
        .onChange(of: backgroundColorKey) { _ in markPreviewDirty() }
''',
"unified tint change handler",
)

replace_once(
'''    private var colorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Цвет", symbol: "paintpalette")
            LGLGlassCard {
                VStack(spacing: 18) {
                    ColorPicker(
                        resolvedMode == .tint && tintVariant == .advanced ? "Цвет фона" : "Цвет тинта",
                        selection: $tintColor,
                        supportsOpacity: false
                    )
                    .font(.body.weight(.medium))

                    if resolvedMode == .tint && tintVariant == .advanced {
                        Divider().opacity(0.35)
                        ColorPicker("Цвет иконки", selection: $iconTintColor, supportsOpacity: false)
                            .font(.body.weight(.medium))
                    }

                    Divider().opacity(0.35)
                    LGLSliderRow(
                        title: "Интенсивность фона",
                        value: $backgroundIntensity,
                        range: 0...1,
                        onEditingChanged: sliderEditingChanged
                    )

                    if resolvedMode == .tint {
                        Divider().opacity(0.35)
                        LGLSliderRow(
                            title: "Сила тинта",
                            value: $tintIntensity,
                            range: 0...1,
                            onEditingChanged: sliderEditingChanged
                        )
                    }

                    Text(colorDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
''',
'''    private var colorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Цвет", symbol: "paintpalette")
            LGLGlassCard {
                VStack(spacing: 18) {
                    if resolvedMode == .tint && tintVariant == .simple {
                        Toggle(isOn: $editUnifiedTint) {
                            Label("Редактировать общий тинт", systemImage: "circle.hexagongrid.fill")
                                .font(.body.weight(.medium))
                        }
                        Divider().opacity(0.35)
                    }

                    ColorPicker(
                        resolvedMode == .tint && tintVariant == .advanced
                            ? "Цвет фона"
                            : (resolvedMode == .tint && tintVariant == .simple && editUnifiedTint
                                ? "Общий тинт"
                                : "Цвет тинта"),
                        selection: $tintColor,
                        supportsOpacity: false
                    )
                    .font(.body.weight(.medium))

                    if resolvedMode == .tint && tintVariant == .advanced {
                        Divider().opacity(0.35)
                        ColorPicker("Цвет иконки", selection: $iconTintColor, supportsOpacity: false)
                            .font(.body.weight(.medium))
                    }

                    Divider().opacity(0.35)

                    if resolvedMode == .tint && tintVariant == .simple && editUnifiedTint {
                        LGLSliderRow(
                            title: "Общая интенсивность",
                            value: unifiedTintIntensityBinding,
                            range: 0...1,
                            onEditingChanged: sliderEditingChanged
                        )
                    } else {
                        LGLSliderRow(
                            title: "Интенсивность фона",
                            value: $backgroundIntensity,
                            range: 0...1,
                            onEditingChanged: sliderEditingChanged
                        )

                        if resolvedMode == .tint {
                            Divider().opacity(0.35)
                            LGLSliderRow(
                                title: "Сила тинта",
                                value: $tintIntensity,
                                range: 0...1,
                                onEditingChanged: sliderEditingChanged
                            )
                        }
                    }

                    Text(colorDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
''',
"simple tint color card",
)

replace_once(
'''        return RenderSnapshot(
            source: source,
            resolvedMode: resolvedMode,
            tintVariant: tintVariant,
            backgroundTint: backgroundTint,
            iconTint: effectiveIconTint,
            tintIntensity: CGFloat(tintIntensity),
            backgroundIntensity: CGFloat(backgroundIntensity),
            gradientStart: CGFloat(gradientStart),
''',
'''        let unifiedSimpleTint = resolvedMode == .tint && tintVariant == .simple && editUnifiedTint
        let unifiedStrength = CGFloat((backgroundIntensity + tintIntensity) * 0.5)

        return RenderSnapshot(
            source: source,
            resolvedMode: resolvedMode,
            tintVariant: tintVariant,
            backgroundTint: backgroundTint,
            iconTint: effectiveIconTint,
            tintIntensity: unifiedSimpleTint ? unifiedStrength : CGFloat(tintIntensity),
            backgroundIntensity: unifiedSimpleTint ? unifiedStrength : CGFloat(backgroundIntensity),
            gradientStart: CGFloat(gradientStart),
''',
"unified render strength",
)

replace_once(
'''            return tintVariant == .advanced
                ? "Расширенный Tint: отдельные цвета фона и элементов с независимой интенсивностью."
                : "Обычный Tint: один цвет для всей иконки с раздельной силой фона и тинта."
''',
'''            return tintVariant == .advanced
                ? "Расширенный Tint: отдельные цвета фона и элементов с независимой интенсивностью."
                : (editUnifiedTint
                    ? "Обычный Tint: общий цвет и одна общая интенсивность одновременно управляют фоном и элементами."
                    : "Обычный Tint: один цвет, но силу фона и элементов можно править раздельно.")
''',
"mode description",
)

replace_once(
'''        } else if resolvedMode == .tint {
            return "При 100% + 100% обычный Tint становится ровно выбранным цветом."
        }
''',
'''        } else if resolvedMode == .tint {
            return editUnifiedTint
                ? "Общий тинт синхронно меняет цвет и интенсивность фона и элементов — без раздельной настройки."
                : "Раздельный режим оставляет один цвет, но позволяет отдельно настроить фон и элементы."
        }
''',
"color description",
)

path.write_text(text, encoding="utf-8")
print("Liquid Glass UI patch applied")
