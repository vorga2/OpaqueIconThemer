from pathlib import Path
import re

# Final no-rim pass for Tint+.
#
# Three different effects were being perceived as "outlines":
# 1) the original pale background baked into antialiased logo-edge pixels;
# 2) tint/gradient being applied to those contaminated edge colours;
# 3) the generic shadow processor drawing a silhouette bevel/highlight around the logo.
#
# This pass removes all three at the source. Edge pixels get their foreground colour from nearby
# confident interior pixels, then are composited over the new background with the *same fixed*
# coverage mask. Tint strength and gradient only change material colour and can never change
# geometry. The generic silhouette-shadow pass is disabled for Tint+ so it cannot re-add a rim.

processor_path = Path("OpaqueIconThemer/AdvancedTintCompositeProcessor.swift")
text = processor_path.read_text(encoding="utf-8")

# Build a local interior-colour field before the per-pixel composite. This avoids solving the
# flattened-edge equation with an imperfect soft mask (which can overshoot toward white/blue).
marker = '''        let bgTintLinear = srgbToLinear(rgb(from: backgroundTint))
        let iconTintLinear = srgbToLinear(rgb(from: iconTint))
        var output = renderedPixels
'''
replacement = '''        let bgTintLinear = srgbToLinear(rgb(from: backgroundTint))
        let iconTintLinear = srgbToLinear(rgb(from: iconTint))

        // Build a colour field from CONFIDENT INTERIOR foreground only. AA/fringe pixels never
        // provide their own colour, so old white/pale background contamination cannot become a
        // visible rim when background intensity, icon tint or the icon gradient changes.
        let pixelCount = width * height
        var coreWeight = [CGFloat](repeating: 0, count: pixelCount)
        var weightedR = [CGFloat](repeating: 0, count: pixelCount)
        var weightedG = [CGFloat](repeating: 0, count: pixelCount)
        var weightedB = [CGFloat](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let p = i * 4
            let coverage = clamp(locked[i], 0, 1)
            let core = smoothstep(edge0: 0.78, edge1: 0.96, value: coverage)
            guard core > 0.0001 else { continue }

            let sourceRGB = RGB(
                r: CGFloat(sourcePixels[p]) / 255.0,
                g: CGFloat(sourcePixels[p + 1]) / 255.0,
                b: CGFloat(sourcePixels[p + 2]) / 255.0
            )
            let sourceLinear = srgbToLinear(sourceRGB)
            coreWeight[i] = core
            weightedR[i] = sourceLinear.r * core
            weightedG[i] = sourceLinear.g * core
            weightedB[i] = sourceLinear.b * core
        }

        // Small local pull: enough to carry the real interior material colour into a 1–2 px AA
        // transition, but not enough to smear unrelated parts of the artwork together.
        let edgeRadius = 5
        let localWeight = boxBlur(coreWeight, width: width, height: height, radius: edgeRadius)
        let localR = boxBlur(weightedR, width: width, height: height, radius: edgeRadius)
        let localG = boxBlur(weightedG, width: width, height: height, radius: edgeRadius)
        let localB = boxBlur(weightedB, width: width, height: height, radius: edgeRadius)

        var output = renderedPixels
'''
if marker not in text:
    raise SystemExit("no-rim patch: AdvancedTintCompositeProcessor setup marker not found")
text = text.replace(marker, replacement, 1)

old_coverage = '''                // Keep the geometry fixed and slightly suppress only the extremely weak residual
                // edge coverage. Neither slider participates in this calculation.
                let rawCoverage = clamp(locked[i], 0, 1)
                let edgeT = clamp((rawCoverage - 0.025) / 0.975, 0, 1)
                let coverage = edgeT * edgeT * (3 - 2 * edgeT)
'''
new_coverage = '''                // One fixed coverage map for every effect. No tint/gradient/shadow parameter can
                // widen it, sharpen it, or reveal neighbouring pixels.
                let coverage = clamp(locked[i], 0, 1)
'''
if old_coverage not in text:
    raise SystemExit("no-rim patch: coverage marker not found")
text = text.replace(old_coverage, new_coverage, 1)

