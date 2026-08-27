from pathlib import Path

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")

old = '''            guard let base else { return nil }
            baseOutput = BackgroundIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                tint: snapshot.backgroundTint,
                intensity: snapshot.backgroundIntensity
            ) ?? base
'''

new = '''            guard let base else { return nil }
            let backgroundAdjusted = BackgroundIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                tint: snapshot.backgroundTint,
                intensity: snapshot.backgroundIntensity
            ) ?? base

            // Reconstruct internal material depth from the original colored artwork. This is
            // separate from the optional user shadow pass below: even with shadows disabled,
            // Mono keeps nested translucent layers, contact separation and cavities like the
            // Photos flower / Settings gear instead of collapsing into one flat white mask.
            baseOutput = AppleMonoDepthProcessor.shared.apply(
                source: snapshot.source,
                rendered: backgroundAdjusted,
                strength: 1.0
            ) ?? backgroundAdjusted
'''

if old not in text:
    raise SystemExit("Apple Mono render block not found")

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("Apple Mono multilayer depth pass wired")
