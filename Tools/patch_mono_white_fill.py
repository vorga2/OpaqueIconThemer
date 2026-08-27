from pathlib import Path

path = Path("OpaqueIconThemer/AppleMonoDepthProcessor.swift")
text = path.read_text(encoding="utf-8")

old = '''                var result = srgbToLinear(renderedRGB)

                // Restore source-local tonal relief while keeping the already chosen Mono hue.
'''

new = '''                var result = srgbToLinear(renderedRGB)

                // Apple Mono uses a white foreground body. Apply white only to the detected
                // foreground coverage here, BEFORE depth/shadow reconstruction. All cavity,
                // contact, bevel and optional shadow passes run afterwards, so whitening never
                // washes the shadows out or recolors the tile/background.
                let whiteFillCoverage = clamp(logo * 0.995, 0, 0.995)
                result = mix(result, white, amount: whiteFillCoverage)

                // Restore source-local tonal relief on top of the white body. Negative relief,
                // cavities and contact shadows stay neutral/dark; only the actual logo fill is
                // forced toward white.
'''

if old not in text:
    raise SystemExit("Apple Mono white-fill insertion point not found")

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("Apple Mono white foreground fill applied before depth/shadows")
