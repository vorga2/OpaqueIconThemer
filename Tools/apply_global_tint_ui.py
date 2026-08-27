from pathlib import Path

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"global tint patch failed: {label} marker not found")
    text = text.replace(old, new, 1)


# The first Liquid UI patch already adds the "Редактировать общий тинт" switch and fixes the
# selected capsule shape. This pass changes what unified mode actually does: a real whole-image
# colorization instead of merely synchronizing the foreground/background strengths.
replace_once(
'''        let tintVariant: LGLTintVariant
        let backgroundTint: UIColor
''',
'''        let tintVariant: LGLTintVariant
        let globalTintEnabled: Bool
        let backgroundTint: UIColor
''',
"RenderSnapshot global tint flag",
)

replace_once(
'''            source: source,
            resolvedMode: resolvedMode,
            tintVariant: tintVariant,
            backgroundTint: backgroundTint,
''',
'''            source: source,
            resolvedMode: resolvedMode,
            tintVariant: tintVariant,
            globalTintEnabled: unifiedSimpleTint,
            backgroundTint: backgroundTint,
''',
"RenderSnapshot global tint value",
)

replace_once(
'''        } else {
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
''',
'''        } else if snapshot.tintVariant == .simple && snapshot.globalTintEnabled {
            // LunaPic-style whole-image tint: no foreground/background segmentation.
            // Hue and saturation come from the selected color while source lightness is preserved,
            // so 100% still keeps white highlights, dark shadows and internal relief.
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
''',
"global tint render path",
)

replace_once(
'''        let preserveSolidTint = snapshot.resolvedMode == .tint &&
            snapshot.tintVariant == .simple &&
            snapshot.tintIntensity >= 0.999 &&
            snapshot.backgroundIntensity >= 0.999
''',
'''        let preserveSolidTint = snapshot.resolvedMode == .tint &&
            snapshot.tintVariant == .simple &&
            !snapshot.globalTintEnabled &&
            snapshot.tintIntensity >= 0.999 &&
            snapshot.backgroundIntensity >= 0.999
''',
"do not flatten global tint at 100 percent",
)

replace_once(
'''        case .tint: return tintVariant == .advanced ? "Apple Tint+" : "Apple Tint"
''',
'''        case .tint:
            if tintVariant == .advanced { return "Apple Tint+" }
            return editUnifiedTint ? "Общий Tint" : "Apple Tint"
''',
"preview title",
)

replace_once(
'''                : (editUnifiedTint
                    ? "Обычный Tint: общий цвет и одна общая интенсивность одновременно управляют фоном и элементами."
                    : "Обычный Tint: один цвет, но силу фона и элементов можно править раздельно.")
''',
'''                : (editUnifiedTint
                    ? "Общий Tint как в LunaPic: один оттенок красит всю картинку целиком без разделения на фон и элементы, сохраняя светлоту, блики, тени и объём."
                    : "Обычный Tint: один цвет, но силу фона и элементов можно править раздельно.")
''',
"mode description global tint",
)

replace_once(
'''            return editUnifiedTint
                ? "Общий тинт синхронно меняет цвет и интенсивность фона и элементов — без раздельной настройки."
                : "Раздельный режим оставляет один цвет, но позволяет отдельно настроить фон и элементы."
''',
'''            return editUnifiedTint
                ? "Как Color Tint в LunaPic: оттенок применяется ко всей иконке. При 100% белые детали остаются светлыми, тёмные — тёмными, поэтому рельеф не превращается в плоскую заливку."
                : "Раздельный режим оставляет один цвет, но позволяет отдельно настроить фон и элементы."
''',
"color description global tint",
)

path.write_text(text, encoding="utf-8")
print("LunaPic-style global tint render path applied")
