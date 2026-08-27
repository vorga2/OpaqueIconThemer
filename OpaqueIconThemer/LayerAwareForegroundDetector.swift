import Foundation
import UIKit

/// Reconstructs a soft foreground/material mask from a flattened app icon.
///
/// A single "distance from border color" threshold loses translucent / low-contrast nested
/// layers (the middle of Settings is a good example). This detector combines:
/// - Oklab distance from the inferred background;
/// - true source alpha when present;
/// - local luminance residual / edge structure;
/// - multi-scale support from already-confident foreground pixels.
///
/// The support term is deliberately local. It recovers nested material inside a logo without
/// turning an unrelated smooth icon background into foreground.
final class LayerAwareForegroundDetector {
    static let shared = LayerAwareForegroundDetector()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    private struct Lab {
        var l: CGFloat
        var a: CGFloat
        var b: CGFloat

        func distance(to other: Lab) -> CGFloat {
            let dl = l - other.l
            let da = a - other.a
            let db = b - other.b
            return sqrt(dl * dl + da * da + db * db)
        }
    }

    func foregroundMask(source: UIImage, width: Int = 512, height: Int = 512) -> [CGFloat]? {
        guard width > 2, height > 2,
              let pixels = rgbaPixels(from: source, width: width, height: height) else {
            return nil
        }

        let references = borderReferences(pixels: pixels, width: width, height: height)
        guard !references.isEmpty else { return nil }

        let referenceLabs = references.map(oklab)
        let meanBackground = mean(references)
        let meanLab = oklab(meanBackground)
        let variation = referenceLabs.reduce(CGFloat.zero) {
            $0 + $1.distance(to: meanLab)
        } / CGFloat(max(1, referenceLabs.count))

        // Slightly lower floor than the old binary detector. We do not directly use this as a
        // foreground mask; low-confidence pixels still need structure and nearby-layer support.
        let threshold = min(0.235, max(0.032, 0.047 + variation * 0.94))
        let count = width * height

        var direct = [CGFloat](repeating: 0, count: count)
        var weak = [CGFloat](repeating: 0, count: count)
        var alphaEvidence = [CGFloat](repeating: 0, count: count)
        var luminance = [CGFloat](repeating: 0, count: count)

        for i in 0..<count {
            let p = i * 4
            let alpha = CGFloat(pixels[p + 3]) / 255.0
            let color = alpha > 0.0001
                ? straightRGB(pixels: pixels, offset: p, alpha: alpha)
                : meanBackground

            let lab = oklab(color)
            let distance = referenceLabs.map { lab.distance(to: $0) }.min() ?? 1

            direct[i] = smoothstep(
                edge0: threshold * 0.52,
                edge1: max(threshold * 1.48, threshold + 0.030),
                value: distance
            )
            weak[i] = smoothstep(
                edge0: threshold * 0.14,
                edge1: max(threshold * 0.92, threshold + 0.010),
                value: distance
            )

            // Real alpha is strong evidence of a separate layer, but avoid making fully opaque
            // flattened App Store artwork look like one giant foreground rectangle.
            if alpha > 0.001 && alpha < 0.995 {
                alphaEvidence[i] = alpha
            }

            let linear = srgbToLinear(color)
            luminance[i] = clamp(
                0.2126 * linear.r + 0.7152 * linear.g + 0.0722 * linear.b,
                0,
                1
            )
        }

        let localMean = boxBlur(luminance, width: width, height: height, radius: 6)
        var structure = [CGFloat](repeating: 0, count: count)

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let residual = abs(luminance[i] - localMean[i])
                let dx = abs(luminance[i + 1] - luminance[i - 1])
                let dy = abs(luminance[i + width] - luminance[i - width])
                let gradient = dx + dy

                // Low-contrast semi-transparent surfaces can have little global color distance,
                // but they still carry local bevels, spokes, rings, highlights and occlusion edges.
                let evidence = residual * 1.45 + gradient * 0.72
                structure[i] = smoothstep(edge0: 0.010, edge1: 0.090, value: evidence)
            }
        }

        // Multi-scale support is the key for nested material. A faint inner piece is accepted when
        // it lives inside/next to confidently detected foreground, while an unrelated background
        // gradient far from the logo remains background.
        let supportNear = boxBlur(direct, width: width, height: height, radius: 14)
        let supportWide = boxBlur(direct, width: width, height: height, radius: 34)

        var result = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            let neighborhood = clamp(supportNear[i] * 1.70 + supportWide[i] * 0.70, 0, 1)
            let nestedLayer = weak[i] * (0.30 + 0.70 * neighborhood)
            let structuredLayer = structure[i] * neighborhood
            let translucentLayer = alphaEvidence[i] * (0.55 + 0.45 * max(structure[i], neighborhood))

            var value = max(direct[i], nestedLayer)
            value = max(value, structuredLayer)
            value = max(value, translucentLayer)

            // Keep weak anti-aliased material around a confident layer, but do not grow the mask
            // across a smooth background.
            if supportNear[i] > 0.035 {
                value = max(value, weak[i] * 0.46)
            }

            result[i] = clamp(value, 0, 1)
        }

        // Two small passes preserve antialiasing and remove tiny threshold holes. This is much less
        // destructive than majority-filtering a binary mask before the low-opacity layers are found.
        result = gaussian3x3(result, width: width, height: height)
        result = gaussian3x3(result, width: width, height: height)

        // Safety against pathological full-art backgrounds: if almost everything became foreground,
        // prefer the direct perceptual signal instead of allowing local-detail recovery to engulf it.
        let recoveredCoverage = CGFloat(result.reduce(0) { $0 + ($1 > 0.50 ? 1 : 0) }) / CGFloat(count)
        if recoveredCoverage > 0.86 {
            return gaussian3x3(direct, width: width, height: height)
        }

        return result.map { clamp($0, 0, 1) }
    }

    // MARK: - Filtering

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

    private func boxBlur(_ source: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, source.count == width * height else { return source }
        var horizontal = [CGFloat](repeating: 0, count: source.count)
        var output = [CGFloat](repeating: 0, count: source.count)

        for y in 0..<height {
            let row = y * width
            var sum: CGFloat = 0
            var samples = 0
            for x in 0...min(width - 1, radius) {
                sum += source[row + x]
                samples += 1
            }
            for x in 0..<width {
                horizontal[row + x] = sum / CGFloat(max(1, samples))
                let remove = x - radius
                let add = x + radius + 1
                if remove >= 0 {
                    sum -= source[row + remove]
                    samples -= 1
                }
                if add < width {
                    sum += source[row + add]
                    samples += 1
                }
            }
        }

        for x in 0..<width {
            var sum: CGFloat = 0
            var samples = 0
            for y in 0...min(height - 1, radius) {
                sum += horizontal[y * width + x]
                samples += 1
            }
            for y in 0..<height {
                output[y * width + x] = sum / CGFloat(max(1, samples))
                let remove = y - radius
                let add = y + radius + 1
                if remove >= 0 {
                    sum -= horizontal[remove * width + x]
                    samples -= 1
                }
                if add < height {
                    sum += horizontal[add * width + x]
                    samples += 1
                }
            }
        }
        return output
    }

    // MARK: - Background sampling

    private func borderReferences(pixels: [UInt8], width: Int, height: Int) -> [RGB] {
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
            patchMean(
                pixels: pixels,
                width: width,
                height: height,
                cx: $0.0,
                cy: $0.1,
                radius: radius
            )
        }
    }

    private func patchMean(
        pixels: [UInt8],
        width: Int,
        height: Int,
        cx: Int,
        cy: Int,
        radius: Int
    ) -> RGB? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var weight: CGFloat = 0

        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                let p = (y * width + x) * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.02 else { continue }
                let color = straightRGB(pixels: pixels, offset: p, alpha: alpha)
                r += color.r * alpha
                g += color.g * alpha
                b += color.b * alpha
                weight += alpha
            }
        }

        guard weight > 0 else { return nil }
        return RGB(r: r / weight, g: g / weight, b: b / weight)
    }

    // MARK: - Color math / pixels

    private func oklab(_ rgb: RGB) -> Lab {
        let c = srgbToLinear(rgb)
        let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b
        let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b
        let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b
        let ll = cbrt(max(0, l))
        let mm = cbrt(max(0, m))
        let ss = cbrt(max(0, s))
        return Lab(
            l: 0.2104542553 * ll + 0.7936177850 * mm - 0.0040720468 * ss,
            a: 1.9779984951 * ll - 2.4285922050 * mm + 0.4505937099 * ss,
            b: 0.0259040371 * ll + 0.7827717662 * mm - 0.8086757660 * ss
        )
    }

    private func srgbToLinear(_ rgb: RGB) -> RGB {
        RGB(r: srgbToLinear(rgb.r), g: srgbToLinear(rgb.g), b: srgbToLinear(rgb.b))
    }

    private func srgbToLinear(_ value: CGFloat) -> CGFloat {
        let v = clamp(value, 0, 1)
        if v <= 0.04045 { return v / 12.92 }
        return pow((v + 0.055) / 1.055, 2.4)
    }

    private func straightRGB(pixels: [UInt8], offset: Int, alpha: CGFloat) -> RGB {
        guard alpha > 0.0001 else { return RGB(r: 0, g: 0, b: 0) }
        return RGB(
            r: clamp(CGFloat(pixels[offset]) / 255.0 / alpha, 0, 1),
            g: clamp(CGFloat(pixels[offset + 1]) / 255.0 / alpha, 0, 1),
            b: clamp(CGFloat(pixels[offset + 2]) / 255.0 / alpha, 0, 1)
        )
    }

    private func mean(_ values: [RGB]) -> RGB {
        guard !values.isEmpty else { return RGB(r: 0.5, g: 0.5, b: 0.5) }
        let n = CGFloat(values.count)
        let sums = values.reduce((CGFloat.zero, CGFloat.zero, CGFloat.zero)) {
            ($0.0 + $1.r, $0.1 + $1.g, $0.2 + $1.b)
        }
        return RGB(r: sums.0 / n, g: sums.1 / n, b: sums.2 / n)
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
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
}
