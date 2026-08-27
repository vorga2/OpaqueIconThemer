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

new = '''        // The permissive layer-aware mask is good for finding faint nested artwork, but its
        // low-confidence outside fringe must not participate in Tint+ colour strength. Convert it
        // into a fixed geometry map first. Exterior-connected fringe is clipped; enclosed weak
        // material remains available for Settings/Photos-style internal layers.
        let lockedForeground = TintForegroundGeometry.shared.lockedCoverage(
            softMask: foregroundMask,
            width: width,
            height: height
        )

        for i in 0..<(width * height) {
            let p = i * 4
            let foregroundCoverage = clamp(lockedForeground[i], 0, 1)

            let renderedRGB = RGB(
                r: CGFloat(renderedPixels[p]) / 255.0,
                g: CGFloat(renderedPixels[p + 1]) / 255.0,
                b: CGFloat(renderedPixels[p + 2]) / 255.0
            )
            let renderedLinear = srgbToLinear(renderedRGB)

            // Slider strength changes MATERIAL COLOR only. Coverage is fixed above and therefore
            // identical at 0%, 50% and 100%. Pixels outside the strict silhouette never receive
            // icon tint, so the edge cannot grow into neighbouring background as strength rises.
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
print("Tint+ geometry locked with strict exterior clipping; strength cannot reveal neighbour fringe")