# Replace edge decontamination equation with interior-colour propagation.
pattern = re.compile(
    r'''                let sourceRGB = RGB\(\n'''
    r'''                    r: CGFloat\(sourcePixels\[p\]\) / 255\.0,\n'''
    r'''                    g: CGFloat\(sourcePixels\[p \+ 1\]\) / 255\.0,\n'''
    r'''                    b: CGFloat\(sourcePixels\[p \+ 2\]\) / 255\.0\n'''
    r'''                \)\n'''
    r'''                let sourceLinear = srgbToLinear\(sourceRGB\)\n\n'''
    r'''                // The source bitmap is already flattened\..*?'''
    r'''                recoveredForeground = clampRGB\(recoveredForeground\)\n\n'''
    r'''                var foregroundMaterial = mix\(\n'''
    r'''                    recoveredForeground,\n'''
    r'''                    iconTintLinear,\n'''
    r'''                    amount: fgStrength\n'''
    r'''                \)\n''',
    re.S,
)
new_material = '''                let sourceRGB = RGB(
                    r: CGFloat(sourcePixels[p]) / 255.0,
                    g: CGFloat(sourcePixels[p + 1]) / 255.0,
                    b: CGFloat(sourcePixels[p + 2]) / 255.0
                )
                let sourceLinear = srgbToLinear(sourceRGB)

                // At partial coverage NEVER trust the flattened edge colour itself. Pull the
                // material colour from nearby confident interior pixels instead. That makes the
                // transition simply foreground -> new background, with no third "outline" colour.
                let support = localWeight[i]
                let interiorColour: RGB
                if support > 0.002 {
                    interiorColour = clampRGB(RGB(
                        r: localR[i] / support,
                        g: localG[i] / support,
                        b: localB[i] / support
                    ))
                } else {
                    interiorColour = sourceLinear
                }

                // Preserve original interior detail in the core, but replace contaminated AA edge
                // colour completely with the local interior material colour.
                let edgeReplacement = 1 - smoothstep(
                    edge0: 0.72,
                    edge1: 0.98,
                    value: coverage
                )
                let cleanForeground = mix(
                    sourceLinear,
                    interiorColour,
                    amount: edgeReplacement
                )

                // "Сила тинта" changes colour only. It never participates in coverage.
                var foregroundMaterial = mix(
                    cleanForeground,
                    iconTintLinear,
                    amount: fgStrength
                )
'''
text, replacements = pattern.subn(new_material, text, count=1)
if replacements != 1:
    raise SystemExit(f"no-rim patch: foreground recovery block replacements={replacements}")

# Add helpers if not already present.
helper_marker = '''    // MARK: - Color math / image helpers

    private func rgb(from color: UIColor) -> RGB {
'''
helpers = '''    // MARK: - Fixed-edge filtering

    private func boxBlur(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, input.count == width * height else { return input }
        var horizontal = [CGFloat](repeating: 0, count: input.count)
        var output = [CGFloat](repeating: 0, count: input.count)

        for y in 0..<height {
            let row = y * width
            var sum: CGFloat = 0
            var samples = 0
            for x in -radius...radius where x >= 0 && x < width {
                sum += input[row + x]
                samples += 1
            }
            for x in 0..<width {
                horizontal[row + x] = sum / CGFloat(max(1, samples))
                let removeX = x - radius
                let addX = x + radius + 1
                if removeX >= 0 {
                    sum -= input[row + removeX]
                    samples -= 1
                }
                if addX < width {
                    sum += input[row + addX]
                    samples += 1
                }
            }
        }

        for x in 0..<width {
            var sum: CGFloat = 0
            var samples = 0
            for y in -radius...radius where y >= 0 && y < height {
                sum += horizontal[y * width + x]
                samples += 1
            }
            for y in 0..<height {
                output[y * width + x] = sum / CGFloat(max(1, samples))
                let removeY = y - radius
                let addY = y + radius + 1
                if removeY >= 0 {
                    sum -= horizontal[removeY * width + x]
                    samples -= 1
                }
                if addY < height {
                    sum += horizontal[addY * width + x]
                    samples += 1
                }
            }
        }
        return output
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Color math / image helpers

    private func rgb(from color: UIColor) -> RGB {
'''
if helper_marker not in text:
    raise SystemExit("no-rim patch: helper insertion marker not found")
text = text.replace(helper_marker, helpers, 1)

processor_path.write_text(text, encoding="utf-8")

# The generic shadow processor creates silhouette bevel/highlight by definition. Even after the
# outside drop-shadow was removed, that upper/left white bevel and lower/right dark bevel are still
# visible as a rim. Do not run it for Tint+. AdvancedTintCompositeProcessor now owns the material
# edge completely. (Simple Tint did not use this pass already; Apple Mono has its own depth pass.)
ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")

candidates = [
    "logoShadows: snapshot.tintVariant == .advanced",
    "logoShadows: snapshot.resolvedMode == .smartLogo || snapshot.tintVariant == .advanced",
]
changed = False
for old in candidates:
    if old in ui:
        ui = ui.replace(old, "logoShadows: false", 1)
        changed = True
        break
if not changed and "logoShadows: false" not in ui:
    raise SystemExit("no-rim patch: logoShadows marker not found")

ui_path.write_text(ui, encoding="utf-8")
print("Tint+ true no-rim pass applied: clean AA from interior colour, fixed geometry, no silhouette bevel")
