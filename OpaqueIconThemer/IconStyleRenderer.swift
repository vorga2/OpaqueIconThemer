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

        let resolved = resolvedMode(source: normalized, requested: options.mode)
        switch resolved {
        case .tint:
            return renderTint(
                source: normalized,
                tint: tint,
                intensity: options.tintIntensity
            )

        case .smartLogo:
            if let mask = smartLogoMask(from: normalized) {
                return renderSmartLogo(
                    source: normalized,
                    mask: mask,
                    tint: tint,
                    gradientStart: options.gradientStart,
                    gradientStrength: options.gradientStrength
                )
            }

            return renderTint(
                source: normalized,
                tint: tint,
                intensity: options.tintIntensity
            )

        case .auto:
            // resolvedMode never returns .auto, but keep a safe fallback.
            return renderTint(
                source: normalized,
                tint: tint,
                intensity: options.tintIntensity
            )
        }
    }

    func resolvedMode(source: UIImage, requested: IconRenderMode) -> IconRenderMode {
        if requested == .smartLogo { return .smartLogo }
        if requested == .tint { return .tint }
        guard let normalized = normalizedIcon(source) else { return .tint }
        return looksLikeSimpleLogo(normalized) ? .smartLogo : .tint
    }

    // MARK: - Auto classification

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
        var opaque = 0
        let border = 6

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let p = index * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.12 else { continue }

                let r = CGFloat(pixels[p]) / 255.0
                let g = CGFloat(pixels[p + 1]) / 255.0
                let b = CGFloat(pixels[p + 2]) / 255.0
                let rgb = RGB(r: r, g: g, b: b)

                opaque += 1
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luminance[index] = lum
                histogram[min(15, Int(lum * 15.999))] += 1

                let qr = min(3, Int(r * 3.999))
                let qg = min(3, Int(g * 3.999))
                let qb = min(3, Int(b * 3.999))
                colorBins[(qr << 4) | (qg << 2) | qb] += 1

                if x < border || x >= width - border || y < border || y >= height - border {
                    borderColors.append(rgb)
                }
            }
        }

        guard opaque > width * height / 4, !borderColors.isEmpty else { return false }

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
            let probability = CGFloat(count) / CGFloat(opaque)
            entropy -= probability * log2(probability)
        }

        let minimumBinPopulation = max(2, opaque / 250)
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

        // Conservative by design: if Auto is unsure, Tint looks much better than a bad mask.
        guard complexity < 0.50,
              edgeDensity < 0.225,
              occupiedColorBins <= 32,
              entropy < 3.75,
              backgroundVariation < 0.22 else {
            return false
        }

        // Also require a usable foreground mask before calling it a logo.
        return smartLogoMask(from: image) != nil
    }

    // MARK: - Smart logo segmentation

    private func smartLogoMask(from image: UIImage) -> UIImage? {
        let width = 256
        let height = 256
        guard let pixels = rgbaPixels(from: image, width: width, height: height) else { return nil }

        let references = borderReferences(pixels: pixels, width: width, height: height)
        guard !references.isEmpty else { return nil }

        let borderPixels = sampledBorderColors(pixels: pixels, width: width, height: height)
        let backgroundMean = meanColor(borderPixels.isEmpty ? references : borderPixels)
        let backgroundVariation = (borderPixels.isEmpty ? references : borderPixels).reduce(CGFloat.zero) {
            $0 + $1.distance(to: backgroundMean)
        } / CGFloat(max(1, (borderPixels.isEmpty ? references : borderPixels).count))

        let threshold = min(0.27, max(0.09, 0.105 + backgroundVariation * 0.72))
        var mask = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.14 else { continue }

                let rgb = RGB(
                    r: CGFloat(pixels[p]) / 255.0,
                    g: CGFloat(pixels[p + 1]) / 255.0,
                    b: CGFloat(pixels[p + 2]) / 255.0
                )

                let distance = references.map { rgb.distance(to: $0) }.min() ?? 1
                mask[i] = distance > threshold
            }
        }

        mask = majorityFilter(mask, width: width, height: height)
        mask = keepMeaningfulComponents(
            mask,
            width: width,
            height: height,
            minimumSize: max(18, Int(CGFloat(width * height) * 0.0012))
        )

        let foreground = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        let coverage = CGFloat(foreground) / CGFloat(width * height)
        guard coverage >= 0.022, coverage <= 0.70 else { return nil }

        return maskImage(from: mask, width: width, height: height)
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

    private func sampledBorderColors(pixels: [UInt8], width: Int, height: Int) -> [RGB] {
        var output: [RGB] = []
        let border = max(3, min(width, height) / 24)
        let step = 3

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard x < border || x >= width - border || y < border || y >= height - border else { continue }
                let p = (y * width + x) * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.15 else { continue }
                output.append(RGB(
                    r: CGFloat(pixels[p]) / 255.0,
                    g: CGFloat(pixels[p + 1]) / 255.0,
                    b: CGFloat(pixels[p + 2]) / 255.0
                ))
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
        var count: CGFloat = 0

        let minX = max(0, cx - radius)
        let maxX = min(width - 1, cx + radius)
        let minY = max(0, cy - radius)
        let maxY = min(height - 1, cy + radius)

        for y in minY...maxY {
            for x in minX...maxX {
                let p = (y * width + x) * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.15 else { continue }
                r += CGFloat(pixels[p]) / 255.0
                g += CGFloat(pixels[p + 1]) / 255.0
                b += CGFloat(pixels[p + 2]) / 255.0
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return RGB(r: r / count, g: g / count, b: b / count)
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
                if source[i] {
                    result[i] = count >= 3
                } else {
                    result[i] = count >= 6
                }
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

    // MARK: - Rendering

    private func renderSmartLogo(
        source: UIImage,
        mask: UIImage,
        tint: UIColor,
        gradientStart: CGFloat,
        gradientStrength: CGFloat
    ) -> UIImage {
        let size = CGSize(width: 1024, height: 1024)
        let rect = CGRect(origin: .zero, size: size)
        let start = min(0.90, max(0.05, gradientStart))
        let strength = min(0.65, max(0, gradientStrength))
        let bottomColor = mixedColor(.white, tint, amount: strength)

        let transparentFormat = UIGraphicsImageRendererFormat()
        transparentFormat.opaque = false
        transparentFormat.scale = 1

        let logoOverlay = UIGraphicsImageRenderer(size: size, format: transparentFormat).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.white.cgColor, UIColor.white.cgColor, bottomColor.cgColor] as CFArray
            let locations: [CGFloat] = [0, start, 1]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: locations
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: size.width / 2, y: 0),
                    end: CGPoint(x: size.width / 2, y: size.height),
                    options: []
                )
            }
            mask.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }

        let finalFormat = UIGraphicsImageRendererFormat()
        finalFormat.opaque = true
        finalFormat.scale = 1

        return UIGraphicsImageRenderer(size: size, format: finalFormat).image { ctx in
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            ctx.cgContext.fill(rect)
            source.draw(in: rect)
            logoOverlay.draw(in: rect)
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

    private func maskImage(from mask: [Bool], width: Int, height: Int) -> UIImage? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<mask.count where mask[i] {
            let p = i * 4
            data[p] = 255
            data[p + 1] = 255
            data[p + 2] = 255
            data[p + 3] = 255
        }

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

    private func mixedColor(_ first: UIColor, _ second: UIColor, amount: CGFloat) -> UIColor {
        let amount = min(1, max(0, amount))
        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0
        first.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        second.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        return UIColor(
            red: r1 + (r2 - r1) * amount,
            green: g1 + (g2 - g1) * amount,
            blue: b1 + (b2 - b1) * amount,
            alpha: a1 + (a2 - a1) * amount
        )
    }
}
