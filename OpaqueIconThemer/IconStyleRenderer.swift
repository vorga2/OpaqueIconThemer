import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum IconRenderMode: String, CaseIterable, Identifiable {
    case auto
    case smartLogo
    case tint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .smartLogo: return "Логотип"
        case .tint: return "Тинт"
        }
    }
}

struct IconRenderOptions {
    var mode: IconRenderMode = .auto
    var tintIntensity: CGFloat = 0.88
    var gradientStart: CGFloat = 0.50
    var gradientStrength: CGFloat = 0.16
}

final class IconStyleRenderer {
    static let shared = IconStyleRenderer()

    private let ciContext = CIContext(options: [.cacheIntermediates: true])

    private init() {}

    func render(source: UIImage, tint: UIColor, options: IconRenderOptions) -> UIImage? {
        guard let normalized = normalizedIcon(source) else { return nil }

        switch resolvedMode(source: normalized, requested: options.mode) {
        case .smartLogo:
            if let result = renderSmartLogo(
                source: normalized,
                tint: tint,
                gradientStart: options.gradientStart,
                gradientStrength: options.gradientStrength
            ) {
                return result
            }
            return renderTint(source: normalized, tint: tint, intensity: options.tintIntensity)

        case .tint:
            return renderTint(source: normalized, tint: tint, intensity: options.tintIntensity)

        case .auto:
            return renderTint(source: normalized, tint: tint, intensity: options.tintIntensity)
        }
    }

    func resolvedMode(source: UIImage, requested: IconRenderMode) -> IconRenderMode {
        if requested == .smartLogo { return .smartLogo }
        if requested == .tint { return .tint }
        guard let normalized = normalizedIcon(source) else { return .tint }
        return looksLikeSimpleLogo(normalized) ? .smartLogo : .tint
    }

    // MARK: - Analysis

    private struct RGB {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat

        func distance(to other: RGB) -> CGFloat {
            let dr = r - other.r
            let dg = g - other.g
            let db = b - other.b
            return sqrt((dr * dr + dg * dg + db * db) / 3.0)
        }
    }

