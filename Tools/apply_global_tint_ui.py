from pathlib import Path

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")

old_segment = '''                .background {
                    if selection == value {
                        if #available(iOS 26.0, *) {
                            Color.accentColor.opacity(0.13)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        } else {
                            Capsule().fill(.thinMaterial)
                        }
                    }
                }
'''
new_segment = '''                .background {
                    if selection == value {
                        if #available(iOS 26.0, *) {
                            Capsule(style: .continuous)
                                .fill(Color.clear)
                                .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                                .overlay {
                                    Capsule(style: .continuous)
                                        .fill(Color.accentColor.opacity(0.10))
                                }
                        } else {
                            Capsule(style: .continuous).fill(.thinMaterial)
                        }
                    }
                }
                .clipShape(Capsule(style: .continuous))
'''
if old_segment not in text:
    raise SystemExit("segmented-control block not found")
text = text.replace(old_segment, new_segment, 1)

old_color = '''    private var colorCard: some View {
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
'''
new_color = '''    private var colorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LGLSectionTitle("Цвет", symbol: "paintpalette")
            LGLGlassCard {
                VStack(spacing: 18) {
                    if resolvedMode == .tint && tintVariant == .simple {
                        ColorPicker(
                            "Общий тинт",
                            selection: $tintColor,
                            supportsOpacity: false
                        )
                        .font(.body.weight(.medium))

                        Divider().opacity(0.35)
                        LGLSliderRow(
                            title: "Сила общего тинта",
                            value: $tintIntensity,
                            range: 0...1,
                            onEditingChanged: sliderEditingChanged
                        )
                    } else {
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
                                value: $tintIntensity,
                                title: "Сила тинта",
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
'''
# Fix accidental parameter ordering before inserting.
new_color = new_color.replace('''LGLSliderRow(\n                                value: $tintIntensity,\n                                title: "Сила тинта",''', '''LGLSliderRow(\n                                title: "Сила тинта",\n                                value: $tintIntensity,''')
if old_color not in text:
    raise SystemExit("colorCard block not found")
text = text.replace(old_color, new_color, 1)

old_render = '''        } else {
            guard let base = renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.iconTint,
                intensity: snapshot.tintIntensity
            ) else { return nil }

            baseOutput = CombinedTintIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                backgroundTint: snapshot.backgroundTint,
                iconTint: snapshot.iconTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                iconIntensity: snapshot.tintIntensity
            ) ?? base
        }

        guard let baseOutput else { return nil }

        let preserveSolidTint = snapshot.resolvedMode == .tint &&
            snapshot.tintVariant == .simple &&
            snapshot.tintIntensity >= 0.999 &&
            snapshot.backgroundIntensity >= 0.999

        guard snapshot.shadowsEnabled && !preserveSolidTint else {
            return baseOutput
        }
'''
new_render = '''        } else if snapshot.tintVariant == .simple {
            // Simple Tint is a true whole-image colorization pass: no foreground/background split.
            // Hue/saturation come from the selected color while source lightness stays intact,
            // matching the classic LunaPic-style tint behavior even at 100%.
            baseOutput = GlobalColorTintProcessor.shared.apply(
                source: snapshot.source,
                tint: snapshot.backgroundTint,
                intensity: snapshot.tintIntensity
            )
        } else {
            guard let base = renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.iconTint,
                intensity: snapshot.tintIntensity
            ) else { return nil }

            baseOutput = CombinedTintIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                backgroundTint: snapshot.backgroundTint,
                iconTint: snapshot.iconTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                iconIntensity: snapshot.tintIntensity
            ) ?? base
        }

        guard let baseOutput else { return nil }

        // A 100% global tint must still retain the source luminance/relief. Do not collapse it to
        // one flat RGB value; only the separate advanced mode uses foreground/background masks.
        guard snapshot.shadowsEnabled else {
            return baseOutput
        }
'''
if old_render not in text:
    raise SystemExit("render block not found")
text = text.replace(old_render, new_render, 1)

text = text.replace(
    'case .tint: return tintVariant == .advanced ? "Apple Tint+" : "Apple Tint"',
    'case .tint: return tintVariant == .advanced ? "Apple Tint+" : "Общий Tint"',
    1,
)
text = text.replace(
    ': "Обычный Tint: один цвет для всей иконки с раздельной силой фона и тинта."',
    ': "Общий Tint: один цвет применяется ко всей картинке без разделения на фон и элементы; светлота, тени и объём исходника сохраняются."',
    1,
)
text = text.replace(
    'return "При 100% + 100% обычный Tint становится ровно выбранным цветом."',
    'return "Как Color Tint в LunaPic: выбранный оттенок применяется ко всей иконке, но белые блики, тёмные тени и внутренний рельеф сохраняются даже при 100%."',
    1,
)

path.write_text(text, encoding="utf-8")
print("Applied global tint UI + capsule selection fixes")
