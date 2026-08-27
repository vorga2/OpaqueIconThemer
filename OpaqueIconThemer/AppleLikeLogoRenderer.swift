import Foundation
import UIKit

/// Static Apple-style mono/tinted renderer for legacy bitmap app icons.
///
/// The exact private IconServices segmentation/material shader is not public. This renderer follows
/// the authoring-level pipeline described in the project research instead of treating the icon as
/// one binary mask: legacy bitmap -> surrogate layer stack -> mono tonal mapping -> shadow/detail ->
/// refraction/specular -> blend -> opaque final composite.
///
/// The one intentional project difference from Apple's glass output is that the final bitmap is
/// always fully opaque. Visual translucency is baked into RGB while every output alpha byte is 255.
final class AppleLikeLogoRenderer {
    static let shared = AppleLikeLogoRenderer()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    private struct Oklab {
        let l: CGFloat
        let a: CGFloat
        let b: CGFloat

        func distance(to other: Oklab) -> CGFloat {
            let dl = l - other.l
            let da = a - other.a
            let db = b - other.b
            return sqrt(dl * dl + da * da + db * db)
        }
    }

    /// Surrogate for Apple's private icon layer stack. These arrays are deliberately separate so
    /// opacity/detail/lighting are not destroyed by a single foreground mask.
    private struct LayerStack {
        let width: Int
        let height: Int
        let background: [RGB]
        let flattenedSource: [RGB]
        let primaryOpacity: [CGFloat]
        let tone: [CGFloat]
        let detailDelta: [CGFloat]
        let shadowLayer: [CGFloat]
        let highlightLayer: [CGFloat]
        let specularLayer: [CGFloat]
        let normalX: [CGFloat]
        let normalY: [CGFloat]
    }