    private func looksLikeSimpleLogo(_ image: UIImage) -> Bool {
        let width = 96
        let height = 96
        guard let pixels = rgbaPixels(from: image, width: width, height: height) else { return false }

        var luminance = [CGFloat](repeating: 0, count: width * height)
        var histogram = [Int](repeating: 0, count: 16)
        var colorBins = [Int](repeating: 0, count: 64)
        var borderColors: [RGB] = []
        var opaqueCount = 0
        let border = 6

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let p = index * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.08 else { continue }

                let rgb = unpremultipliedRGB(pixels: pixels, pixelOffset: p, alpha: alpha)
                opaqueCount += 1

                let lum = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
                luminance[index] = lum
                histogram[min(15, Int(lum * 15.999))] += 1

                let qr = min(3, Int(rgb.r * 3.999))
                let qg = min(3, Int(rgb.g * 3.999))
                let qb = min(3, Int(rgb.b * 3.999))
                colorBins[(qr << 4) | (qg << 2) | qb] += 1

                if x < border || x >= width - border || y < border || y >= height - border {
                    borderColors.append(rgb)
                }
            }
        }

        guard opaqueCount > width * height / 4, !borderColors.isEmpty else { return false }

        var edgeCount = 0
        var edgeSamples = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let dx = abs(luminance[i + 1] - luminance[i - 1])
                let dy = abs(luminance[i + width] - luminance[i - width])
                if dx + dy > 0.19 { edgeCount += 1 }
                edgeSamples += 1
            }
        }

        let edgeDensity = edgeSamples > 0 ? CGFloat(edgeCount) / CGFloat(edgeSamples) : 1

        var entropy: CGFloat = 0
        for count in histogram where count > 0 {
            let probability = CGFloat(count) / CGFloat(opaqueCount)
            entropy -= probability * log2(probability)
        }

        let minimumBinPopulation = max(2, opaqueCount / 250)
        let occupiedColorBins = colorBins.filter { $0 >= minimumBinPopulation }.count
        let backgroundMean = meanColor(borderColors)
        let backgroundVariation = borderColors.reduce(CGFloat.zero) {
            $0 + $1.distance(to: backgroundMean)
        } / CGFloat(borderColors.count)

        let edgeScore = normalizedScore(edgeDensity, low: 0.045, high: 0.23)
        let colorScore = normalizedScore(CGFloat(occupiedColorBins), low: 7, high: 32)
        let entropyScore = normalizedScore(entropy, low: 2.1, high: 3.75)
        let backgroundScore = normalizedScore(backgroundVariation, low: 0.035, high: 0.19)

        let complexity =
            edgeScore * 0.40 +
            colorScore * 0.29 +
            entropyScore * 0.22 +
            backgroundScore * 0.09

        guard complexity < 0.50,
              edgeDensity < 0.225,
              occupiedColorBins <= 32,
              entropy < 3.75,
              backgroundVariation < 0.22 else {
            return false
        }

        return logoSegmentation(from: image, width: 160, height: 160) != nil
    }

    // MARK: - Smart logo segmentation

    private struct LogoSegmentation {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let allowedMask: [Bool]
        let softAlpha: [CGFloat]
        let corners: [RGB]
    }

    private func logoSegmentation(from image: UIImage, width: Int, height: Int) -> LogoSegmentation? {
        guard let pixels = rgbaPixels(from: image, width: width, height: height) else { return nil }

        let references = borderReferences(pixels: pixels, width: width, height: height)
        guard !references.isEmpty else { return nil }

        let sampledBorder = sampledBorderColors(pixels: pixels, width: width, height: height)
        let borderForStats = sampledBorder.isEmpty ? references : sampledBorder
        let backgroundMean = meanColor(borderForStats)
        let backgroundVariation = borderForStats.reduce(CGFloat.zero) {
            $0 + $1.distance(to: backgroundMean)
        } / CGFloat(max(1, borderForStats.count))

        let threshold = min(0.28, max(0.075, 0.095 + backgroundVariation * 0.72))
        var hardMask = [Bool](repeating: false, count: width * height)
        var rawSoftAlpha = [CGFloat](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let sourceAlpha = CGFloat(pixels[p + 3]) / 255.0
                guard sourceAlpha > 0.015 else { continue }

                let rgb = unpremultipliedRGB(pixels: pixels, pixelOffset: p, alpha: sourceAlpha)
                let distance = references.map { rgb.distance(to: $0) }.min() ?? 1

                // Hard mask is used only to understand the shape. The actual rendering uses
                // the soft mask below, so translucent strokes and antialiased edges survive.
                hardMask[i] = distance > threshold * 0.82

                let inferredOpacity = smoothstep(
                    edge0: threshold * 0.28,
                    edge1: max(threshold * 1.90, threshold + 0.08),
                    value: distance
                )
                rawSoftAlpha[i] = inferredOpacity * sourceAlpha
            }
        }

        hardMask = majorityFilter(hardMask, width: width, height: height)
        hardMask = keepMeaningfulComponents(
            hardMask,
            width: width,
            height: height,
            minimumSize: max(6, Int(CGFloat(width * height) * 0.00006))
        )

        // Let the soft mask extend a couple of pixels beyond the hard shape. This keeps
        // transparent outlines, shadows and antialiasing instead of cutting them off.
        let allowedMask = dilateMask(hardMask, width: width, height: height, radius: 2)
        let foreground = hardMask.reduce(0) { $0 + ($1 ? 1 : 0) }
        let coverage = CGFloat(foreground) / CGFloat(width * height)
        guard coverage >= 0.015, coverage <= 0.72 else { return nil }

        var softAlpha = rawSoftAlpha
        for i in 0..<softAlpha.count where !allowedMask[i] {
            softAlpha[i] = 0
        }

        let corners = cornerBackgrounds(
            pixels: pixels,
            width: width,
            height: height,
            fallback: backgroundMean
        )

        return LogoSegmentation(
            pixels: pixels,
            width: width,
            height: height,
            allowedMask: allowedMask,
            softAlpha: softAlpha,
            corners: corners
        )
    }

    private func borderReferences(pixels: [UInt8], width: Int, height: Int) -> [RGB] {
        let patch = max(4, min(width, height) / 12)
        let centers = [
            (patch / 2, patch / 2),
            (width - 1 - patch / 2, patch / 2),
            (patch / 2, height - 1 - patch / 2),
            (width - 1 - patch / 2, height - 1 - patch / 2),
            (width / 2, patch / 2),
            (width / 2, height - 1 - patch / 2),
            (patch / 2, height / 2),
            (width - 1 - patch / 2, height / 2)
        ]

        return centers.compactMap { cx, cy in
            patchMean(pixels: pixels, width: width, height: height, cx: cx, cy: cy, radius: patch / 2)
        }
    }

    private func cornerBackgrounds(
        pixels: [UInt8],
        width: Int,
        height: Int,
        fallback: RGB
    ) -> [RGB] {
        let radius = max(3, min(width, height) / 24)
        return [
            patchMean(pixels: pixels, width: width, height: height, cx: radius, cy: radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, cx: width - 1 - radius, cy: radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, cx: radius, cy: height - 1 - radius, radius: radius) ?? fallback,
            patchMean(pixels: pixels, width: width, height: height, cx: width - 1 - radius, cy: height - 1 - radius, radius: radius) ?? fallback
        ]
    }

    private func sampledBorderColors(pixels: [UInt8], width: Int, height: Int) -> [RGB] {
        var output: [RGB] = []
        let border = max(3, min(width, height) / 24)
        let step = 3

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard x < border || x >= width - border || y < border || y >= height - border else { continue }
                let p = (y * width + x) * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.08 else { continue }
                output.append(unpremultipliedRGB(pixels: pixels, pixelOffset: p, alpha: alpha))
            }
        }
        return output
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

        let minX = max(0, cx - radius)
        let maxX = min(width - 1, cx + radius)
        let minY = max(0, cy - radius)
        let maxY = min(height - 1, cy + radius)

        for y in minY...maxY {
            for x in minX...maxX {
                let p = (y * width + x) * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.08 else { continue }
                let rgb = unpremultipliedRGB(pixels: pixels, pixelOffset: p, alpha: alpha)
                r += rgb.r * alpha
                g += rgb.g * alpha
                b += rgb.b * alpha
                weight += alpha
            }
        }

        guard weight > 0 else { return nil }
        return RGB(r: r / weight, g: g / weight, b: b / weight)
    }

    private func majorityFilter(_ source: [Bool], width: Int, height: Int) -> [Bool] {
        var result = source
        guard width > 2, height > 2 else { return result }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var count = 0
                for oy in -1...1 {
                    for ox in -1...1 {
                        if source[(y + oy) * width + (x + ox)] { count += 1 }
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
        var output = [Bool](repeating: false, count: source.count)
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
                for index in component { output[index] = true }
            }
        }

        return output
    }

    private func dilateMask(_ source: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return source }
        var result = source

        for y in 0..<height {
            for x in 0..<width where source[y * width + x] {
                let minY = max(0, y - radius)
                let maxY = min(height - 1, y + radius)
                let minX = max(0, x - radius)
                let maxX = min(width - 1, x + radius)
                for ny in minY...maxY {
                    for nx in minX...maxX {
                        result[ny * width + nx] = true
                    }
                }
            }
        }
        return result
    }

    // MARK: - Rendering

    private func renderSmartLogo(
        source: UIImage,
        tint: UIColor,
        gradientStart: CGFloat,
        gradientStrength: CGFloat
    ) -> UIImage? {
        // 512px is enough for a clean Home Screen symbol while keeping live slider updates fast.
        let workSize = 512
        guard let segmentation = logoSegmentation(from: source, width: workSize, height: workSize) else {
            return nil
        }

        var output = segmentation.pixels
        let start = min(0.90, max(0.05, gradientStart))
        let strength = min(0.65, max(0, gradientStrength))
        let tintRGB = rgb(from: tint)

        for y in 0..<segmentation.height {
            let yNorm = CGFloat(y) / CGFloat(max(1, segmentation.height - 1))
            let gradientProgress: CGFloat
            if yNorm <= start {
                gradientProgress = 0
            } else {
                gradientProgress = (yNorm - start) / max(0.001, 1 - start)
            }

            let logoMix = min(1, max(0, gradientProgress * strength))
            let logoColor = RGB(
                r: 1 + (tintRGB.r - 1) * logoMix,
                g: 1 + (tintRGB.g - 1) * logoMix,
                b: 1 + (tintRGB.b - 1) * logoMix
            )

            for x in 0..<segmentation.width {
                let i = y * segmentation.width + x
                guard segmentation.allowedMask[i] else { continue }

                let opacity = min(1, max(0, segmentation.softAlpha[i]))
                guard opacity > 0.001 else { continue }

                let p = i * 4
                let originalAlpha = CGFloat(segmentation.pixels[p + 3]) / 255.0
                guard originalAlpha > 0 else { continue }

                // Reconstruct the local background from the icon corners, then place the new
                // white/gradient symbol on it using the inferred original opacity. This is the
                // important part: semi-transparent strokes stay semi-transparent instead of
                // becoming solid white blobs.
                let xNorm = CGFloat(x) / CGFloat(max(1, segmentation.width - 1))
                let background = bilinearBackground(segmentation.corners, x: xNorm, y: yNorm)
                let result = RGB(
                    r: background.r * (1 - opacity) + logoColor.r * opacity,
                    g: background.g * (1 - opacity) + logoColor.g * opacity,
                    b: background.b * (1 - opacity) + logoColor.b * opacity
                )

                output[p] = UInt8(clamping: Int(result.r * originalAlpha * 255.0 + 0.5))
                output[p + 1] = UInt8(clamping: Int(result.g * originalAlpha * 255.0 + 0.5))
                output[p + 2] = UInt8(clamping: Int(result.b * originalAlpha * 255.0 + 0.5))
                output[p + 3] = segmentation.pixels[p + 3]
            }
        }

        guard let workImage = imageFromRGBA(output, width: workSize, height: workSize) else { return nil }

        let finalSize = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1

        return UIGraphicsImageRenderer(size: finalSize, format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            workImage.draw(in: CGRect(origin: .zero, size: finalSize))
        }
    }

    private func renderTint(source: UIImage, tint: UIColor, intensity: CGFloat) -> UIImage? {
        guard let input = CIImage(image: source) else { return nil }

        let filter = CIFilter.colorMonochrome()
        filter.inputImage = input
        filter.color = CIColor(color: tint)
        filter.intensity = Float(min(1, max(0, intensity)))

        guard let output = filter.outputImage,
              let cgImage = ciContext.createCGImage(output, from: output.extent) else {
            return nil
        }

        let result = UIImage(cgImage: cgImage)
        let size = CGSize(width: 1024, height: 1024)
        let rect = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.setFillColor(tint.cgColor)
            ctx.cgContext.fill(rect)
            result.draw(in: rect)
        }
    }

    // MARK: - Image helpers

    private func normalizedIcon(_ source: UIImage) -> UIImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }

        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            let scale = max(size.width / source.size.width, size.height / source.size.height)
            let drawSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            let origin = CGPoint(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2
            )
            source.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

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

    private func unpremultipliedRGB(pixels: [UInt8], pixelOffset: Int, alpha: CGFloat) -> RGB {
        guard alpha > 0.0001 else { return RGB(r: 0, g: 0, b: 0) }
        return RGB(
            r: min(1, CGFloat(pixels[pixelOffset]) / 255.0 / alpha),
            g: min(1, CGFloat(pixels[pixelOffset + 1]) / 255.0 / alpha),
            b: min(1, CGFloat(pixels[pixelOffset + 2]) / 255.0 / alpha)
        )
    }

    private func meanColor(_ colors: [RGB]) -> RGB {
        guard !colors.isEmpty else { return RGB(r: 0.5, g: 0.5, b: 0.5) }
        let count = CGFloat(colors.count)
        let sums = colors.reduce((CGFloat.zero, CGFloat.zero, CGFloat.zero)) { partial, color in
            (partial.0 + color.r, partial.1 + color.g, partial.2 + color.b)
        }
        return RGB(r: sums.0 / count, g: sums.1 / count, b: sums.2 / count)
    }

    private func normalizedScore(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard high > low else { return 0 }
        return min(1, max(0, (value - low) / (high - low)))
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private func bilinearBackground(_ corners: [RGB], x: CGFloat, y: CGFloat) -> RGB {
        guard corners.count >= 4 else { return meanColor(corners) }
        let top = mix(corners[0], corners[1], amount: x)
        let bottom = mix(corners[2], corners[3], amount: x)
        return mix(top, bottom, amount: y)
    }

    private func mix(_ first: RGB, _ second: RGB, amount: CGFloat) -> RGB {
        let t = min(1, max(0, amount))
        return RGB(
            r: first.r + (second.r - first.r) * t,
            g: first.g + (second.g - first.g) * t,
            b: first.b + (second.b - first.b) * t
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
}
