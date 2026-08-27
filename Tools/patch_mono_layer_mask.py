from pathlib import Path

path = Path("OpaqueIconThemer/ReferenceAppleMonotoneRenderer.swift")
text = path.read_text(encoding="utf-8")

old = '''        let referenceLabs = references.map(oklab)
        let meanBackground = mean(references)
        let meanLab = oklab(meanBackground)
        let variation = referenceLabs.reduce(CGFloat.zero) { $0 + $1.distance(to: meanLab) } /
            CGFloat(max(1, referenceLabs.count))

        // Soft threshold deliberately remains conservative. Auto mode falls back to full tint
        // if this cannot isolate a useful glyph.
        let threshold = min(0.20, max(0.034, 0.047 + variation * 0.92))

        var hardMask = [Bool](repeating: false, count: width * height)
        var softMask = [CGFloat](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.001 else { continue }

                let straight = straightRGB(pixels: pixels, offset: p, alpha: alpha)
                let distance = referenceLabs.map { oklab(straight).distance(to: $0) }.min() ?? 1

                hardMask[i] = distance >= threshold * 0.78

                // Apple-like edge behavior needs coverage, not a binary sticker. The original
                // alpha remains part of the coverage so translucent strokes stay translucent.
                let confidence = smoothstep(
                    edge0: threshold * 0.20,
                    edge1: max(threshold * 1.80, threshold + 0.050),
                    value: distance
                )
                softMask[i] = confidence * alpha
            }
        }

        hardMask = majorityFilter(hardMask, width: width, height: height)
        hardMask = keepMeaningfulComponents(
            hardMask,
            width: width,
            height: height,
            minimumSize: max(8, Int(CGFloat(width * height) * 0.00004))
        )

        let foregroundCount = hardMask.reduce(0) { $0 + ($1 ? 1 : 0) }
        let coverage = CGFloat(foregroundCount) / CGFloat(width * height)
        guard coverage >= 0.010, coverage <= 0.74 else { return nil }

        let allowed = dilate(hardMask, width: width, height: height, radius: 3)
        for i in 0..<softMask.count where !allowed[i] {
            softMask[i] = 0
        }
        softMask = gaussian3x3(softMask, width: width, height: height)
'''

new = '''        let meanBackground = mean(references)

        // The old single border-color threshold collapsed low-contrast and semi-transparent
        // nested material into one flat glyph. Reuse the same layer-aware detector as Tint+ so
        // Photos-like overlaps and the Settings center stay part of the foreground material.
        guard var softMask = LayerAwareForegroundDetector.shared.foregroundMask(
            source: source,
            width: width,
            height: height
        ), softMask.count == width * height else {
            return nil
        }

        softMask = gaussian3x3(softMask, width: width, height: height)
        let foregroundCount = softMask.reduce(0) { $0 + ($1 > 0.42 ? 1 : 0) }
        let coverage = CGFloat(foregroundCount) / CGFloat(width * height)
        guard coverage >= 0.010, coverage <= 0.78 else { return nil }
'''

if old not in text:
    raise SystemExit("old smart-logo segmentation block not found")

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("Apple Mono now uses layer-aware foreground coverage")