    func render(
        source: UIImage,
        tint: UIColor,
        gradientStart: CGFloat,
        gradientStrength: CGFloat
    ) -> UIImage? {
        let workSize = 512
        guard let stack = buildLayerStack(source: source, width: workSize, height: workSize) else {
            return nil
        }

        let tintSRGB = rgb(from: tint)
        let white = RGB(r: 1, g: 1, b: 1)
        let start = min(1.0, max(0.0, gradientStart))
        let strength = min(1.0, max(0.0, gradientStrength))
        var output = [UInt8](repeating: 0, count: stack.width * stack.height * 4)

        for y in 0..<stack.height {
            let yNorm = CGFloat(y) / CGFloat(max(1, stack.height - 1))
            let gradientProgress = yNorm <= start
                ? CGFloat.zero
                : (yNorm - start) / max(0.001, 1 - start)

            // User control is preserved, but the interpolation itself happens in linear light.
            let tintAmount = min(1, max(0, gradientProgress * strength))
            let rowBase = mixLinear(white, tintSRGB, amount: tintAmount)

            for x in 0..<stack.width {
                let i = y * stack.width + x
                let p = i * 4
                let alpha = clamp01(stack.primaryOpacity[i])

                guard alpha > 0.0005 else {
                    let c = stack.flattenedSource[i]
                    output[p] = byte(c.r)
                    output[p + 1] = byte(c.g)
                    output[p + 2] = byte(c.b)
                    output[p + 3] = 255
                    continue
                }

                // Approximate the material's edge refraction by sampling the reconstructed canvas
                // along the local foreground normal. This is intentionally subtle for a static icon.
                let edgeStrength = clamp01(stack.specularLayer[i] * 1.8 + abs(stack.detailDelta[i]) * 0.35)
                let displacement = 0.65 + 1.65 * edgeStrength
                let refractedBackground = sample(
                    stack.background,
                    width: stack.width,
                    height: stack.height,
                    x: CGFloat(x) + stack.normalX[i] * displacement,
                    y: CGFloat(y) + stack.normalY[i] * displacement
                )

                // Remove the old flattened glyph only where segmentation is confident, keeping the
                // untouched original background elsewhere.
                var result = mix(stack.flattenedSource[i], refractedBackground, amount: alpha)

                // Mono representation: linear-light tonal hierarchy, not gamma-space RGB tinting.
                let t = clamp01(stack.tone[i])
                let shadowTone = scaleLinear(rowBase, factor: 0.72)
                let highlightTone = mixLinear(rowBase, white, amount: 0.58)
                var mono = mixLinear(shadowTone, highlightTone, amount: t)

                // Keep secondary geometry from the original icon. A positive detail residual gets a
                // slight lift; a negative one gets a slight lowlight. This mimics separate detail
                // layers rather than flattening every foreground pixel to the same white.
                let detail = max(-1, min(1, stack.detailDelta[i] * 4.5))
                if detail >= 0 {
                    mono = screen(mono, white, amount: detail * 0.12)
                } else {
                    mono = scaleLinear(mono, factor: 1 + detail * 0.10)
                }

                // The inferred opacity remains a layer property. Final alpha is still 1.0 because
                // we composite the layer onto an opaque canvas here.
                result = mix(result, mono, amount: alpha)

                // Separate authoring-style shadow and highlight passes.
                let shadow = clamp01(stack.shadowLayer[i])
                if shadow > 0 {
                    result = scaleLinear(result, factor: 1 - shadow * 0.10)
                }

                let highlight = clamp01(stack.highlightLayer[i])
                if highlight > 0 {
                    result = screen(result, white, amount: highlight * 0.075)
                }

                // Sharper iOS-27-like edge definition: small directional specular at the upper
                // facing edge. This is static; dynamic gyro lighting is outside a saved PNG.
                let specular = clamp01(stack.specularLayer[i])
                if specular > 0 {
                    result = screen(result, white, amount: specular * 0.17)
                }

                output[p] = byte(result.r)
                output[p + 1] = byte(result.g)
                output[p + 2] = byte(result.b)
                output[p + 3] = 255
            }
        }

        guard let workImage = imageFromOpaqueRGBA(output, width: stack.width, height: stack.height) else {
            return nil
        }

        let finalSize = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1

        return UIGraphicsImageRenderer(size: finalSize, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            workImage.draw(in: CGRect(origin: .zero, size: finalSize))
        }
    }

    // MARK: - Surrogate layer extraction

    private func buildLayerStack(source: UIImage, width: Int, height: Int) -> LayerStack? {
        guard let pixels = rgbaPixels(from: source, width: width, height: height) else { return nil }

        let cornerColors = cornerBackgrounds(pixels: pixels, width: width, height: height)
        guard cornerColors.count == 4 else { return nil }

        let borderColors = backgroundReferences(pixels: pixels, width: width, height: height)
        let borderLab = borderColors.map(oklab)
        let meanBackground = mean(borderColors.isEmpty ? cornerColors : borderColors)
        let meanLab = oklab(meanBackground)
        let borderVariation = borderLab.isEmpty ? CGFloat.zero : borderLab.reduce(CGFloat.zero) {
            $0 + $1.distance(to: meanLab)
        } / CGFloat(borderLab.count)

        // Perceptual threshold. The soft range is intentionally wider than the hard mask so
        // anti-aliasing and visually translucent flattened layers survive.
        let threshold = min(0.22, max(0.030, 0.042 + borderVariation * 0.82))

        var background = [RGB](repeating: meanBackground, count: width * height)
        var flattened = [RGB](repeating: meanBackground, count: width * height)
        var linearLuminance = [CGFloat](repeating: 0, count: width * height)
        var rawOpacity = [CGFloat](repeating: 0, count: width * height)
        var hardMask = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            for x in 0..<width {
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))
                let i = y * width + x
                let p = i * 4
                let bg = bilinear(cornerColors, x: xNorm, y: yNorm)
                background[i] = bg

