from pathlib import Path

path = Path("OpaqueIconThemer/CombinedTintIntensityProcessor.swift")
text = path.read_text(encoding="utf-8")

old = '''        for i in 0..<(width * height) {
            let p = i * 4
            let foregroundConfidence = clamp(foregroundMask[i], 0, 1)
            let backgroundConfidence = 1 - foregroundConfidence

            let bgWeight = backgroundConfidence * bgStrength
            let fgWeight = foregroundConfidence * fgStrength
            let combined = bgWeight + fgWeight
            let totalWeight = clamp(combined, 0, 1)

            guard totalWeight > 0.0001 else {
                output[p + 3] = 255
                continue
            }

            let renderedRGB = RGB(
                r: CGFloat(renderedPixels[p]) / 255.0,
                g: CGFloat(renderedPixels[p + 1]) / 255.0,
                b: CGFloat(renderedPixels[p + 2]) / 255.0
            )
            let renderedLinear = srgbToLinear(renderedRGB)

            // The target color is the weighted material mix. Nested / translucent foreground
            // remains partially assigned to iconTint instead of being mistaken for flat background.
            let backgroundShare = bgWeight / max(0.0001, combined)
            let targetLinear = mix(
                iconTintLinear,
                bgTintLinear,
                amount: backgroundShare
            )

            let resultLinear = mix(renderedLinear, targetLinear, amount: totalWeight)
            let result = linearToSRGB(resultLinear)

            output[p] = byte(result.r)
            output[p + 1] = byte(result.g)
            output[p + 2] = byte(result.b)
            output[p + 3] = 255
        }
'''

new = '''        for i in 0..<(width * height) {
            let p = i * 4

            // IMPORTANT: mask geometry must be completely independent from both sliders.
            // Previously fgStrength multiplied the soft foreground mask itself. Increasing
            // “Сила тинта” therefore made low-confidence AA/fringe pixels progressively visible,
            // so the logo looked like it grew into neighbouring pixels. Build one fixed coverage
            // curve once, then use strength only to change the MATERIAL COLOR inside that geometry.
            let rawForeground = clamp(foregroundMask[i], 0, 1)
            let fixedT = clamp((rawForeground - 0.10) / 0.80, 0, 1)
            let foregroundCoverage = fixedT * fixedT * (3 - 2 * fixedT)

            let renderedRGB = RGB(
                r: CGFloat(renderedPixels[p]) / 255.0,
                g: CGFloat(renderedPixels[p + 1]) / 255.0,
                b: CGFloat(renderedPixels[p + 2]) / 255.0
            )
            let renderedLinear = srgbToLinear(renderedRGB)

            // Strength changes colour, never opacity/coverage. At an AA edge the same fixed
            // foregroundCoverage is used at 0%, 50% and 100%, so the silhouette cannot expand.
            let backgroundMaterial = mix(
                renderedLinear,
                bgTintLinear,
                amount: bgStrength
            )
            let foregroundMaterial = mix(
                renderedLinear,
                iconTintLinear,
                amount: fgStrength
            )

            let resultLinear = mix(
                backgroundMaterial,
                foregroundMaterial,
                amount: foregroundCoverage
            )
            let result = linearToSRGB(resultLinear)

            output[p] = byte(result.r)
            output[p + 1] = byte(result.g)
            output[p + 2] = byte(result.b)
            output[p + 3] = 255
        }
'''

if old not in text:
    raise SystemExit("Tint+ geometry block not found")

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("Tint+ geometry locked: strength changes color only, never mask coverage")
