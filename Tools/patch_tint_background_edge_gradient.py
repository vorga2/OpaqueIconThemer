from pathlib import Path

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"Tint+ edge/gradient patch failed: {label} marker not found")
    text = text.replace(old, new, 1)


# Show the same gradient controls in Advanced Tint+. The gradient colour itself is intentionally
# not user-selectable here: by request it always uses the selected background colour.
replace_once(
'''                        if resolvedMode == .smartLogo {
                            gradientCard
                        }
''',
'''                        if resolvedMode == .smartLogo ||
                            (resolvedMode == .tint && tintVariant == .advanced) {
                            gradientCard
                        }
''',
"gradient card visibility",
)

replace_once(
'''            LGLSectionTitle("Градиент логотипа", symbol: "circle.lefthalf.filled")
''',
'''            LGLSectionTitle(
                resolvedMode == .tint && tintVariant == .advanced
                    ? "Градиент иконки"
                    : "Градиент логотипа",
                symbol: "circle.lefthalf.filled"
            )
''',
"gradient title",
)

replace_once(
'''                    Text("Mono-форма считается в linear-light; мягкие слои и антиалиасинг сохраняются, итоговая PNG остаётся непрозрачной.")
                        .font(.caption)
''',
'''                    Text(
                        resolvedMode == .tint && tintVariant == .advanced
                            ? "Градиент применяется только к иконке, берёт цвет фона и не зависит от «Силы тинта»."
                            : "Mono-форма считается в linear-light; мягкие слои и антиалиасинг сохраняются, итоговая PNG остаётся непрозрачной."
                    )
                        .font(.caption)
''',
"gradient description",
)

# After patch_tint_strength_fill_only.py the advanced branch uses a neutral bitmap plus the old
# CombinedTintIntensityProcessor. Replace it with the decontaminating compositor. It reconstructs
# the foreground colour at antialiased edges before applying the new background, so increasing
# background intensity cannot leave the old white background baked around the logo.
replace_once(
'''        } else {
            // Tint+ must not pre-tint the whole bitmap. A whole-image tint colours the soft
            // antialias/fringe and any baked shadow before the layer mask is applied, which turns
            // “Сила тинта” into a visible coloured halo around simple logos. Build a neutral,
            // fully-opaque base first; the layer-aware combined pass below is the ONLY place where
            // background/icon tint strength is applied.
            guard let base = renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.iconTint,
                intensity: 0.0
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
'''        } else {
            // Tint+ starts from a neutral copy. AdvancedTintCompositeProcessor owns the complete
            // foreground/background composite, including AA edge decontamination. This prevents
            // the original pale icon background from surviving as a white outline when
            // “Интенсивность фона” is increased.
            guard let base = renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.iconTint,
                intensity: 0.0
            ) else { return nil }

            baseOutput = AdvancedTintCompositeProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                backgroundTint: snapshot.backgroundTint,
                iconTint: snapshot.iconTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                iconIntensity: snapshot.tintIntensity,
                gradientStart: snapshot.gradientStart,
                gradientStrength: snapshot.gradientStrength
            ) ?? base
        }
''',
"advanced Tint render branch",
)

path.write_text(text, encoding="utf-8")
print("Tint+ background edge decontamination + independent background-colour icon gradient applied")