                let sourceAlpha = CGFloat(pixels[p + 3]) / 255.0
                let src = sourceAlpha > 0.0001
                    ? unpremultipliedRGB(pixels: pixels, offset: p, alpha: sourceAlpha)
                    : bg

                // Read input as straight color, then flatten it onto our reconstructed canvas. This
                // avoids the classic double-premultiply halo around partially transparent pixels.
                let observed = mix(bg, src, amount: sourceAlpha)
                flattened[i] = observed
                linearLuminance[i] = luminanceLinear(observed)

                let perceptualDistance = oklab(observed).distance(to: oklab(bg))
                let confidence = smoothstep(
                    edge0: threshold * 0.18,
                    edge1: max(threshold * 1.75, threshold + 0.040),
                    value: perceptualDistance
                )

                // If the source actually contains alpha, keep it. For flattened App Store artwork
                // alpha is normally 1, so opacity is inferred from perceptual distance instead.
                let alphaContribution: CGFloat
                if sourceAlpha < 0.995 {
                    alphaContribution = sourceAlpha
                } else {
                    alphaContribution = 1
                }

                rawOpacity[i] = confidence * alphaContribution
                hardMask[i] = rawOpacity[i] >= 0.31
            }
        }

        hardMask = majorityFilter(hardMask, width: width, height: height)
        hardMask = keepMeaningfulComponents(
            hardMask,
            width: width,
            height: height,
            minimumSize: max(10, Int(CGFloat(width * height) * 0.00005))
        )

        let hardCoverage = CGFloat(hardMask.reduce(0) { $0 + ($1 ? 1 : 0) }) / CGFloat(width * height)
        guard hardCoverage >= 0.010, hardCoverage <= 0.74 else { return nil }

        let allowed = dilateMask(hardMask, width: width, height: height, radius: 3)
        for i in 0..<rawOpacity.count where !allowed[i] {
            rawOpacity[i] = 0
        }

        // Two soft passes retain antialiased geometry without turning the mask into a sticker.
        var primary = gaussian3x3(rawOpacity, width: width, height: height)
        primary = gaussian3x3(primary, width: width, height: height)
        for i in 0..<primary.count {
            primary[i] = clamp01(primary[i])
        }

        let (blackPoint, whitePoint) = weightedToneRange(
            luminance: linearLuminance,
            weights: primary
        )

        var tone = [CGFloat](repeating: 0.5, count: width * height)
        for i in 0..<tone.count {
            let normalized = (linearLuminance[i] - blackPoint) / max(0.0001, whitePoint - blackPoint)
            tone[i] = clamp01(normalized)
        }

        let localLum = boxBlur(linearLuminance, width: width, height: height, radius: 3)
        let softPrimary = boxBlur(primary, width: width, height: height, radius: 2)

        var detailDelta = [CGFloat](repeating: 0, count: width * height)
        var shadowLayer = [CGFloat](repeating: 0, count: width * height)
        var highlightLayer = [CGFloat](repeating: 0, count: width * height)
        var specularLayer = [CGFloat](repeating: 0, count: width * height)
        var normalX = [CGFloat](repeating: 0, count: width * height)
        var normalY = [CGFloat](repeating: 0, count: width * height)

        if width > 2, height > 2 {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    guard primary[i] > 0.001 else { continue }

                    let ax = primary[i + 1] - primary[i - 1]
                    let ay = primary[i + width] - primary[i - width]
                    let len = sqrt(ax * ax + ay * ay) + 0.0001
                    normalX[i] = ax / len
                    normalY[i] = ay / len

                    let lumDelta = linearLuminance[i] - localLum[i]
                    detailDelta[i] = max(-0.30, min(0.30, lumDelta)) * primary[i]

                    let edgeBand = clamp01(abs(primary[i] - softPrimary[i]) * 4.0 + len * 1.6)
                    let dark = 1 - smoothstep(edge0: 0.18, edge1: 0.58, value: tone[i])
                    let light = smoothstep(edge0: 0.48, edge1: 0.92, value: tone[i])
                    shadowLayer[i] = clamp01(primary[i] * dark * (0.48 + edgeBand * 0.25))
                    highlightLayer[i] = clamp01(primary[i] * light * (0.35 + edgeBand * 0.35))

                    // Negative Y normal roughly means the edge faces the vertical light from above.
                    let topFacing = clamp01((-normalY[i] + 0.20) / 1.20)
                    specularLayer[i] = clamp01(edgeBand * topFacing * primary[i])
                }
            }
        }

        return LayerStack(
            width: width,
            height: height,
            background: background,
            flattenedSource: flattened,
            primaryOpacity: primary,
            tone: tone,
            detailDelta: detailDelta,
            shadowLayer: shadowLayer,
            highlightLayer: highlightLayer,
            specularLayer: specularLayer,
            normalX: normalX,
            normalY: normalY
        )
    }

    // MARK: - Mask / filter helpers

    private func majorityFilter(_ source: [Bool], width: Int, height: Int) -> [Bool] {
        guard width > 2, height > 2 else { return source }
        var result = source

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var count = 0
                for oy in -1...1 {
                    for ox in -1...1 where source[(y + oy) * width + (x + ox)] {
                        count += 1
                    }
                }
                let i = y * width + x
                result[i] = source[i] ? count >= 3 : count >= 6
            }
        }
        return result
    }

    private func keepMeaningfulComponents(
        _ source: [Bool],
        width: Int,
        height: Int,
        minimumSize: Int
    ) -> [Bool] {
        var visited = [Bool](repeating: false, count: source.count)
        var result = [Bool](repeating: false, count: source.count)
        let directions = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for start in 0..<source.count where source[start] && !visited[start] {
            var queue = [start]
            var head = 0
            var component: [Int] = []
            visited[start] = true

            while head < queue.count {
                let current = queue[head]
                head += 1
                component.append(current)
                let x = current % width
                let y = current / width

                for (dx, dy) in directions {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    guard source[next], !visited[next] else { continue }
                    visited[next] = true
                    queue.append(next)
                }
            }

            if component.count >= minimumSize {
                for i in component { result[i] = true }
            }
        }
        return result
    }

    private func dilateMask(_ source: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return source }
        var result = source
        for y in 0..<height {
            for x in 0..<width where source[y * width + x] {
                for ny in max(0, y - radius)...min(height - 1, y + radius) {
                    for nx in max(0, x - radius)...min(width - 1, x + radius) {
                        result[ny * width + nx] = true
                    }
                }
            }
        }
        return result
    }

    private func gaussian3x3(_ source: [CGFloat], width: Int, height: Int) -> [CGFloat] {
        guard width > 2, height > 2 else { return source }
        var result = source
        let weights = [1, 2, 1, 2, 4, 2, 1, 2, 1]

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum: CGFloat = 0
                var k = 0
                for oy in -1...1 {
                    for ox in -1...1 {
                        sum += source[(y + oy) * width + (x + ox)] * CGFloat(weights[k])
                        k += 1
                    }
                }
                result[y * width + x] = sum / 16
            }
        }
        return result
    }

    /// Separable box blur in O(N), used for local tonal/detail decomposition and edge profiles.
    private func boxBlur(_ source: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, width > 0, height > 0 else { return source }
        var horizontal = [CGFloat](repeating: 0, count: source.count)
        var output = [CGFloat](repeating: 0, count: source.count)

        for y in 0..<height {
            var prefix = [CGFloat](repeating: 0, count: width + 1)
            for x in 0..<width {
                prefix[x + 1] = prefix[x] + source[y * width + x]
            }
            for x in 0..<width {
                let lo = max(0, x - radius)
                let hi = min(width - 1, x + radius)
                horizontal[y * width + x] = (prefix[hi + 1] - prefix[lo]) / CGFloat(hi - lo + 1)
            }
        }

        for x in 0..<width {
            var prefix = [CGFloat](repeating: 0, count: height + 1)
            for y in 0..<height {
                prefix[y + 1] = prefix[y] + horizontal[y * width + x]
            }
            for y in 0..<height {
                let lo = max(0, y - radius)
                let hi = min(height - 1, y + radius)
                output[y * width + x] = (prefix[hi + 1] - prefix[lo]) / CGFloat(hi - lo + 1)
            }
        }
        return output
    }

    private func weightedToneRange(luminance: [CGFloat], weights: [CGFloat]) -> (CGFloat, CGFloat) {
        var histogram = [CGFloat](repeating: 0, count: 256)
        var total: CGFloat = 0

        for i in 0..<min(luminance.count, weights.count) {
            let w = clamp01(weights[i])
            guard w > 0.01 else { continue }
            let bin = min(255, max(0, Int(clamp01(luminance[i]) * 255)))
            histogram[bin] += w
            total += w
        }

        guard total > 0 else { return (0, 1) }

        func percentile(_ q: CGFloat) -> CGFloat {
            let target = total * q
            var cumulative: CGFloat = 0
            for i in 0..<256 {
                cumulative += histogram[i]
                if cumulative >= target { return CGFloat(i) / 255 }
            }
            return 1
        }

        let low = percentile(0.04)
        let high = percentile(0.96)
        if high - low < 0.08 { return (max(0, low - 0.04), min(1, high + 0.04)) }
        return (low, high)
    }

    // MARK: - Background reconstruction

    private func backgroundReferences(pixels: [UInt8], width: Int, height: Int) -> [RGB] {
        let radius = max(4, min(width, height) / 30)
        let points = [
            (radius, radius),
            (width - 1 - radius, radius),
            (radius, height - 1 - radius),
            (width - 1 - radius, height - 1 - radius),
            (width / 2, radius),
            (width / 2, height - 1 - radius),
            (radius, height / 2),
            (width - 1 - radius, height / 2)
        ]
        return points.compactMap {
            patchMean(pixels: pixels, width: width, height: height, centerX: $0.0, centerY: $0.1, radius: radius)
        }
    }

    private func cornerBackgrounds(pixels: [UInt8], width: Int, height: Int) -> [RGB] {
        let radius = max(4, min(width, height) / 30)
        let fallback = mean(backgroundReferences(pixels: pixels, width: width, height: height))
        return [
            patchMean(pixels: pixels, width: width, height: height, centerX: radius, centerY: radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, centerX: width - 1 - radius, centerY: radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, centerX: radius, centerY: height - 1 - radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, centerX: width - 1 - radius, centerY: height - 1 - radius, radius: radius) ?? fallback
        ]
    }

    private func patchMean(
        pixels: [UInt8],
        width: Int,
        height: Int,
        centerX: Int,
        centerY: Int,
        radius: Int
    ) -> RGB? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var weight: CGFloat = 0

        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let p = (y * width + x) * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.02 else { continue }
                let c = unpremultipliedRGB(pixels: pixels, offset: p, alpha: alpha)
                r += c.r * alpha
                g += c.g * alpha
                b += c.b * alpha
                weight += alpha
            }
        }

        guard weight > 0 else { return nil }
        return RGB(r: r / weight, g: g / weight, b: b / weight)
    }

    // MARK: - Color math

    private func luminanceLinear(_ color: RGB) -> CGFloat {
        let l = toLinear(color)
        return 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b
    }

    private func oklab(_ rgb: RGB) -> Oklab {
        let c = toLinear(rgb)
        let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b
        let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b
        let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b
        let l_ = cbrt(l)
        let m_ = cbrt(m)
        let s_ = cbrt(s)
        return Oklab(
            l: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    private func toLinear(_ c: RGB) -> RGB {
        RGB(r: srgbToLinear(c.r), g: srgbToLinear(c.g), b: srgbToLinear(c.b))
    }

    private func fromLinear(_ c: RGB) -> RGB {
        RGB(r: linearToSRGB(c.r), g: linearToSRGB(c.g), b: linearToSRGB(c.b))
    }

    private func srgbToLinear(_ v: CGFloat) -> CGFloat {
        let x = clamp01(v)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private func linearToSRGB(_ v: CGFloat) -> CGFloat {
        let x = max(0, v)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    private func mix(_ a: RGB, _ b: RGB, amount: CGFloat) -> RGB {
        let t = clamp01(amount)
        return RGB(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t
        )
    }

    private func mixLinear(_ a: RGB, _ b: RGB, amount: CGFloat) -> RGB {
        let la = toLinear(a)
        let lb = toLinear(b)
        return fromLinear(mix(la, lb, amount: amount))
    }

    private func scaleLinear(_ c: RGB, factor: CGFloat) -> RGB {
        let l = toLinear(c)
        return fromLinear(RGB(r: l.r * factor, g: l.g * factor, b: l.b * factor))
    }

    private func screen(_ base: RGB, _ blend: RGB, amount: CGFloat) -> RGB {
        let a = clamp01(amount)
        let screened = RGB(
            r: 1 - (1 - clamp01(base.r)) * (1 - clamp01(blend.r)),
            g: 1 - (1 - clamp01(base.g)) * (1 - clamp01(blend.g)),
            b: 1 - (1 - clamp01(base.b)) * (1 - clamp01(blend.b))
        )
        return mix(base, screened, amount: a)
    }

    private func bilinear(_ corners: [RGB], x: CGFloat, y: CGFloat) -> RGB {
        guard corners.count >= 4 else { return mean(corners) }
        let top = mix(corners[0], corners[1], amount: x)
        let bottom = mix(corners[2], corners[3], amount: x)
        return mix(top, bottom, amount: y)
    }

    private func mean(_ colors: [RGB]) -> RGB {
        guard !colors.isEmpty else { return RGB(r: 0.11, g: 0.11, b: 0.12) }
        let n = CGFloat(colors.count)
        let sum = colors.reduce(RGB(r: 0, g: 0, b: 0)) {
            RGB(r: $0.r + $1.r, g: $0.g + $1.g, b: $0.b + $1.b)
        }
        return RGB(r: sum.r / n, g: sum.g / n, b: sum.b / n)
    }

    private func rgb(from color: UIColor) -> RGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return RGB(r: r, g: g, b: b)
        }
        return RGB(r: 0, g: 0.478, b: 1)
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp01((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    private func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

    // MARK: - Sampling / bitmap handling

    private func sample(_ data: [RGB], width: Int, height: Int, x: CGFloat, y: CGFloat) -> RGB {
        let sx = min(CGFloat(width - 1), max(0, x))
        let sy = min(CGFloat(height - 1), max(0, y))
        let x0 = Int(floor(sx))
        let y0 = Int(floor(sy))
        let x1 = min(width - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let tx = sx - CGFloat(x0)
        let ty = sy - CGFloat(y0)
        let top = mix(data[y0 * width + x0], data[y0 * width + x1], amount: tx)
        let bottom = mix(data[y1 * width + x0], data[y1 * width + x1], amount: tx)
        return mix(top, bottom, amount: ty)
    }

    private func rgbaPixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func imageFromOpaqueRGBA(_ data: [UInt8], width: Int, height: Int) -> UIImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func unpremultipliedRGB(pixels: [UInt8], offset: Int, alpha: CGFloat) -> RGB {
        guard alpha > 0.0001 else { return RGB(r: 0, g: 0, b: 0) }
        return RGB(
            r: min(1, CGFloat(pixels[offset]) / 255 / alpha),
            g: min(1, CGFloat(pixels[offset + 1]) / 255 / alpha),
            b: min(1, CGFloat(pixels[offset + 2]) / 255 / alpha)
        )
    }

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(clamp01(value) * 255 + 0.5))
    }
}