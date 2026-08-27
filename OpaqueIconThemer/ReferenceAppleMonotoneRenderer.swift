import Foundation
import UIKit

/// Static Apple-style monotone approximation based on the research/reference pipeline:
/// - perceptual foreground segmentation for legacy bitmap icons;
/// - straight-alpha aware processing;
/// - sRGB -> linear-light luminance;
/// - two-point tonal ramp instead of gamma-space multiply tint;
/// - soft antialiased foreground coverage;
/// - output alpha is always 1.0 (the intentional difference from Apple's translucent material).
///
/// Apple's exact legacy segmentation and Liquid Glass shader are private. This renderer targets
/// the static Mono/tinted appearance as closely as possible without claiming those private stages.
final class ReferenceAppleMonotoneRenderer {
    static let shared = ReferenceAppleMonotoneRenderer()

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

    // MARK: - Public rendering

    func renderSmartLogo(
        source: UIImage,
        tint: UIColor,
        gradientStart: CGFloat,
        gradientStrength: CGFloat
    ) -> UIImage? {
        let width = 512
        let height = 512
        guard let pixels = rgbaPixels(from: source, width: width, height: height) else { return nil }

        let references = borderReferences(pixels: pixels, width: width, height: height)
        guard !references.isEmpty else { return nil }

        let referenceLabs = references.map(oklab)
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

        let corners = cornerBackgrounds(
            pixels: pixels,
            width: width,
            height: height,
            fallback: meanBackground
        )

        let tintLinear = srgbToLinear(rgb(from: tint))
        let start = clamp(gradientStart, 0.0, 1.0)
        let strength = clamp(gradientStrength, 0.0, 1.0)

        // White Mono hierarchy in linear light. This retains relief/volume without preserving
        // the source hue. Highlights reach white; shadows remain bright like Apple's Mono art.
        let monoShadow = RGB(r: 0.72, g: 0.72, b: 0.72)
        let monoHighlight = RGB(r: 1.00, g: 1.00, b: 1.00)

        // Selected-color hierarchy used only by the lower spatial gradient.
        let tintedShadow = mix(multiply(tintLinear, 0.58), monoShadow, amount: 0.12)
        let tintedHighlight = mix(tintLinear, RGB(r: 1, g: 1, b: 1), amount: 0.78)

        var output = [UInt8](repeating: 0, count: pixels.count)

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            let spatial: CGFloat
            if yNorm <= start {
                spatial = 0
            } else {
                // Smooth rather than linear onset removes the visible "50% seam".
                let t = clamp((yNorm - start) / max(0.001, 1 - start), 0, 1)
                spatial = (t * t * (3 - 2 * t)) * strength
            }

            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))
                let background = bilinear(corners, x: xNorm, y: yNorm)

                let straight = alpha > 0.0001
                    ? straightRGB(pixels: pixels, offset: p, alpha: alpha)
                    : background

                // Intentional project behavior: flatten source onto the inferred local background,
                // therefore every final pixel is opaque even if the input PNG has transparency.
                let flattened = mix(background, straight, amount: alpha)

                let glyphCoverage = clamp(softMask[i], 0, 1)
                guard glyphCoverage > 0.0001 else {
                    write(flattened, to: &output, offset: p, alpha: 255)
                    continue
                }

                // Reference report: exact sRGB decoding, linear-light Rec.709 luminance,
                // and a tonal ramp rather than gamma-space multiplication.
                let linearSource = srgbToLinear(straight)
                let luminance = clamp(
                    0.2126 * linearSource.r +
                    0.7152 * linearSource.g +
                    0.0722 * linearSource.b,
                    0,
                    1
                )

                let mono = mix(monoShadow, monoHighlight, amount: luminance)
                let colored = mix(tintedShadow, tintedHighlight, amount: luminance)
                let logoLinear = mix(mono, colored, amount: spatial)
                let logoSRGB = linearToSRGB(logoLinear)

                let result = mix(flattened, logoSRGB, amount: glyphCoverage)
                write(result, to: &output, offset: p, alpha: 255)
            }
        }

        return finalImage(output, width: width, height: height)
    }

    /// Detailed/game fallback: no semantic glyph extraction. The complete bitmap is mapped to a
    /// linear-light two-point tint ramp, preserving luminance hierarchy and forcing alpha = 1.
    func renderTintedBitmap(
        source: UIImage,
        tint: UIColor,
        intensity: CGFloat
    ) -> UIImage? {
        let width = 512
        let height = 512
        guard let pixels = rgbaPixels(from: source, width: width, height: height) else { return nil }

        let references = borderReferences(pixels: pixels, width: width, height: height)
        let fallback = references.isEmpty ? RGB(r: 0.15, g: 0.15, b: 0.16) : mean(references)
        let corners = cornerBackgrounds(pixels: pixels, width: width, height: height, fallback: fallback)

        let tintLinear = srgbToLinear(rgb(from: tint))
        let amount = clamp(intensity, 0, 1)

        // Apple-like duotone hierarchy: deep selected-color shadows + pale tinted highlights.
        let shadow = multiply(tintLinear, 0.34)
        let highlight = mix(tintLinear, RGB(r: 1, g: 1, b: 1), amount: 0.82)

        var output = [UInt8](repeating: 0, count: pixels.count)

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))
                let background = bilinear(corners, x: xNorm, y: yNorm)
                let straight = alpha > 0.0001
                    ? straightRGB(pixels: pixels, offset: p, alpha: alpha)
                    : background
                let flattened = mix(background, straight, amount: alpha)

                let linearSource = srgbToLinear(straight)
                let yLinear = clamp(
                    0.2126 * linearSource.r +
                    0.7152 * linearSource.g +
                    0.0722 * linearSource.b,
                    0,
                    1
                )
                let mapped = linearToSRGB(mix(shadow, highlight, amount: yLinear))
                let result = mix(flattened, mapped, amount: amount)
                write(result, to: &output, offset: p, alpha: 255)
            }
        }

        return finalImage(output, width: width, height: height)
    }

    // MARK: - Pixel/image helpers

    private func finalImage(_ rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let work = imageFromRGBA(rgba, width: width, height: height) else { return nil }
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            work.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func rgbaPixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmap
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func imageFromRGBA(_ data: [UInt8], width: Int, height: Int) -> UIImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func straightRGB(pixels: [UInt8], offset: Int, alpha: CGFloat) -> RGB {
        guard alpha > 0.0001 else { return RGB(r: 0, g: 0, b: 0) }
        return RGB(
            r: clamp(CGFloat(pixels[offset]) / 255.0 / alpha, 0, 1),
            g: clamp(CGFloat(pixels[offset + 1]) / 255.0 / alpha, 0, 1),
            b: clamp(CGFloat(pixels[offset + 2]) / 255.0 / alpha, 0, 1)
        )
    }

    private func write(_ rgb: RGB, to output: inout [UInt8], offset: Int, alpha: UInt8) {
        output[offset] = byte(rgb.r)
        output[offset + 1] = byte(rgb.g)
        output[offset + 2] = byte(rgb.b)
        output[offset + 3] = alpha
    }

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(clamp(value, 0, 1) * 255.0 + 0.5))
    }

    // MARK: - Background/segmentation helpers

    private func borderReferences(pixels: [UInt8], width: Int, height: Int) -> [RGB] {
        let radius = max(4, min(width, height) / 28)
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
            patchMean(pixels: pixels, width: width, height: height, cx: $0.0, cy: $0.1, radius: radius)
        }
    }

    private func cornerBackgrounds(
        pixels: [UInt8],
        width: Int,
        height: Int,
        fallback: RGB
    ) -> [RGB] {
        let radius = max(4, min(width, height) / 28)
        return [
            patchMean(pixels: pixels, width: width, height: height, cx: radius, cy: radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, cx: width - 1 - radius, cy: radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, cx: radius, cy: height - 1 - radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, cx: width - 1 - radius, cy: height - 1 - radius, radius: radius) ?? fallback
        ]
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
                guard alpha > 0.03 else { continue }
                let value = straightRGB(pixels: pixels, offset: p, alpha: alpha)
                r += value.r * alpha
                g += value.g * alpha
                b += value.b * alpha
                weight += alpha
            }
        }
        guard weight > 0 else { return nil }
        return RGB(r: r / weight, g: g / weight, b: b / weight)
    }

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
        let dirs = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

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
                for (dx, dy) in dirs {
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

    private func dilate(_ source: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
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
                result[y * width + x] = sum / 16.0
            }
        }
        return result
    }

    // MARK: - Color math

    private func srgbToLinear(_ rgb: RGB) -> RGB {
        RGB(r: srgbToLinear(rgb.r), g: srgbToLinear(rgb.g), b: srgbToLinear(rgb.b))
    }

    private func linearToSRGB(_ rgb: RGB) -> RGB {
        RGB(r: linearToSRGB(rgb.r), g: linearToSRGB(rgb.g), b: linearToSRGB(rgb.b))
    }

    private func srgbToLinear(_ c: CGFloat) -> CGFloat {
        let c = clamp(c, 0, 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func linearToSRGB(_ c: CGFloat) -> CGFloat {
        let c = max(0, c)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    private func oklab(_ rgb: RGB) -> Lab {
        let linear = srgbToLinear(rgb)
        let l = 0.4122214708 * linear.r + 0.5363325363 * linear.g + 0.0514459929 * linear.b
        let m = 0.2119034982 * linear.r + 0.6806995451 * linear.g + 0.1073969566 * linear.b
        let s = 0.0883024619 * linear.r + 0.2817188376 * linear.g + 0.6299787005 * linear.b
        let ll = Foundation.pow(max(0, l), 1.0 / 3.0)
        let mm = Foundation.pow(max(0, m), 1.0 / 3.0)
        let ss = Foundation.pow(max(0, s), 1.0 / 3.0)
        return Lab(
            l: 0.2104542553 * ll + 0.7936177850 * mm - 0.0040720468 * ss,
            a: 1.9779984951 * ll - 2.4285922050 * mm + 0.4505937099 * ss,
            b: 0.0259040371 * ll + 0.7827717662 * mm - 0.8086757660 * ss
        )
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

    private func mean(_ values: [RGB]) -> RGB {
        guard !values.isEmpty else { return RGB(r: 0.5, g: 0.5, b: 0.5) }
        let count = CGFloat(values.count)
        let total = values.reduce(RGB(r: 0, g: 0, b: 0)) { partial, value in
            RGB(r: partial.r + value.r, g: partial.g + value.g, b: partial.b + value.b)
        }
        return RGB(r: total.r / count, g: total.g / count, b: total.b / count)
    }

    private func bilinear(_ corners: [RGB], x: CGFloat, y: CGFloat) -> RGB {
        guard corners.count >= 4 else { return mean(corners) }
        let top = mix(corners[0], corners[1], amount: x)
        let bottom = mix(corners[2], corners[3], amount: x)
        return mix(top, bottom, amount: y)
    }

    private func mix(_ first: RGB, _ second: RGB, amount: CGFloat) -> RGB {
        let t = clamp(amount, 0, 1)
        return RGB(
            r: first.r + (second.r - first.r) * t,
            g: first.g + (second.g - first.g) * t,
            b: first.b + (second.b - first.b) * t
        )
    }

    private func multiply(_ value: RGB, _ amount: CGFloat) -> RGB {
        RGB(r: value.r * amount, g: value.g * amount, b: value.b * amount)
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }
}
