import Foundation
import UIKit

/// Apple-inspired smart-logo renderer.
///
/// Important: IconServices is private implementation detail, so this is a visual reproduction,
/// not a claim that Apple uses these exact thresholds internally.
///
/// The output is always fully opaque (alpha = 1.0) while the detected logo keeps its original
/// per-pixel transparency, antialiasing and soft edges by baking that alpha into the composite.
final class AppleLikeLogoRenderer {
    static let shared = AppleLikeLogoRenderer()

    private init() {}

    private struct RGB {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
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

    func render(
        source: UIImage,
        tint: UIColor,
        gradientStart: CGFloat,
        gradientStrength: CGFloat
    ) -> UIImage? {
        let workWidth = 512
        let workHeight = 512

        guard let pixels = rgbaPixels(from: source, width: workWidth, height: workHeight) else {
            return nil
        }

        let backgroundRGB = backgroundReferences(
            pixels: pixels,
            width: workWidth,
            height: workHeight
        )
        guard !backgroundRGB.isEmpty else { return nil }

        let backgroundLab = backgroundRGB.map(oklab)
        let backgroundMean = mean(backgroundRGB)
        let borderVariation = backgroundLab.reduce(CGFloat.zero) {
            $0 + $1.distance(to: oklab(backgroundMean))
        } / CGFloat(max(1, backgroundLab.count))

        // Oklab distance is perceptual enough for anti-aliased logo/background separation.
        let threshold = min(0.20, max(0.035, 0.050 + borderVariation * 0.90))

        var hardMask = [Bool](repeating: false, count: workWidth * workHeight)
        var softMask = [CGFloat](repeating: 0, count: workWidth * workHeight)

        for y in 0..<workHeight {
            for x in 0..<workWidth {
                let index = y * workWidth + x
                let p = index * 4
                let sourceAlpha = CGFloat(pixels[p + 3]) / 255.0
                guard sourceAlpha > 0.002 else { continue }

                let rgb = unpremultipliedRGB(pixels: pixels, offset: p, alpha: sourceAlpha)
                let lab = oklab(rgb)
                let distance = backgroundLab.map { lab.distance(to: $0) }.min() ?? 1

                hardMask[index] = distance >= threshold * 0.78

                // Never replace the original alpha. The segmentation confidence only scales it.
                let confidence = smoothstep(
                    edge0: threshold * 0.28,
                    edge1: max(threshold * 1.70, threshold + 0.045),
                    value: distance
                )
                softMask[index] = confidence * sourceAlpha
            }
        }

        hardMask = majorityFilter(hardMask, width: workWidth, height: workHeight)
        hardMask = keepMeaningfulComponents(
            hardMask,
            width: workWidth,
            height: workHeight,
            minimumSize: max(8, Int(CGFloat(workWidth * workHeight) * 0.00004))
        )

        let hardCoverage = CGFloat(hardMask.reduce(0) { $0 + ($1 ? 1 : 0) }) / CGFloat(workWidth * workHeight)
        guard hardCoverage >= 0.010, hardCoverage <= 0.74 else { return nil }

        let allowedMask = dilateMask(hardMask, width: workWidth, height: workHeight, radius: 3)
        for i in 0..<softMask.count where !allowedMask[i] {
            softMask[i] = 0
        }

        // 3x3 Gaussian-like pass. This preserves edge coverage instead of converting the glyph
        // into a binary sticker.
        softMask = gaussian3x3(softMask, width: workWidth, height: workHeight)

        let corners = cornerBackgrounds(
            pixels: pixels,
            width: workWidth,
            height: workHeight,
            fallback: backgroundMean
        )

        let tintRGB = rgb(from: tint)
        let start = min(0.90, max(0.05, gradientStart))
        let strength = min(0.65, max(0, gradientStrength))

        var output = [UInt8](repeating: 0, count: pixels.count)

        for y in 0..<workHeight {
            let yNorm = CGFloat(y) / CGFloat(max(1, workHeight - 1))
            let gradientProgress: CGFloat
            if yNorm <= start {
                gradientProgress = 0
            } else {
                gradientProgress = (yNorm - start) / max(0.001, 1 - start)
            }

            let tintMix = min(1, max(0, gradientProgress * strength))
            let baseLogoColor = mix(
                RGB(r: 1, g: 1, b: 1),
                tintRGB,
                amount: tintMix
            )

            for x in 0..<workWidth {
                let index = y * workWidth + x
                let p = index * 4
                let sourceAlpha = CGFloat(pixels[p + 3]) / 255.0
                let xNorm = CGFloat(x) / CGFloat(max(1, workWidth - 1))
                let reconstructedBackground = bilinear(corners, x: xNorm, y: yNorm)

                let originalRGB: RGB
                if sourceAlpha > 0.0001 {
                    originalRGB = unpremultipliedRGB(pixels: pixels, offset: p, alpha: sourceAlpha)
                } else {
                    originalRGB = reconstructedBackground
                }

                // Flatten the original icon onto a reconstructed local background so the final
                // image has alpha=1 everywhere, including transparent PNG backgrounds.
                let flattenedSource = mix(reconstructedBackground, originalRGB, amount: sourceAlpha)

                let glyphAlpha = min(1, max(0, softMask[index]))
                let result: RGB

                if glyphAlpha > 0.0005 {
                    // Keep subtle luminance structure inside the logo while staying visually white.
                    // This retains translucent/shaded Apple-style details instead of erasing them.
                    let luminance = min(1, max(0,
                        0.299 * originalRGB.r +
                        0.587 * originalRGB.g +
                        0.114 * originalRGB.b
                    ))
                    let volume = 0.88 + 0.12 * luminance
                    let logoColor = RGB(
                        r: min(1, baseLogoColor.r * volume),
                        g: min(1, baseLogoColor.g * volume),
                        b: min(1, baseLogoColor.b * volume)
                    )
                    result = mix(flattenedSource, logoColor, amount: glyphAlpha)
                } else {
                    result = flattenedSource
                }

                output[p] = byte(result.r)
                output[p + 1] = byte(result.g)
                output[p + 2] = byte(result.b)
                output[p + 3] = 255 // background/output opacity is always exactly 1.0
            }
        }

        guard let workImage = imageFromRGBA(output, width: workWidth, height: workHeight) else {
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

    // MARK: - Segmentation helpers

    private func backgroundReferences(pixels: [UInt8], width: Int, height: Int) -> [RGB] {
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
            patchMean(
                pixels: pixels,
                width: width,
                height: height,
                centerX: $0.0,
                centerY: $0.1,
                radius: radius
            )
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

        let minX = max(0, centerX - radius)
        let maxX = min(width - 1, centerX + radius)
        let minY = max(0, centerY - radius)
        let maxY = min(height - 1, centerY + radius)

        for y in minY...maxY {
            for x in minX...maxX {
                let p = (y * width + x) * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.03 else { continue }
                let value = unpremultipliedRGB(pixels: pixels, offset: p, alpha: alpha)
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
        let weights = [
            1, 2, 1,
            2, 4, 2,
            1, 2, 1
        ]

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum: CGFloat = 0
                var w = 0
                var k = 0
                for oy in -1...1 {
                    for ox in -1...1 {
                        let weight = weights[k]
                        sum += source[(y + oy) * width + (x + ox)] * CGFloat(weight)
                        w += weight
                        k += 1
                    }
                }
                result[y * width + x] = sum / CGFloat(w)
            }
        }
        return result
    }

    // MARK: - Color math

    private func oklab(_ rgb: RGB) -> Oklab {
        let r = linear(rgb.r)
        let g = linear(rgb.g)
        let b = linear(rgb.b)

        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let l_ = cbrt(l)
        let m_ = cbrt(m)
        let s_ = cbrt(s)

        return Oklab(
            l: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    private func linear(_ value: CGFloat) -> CGFloat {
        let v = min(1, max(0, value))
        if v <= 0.04045 {
            return v / 12.92
        }
        return pow((v + 0.055) / 1.055, 2.4)
    }

    private func mean(_ colors: [RGB]) -> RGB {
        guard !colors.isEmpty else { return RGB(r: 0.11, g: 0.11, b: 0.12) }
        let c = CGFloat(colors.count)
        let sums = colors.reduce((CGFloat.zero, CGFloat.zero, CGFloat.zero)) {
            ($0.0 + $1.r, $0.1 + $1.g, $0.2 + $1.b)
        }
        return RGB(r: sums.0 / c, g: sums.1 / c, b: sums.2 / c)
    }

    private func mix(_ first: RGB, _ second: RGB, amount: CGFloat) -> RGB {
        let t = min(1, max(0, amount))
        return RGB(
            r: first.r + (second.r - first.r) * t,
            g: first.g + (second.g - first.g) * t,
            b: first.b + (second.b - first.b) * t
        )
    }

    private func bilinear(_ corners: [RGB], x: CGFloat, y: CGFloat) -> RGB {
        guard corners.count >= 4 else { return mean(corners) }
        let top = mix(corners[0], corners[1], amount: x)
        let bottom = mix(corners[2], corners[3], amount: x)
        return mix(top, bottom, amount: y)
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
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Pixel helpers

    private func rgbaPixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func imageFromRGBA(_ data: [UInt8], width: Int, height: Int) -> UIImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
              ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private func unpremultipliedRGB(pixels: [UInt8], offset: Int, alpha: CGFloat) -> RGB {
        guard alpha > 0.0001 else { return RGB(r: 0, g: 0, b: 0) }
        return RGB(
            r: min(1, CGFloat(pixels[offset]) / 255.0 / alpha),
            g: min(1, CGFloat(pixels[offset + 1]) / 255.0 / alpha),
            b: min(1, CGFloat(pixels[offset + 2]) / 255.0 / alpha)
        )
    }

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(min(1, max(0, value)) * 255.0 + 0.5))
    }
}
