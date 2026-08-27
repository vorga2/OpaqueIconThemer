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

# Prior patches already turn the advanced branch into a neutral base. Replace only the actual
# compositor call instead of matching the surrounding comments, because those comments have
# changed several times while the render contract stayed the same.
replace_once(
'''            baseOutput = CombinedTintIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                backgroundTint: snapshot.backgroundTint,
                iconTint: snapshot.iconTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                iconIntensity: snapshot.tintIntensity
            ) ?? base
''',
'''            baseOutput = AdvancedTintCompositeProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                backgroundTint: snapshot.backgroundTint,
                iconTint: snapshot.iconTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                iconIntensity: snapshot.tintIntensity,
                gradientStart: snapshot.gradientStart,
                gradientStrength: snapshot.gradientStrength
            ) ?? base
''',
"advanced Tint compositor call",
)

path.write_text(text, encoding="utf-8")
print("Tint+ background edge decontamination + independent background-colour icon gradient applied")
