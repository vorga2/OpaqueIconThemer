from pathlib import Path

path = Path("OpaqueIconThemer/AppleMonoDepthProcessor.swift")
text = path.read_text(encoding="utf-8")

old = '''                var result = srgbToLinear(renderedRGB)

                // Restore source-local tonal relief while keeping the already chosen Mono hue.
'''

new = '''                var result = srgbToLinear(renderedRGB)

                // Apple Mono surface contract: the foreground/logo body itself is white.
                // Do this BEFORE any depth pass. Contact shadows, cavities, lower/right bevels
                // and the optional user shadow processor are composited afterwards, so they stay
                // neutral/dark and are never washed toward white. `logo` is a soft coverage mask,
                // therefore antialiased edges remain clean instead of becoming a hard sticker.
                result = mix(result, white, amount: clamp(logo, 0, 1))

                // Restore source-local tonal relief on top of the white body. Bright relief can
                // only add a subtle highlight; negative relief is still allowed to darken the
                // surface, so depth remains visible without changing the fill colour itself.
'''

if old not in text:
    raise SystemExit("Apple Mono white-fill insertion point not found")

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("Apple Mono white foreground fill applied before all depth/shadow passes")
