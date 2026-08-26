import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

final class IconTintEngine {
    static let shared = IconTintEngine()

    private let context = CIContext(options: [.cacheIntermediates: true])

    private init() {}

    /// Auto mode:
    /// - simple, logo-like icons -> keep the original background, replace the main logo with white
    ///   and add a very soft tint gradient only on the lower 50% of the logo;
    /// - detailed / colorful / game-like icons -> fall back to the regular full-icon tint.
    func render(source: UIImage, tint: UIColor, intensity: CGFloat) -> UIImage? {
        guard let normalized = normalizedIcon(source) else { return nil }
        let analysis = analyze(normalized)

        if analysis.shouldUseSmartLogo,
           let mask = buildSmartLogoMask(
                from: normalized,
                backgroundReferences: analysis.backgroundReferences,
                threshold: analysis.foregroundThreshold
           ) {
            return renderSmartLogo(
                source: normalized,
                mask: mask,
                tint: tint,
                intensity: intensity,
                fallbackBackground: analysis.backgroundColor
            )
        }

        return renderTint(source: normalized, tint: tint, intensity: intensity)
    }

    // MARK: - Auto recognition

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

        var color: UIColor {
            UIColor(red: r, green: g, blue: b, alpha: 1)
        }
    }

    private struct Analysis {
        let shouldUseSmartLogo: Bool
        let backgroundReferences: [RGB]
        let foregroundThreshold: CGFloat
        let backgroundColor: UIColor
    }

    private struct Component {
        let size: Int
        let centerX: CGFloat
        let centerY: CGFloat
    }

    private func analyze(_ image: UIImage) -> Analysis {
        let width = 96
        let height = 96

        guard let pixels = rgbaPixels(from: image, width: width, height: height) else {
            return Analysis(
                shouldUseSmartLogo: false,
                backgroundReferences: [RGB(r: 0.5, g: 0.5, b: 0.5)],
                foregroundThreshold: 0.16,
                backgroundColor: .darkGray
            )
        }

        let border = 6
        var borderColors: [RGB] = []
        var luminance = [CGFloat](repeating: 0, count: width * height)
        var luminanceHistogram = [Int](repeating: 0, count: 16)
        var colorBins = [Int](repeating: 0, count: 64)
        var opaqueCount = 0

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

                opaqueCount += 1
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luminance[index] = lum
                luminanceHistogram[min(15, Int(lum * 15.999))] += 1

                let qr = min(3, Int(r * 3.999))
                let qg = min(3, Int(g * 3.999))
                let qb = min(3, Int(b * 3.999))
                colorBins[(qr << 4) | (qg << 2) | qb] += 1

                if x < border || x >= width - border || y < border || y >= height - border {
                    borderColors.append(rgb)
                }
            }
        }

        guard opaqueCount > width * height / 5, !borderColors.isEmpty else {
            return Analysis(
                shouldUseSmartLogo: false,
                backgroundReferences: [RGB(r: 0.5, g: 0.5, b: 0.5)],
                foregroundThreshold: 0.16,
                backgroundColor: .darkGray
            )
        }

        let backgroundMean = meanColor(borderColors)
        let backgroundVariation = borderColors.reduce(CGFloat.zero) {
            $0 + $1.distance(to: backgroundMean)
        } / CGFloat(borderColors.count)

        let references = backgroundReferences(
            pixels: pixels,
            width: width,
            height: height,
            fallback: backgroundMean
        )

        // A little more tolerance for soft gradients/noisy borders. This avoids turning the
        // background itself into the detected logo.
        let foregroundThreshold = min(0.27, max(0.105, 0.115 + backgroundVariation * 0.72))
        var foregroundMask = [Bool](repeating: false, count: width * height)
        var foregroundCount = 0

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let p = index * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.16 else { continue }

                let rgb = RGB(
                    r: CGFloat(pixels[p]) / 255.0,
                    g: CGFloat(pixels[p + 1]) / 255.0,
                    b: CGFloat(pixels[p + 2]) / 255.0
                )

                let distance = references.map { rgb.distance(to: $0) }.min() ?? 1
                if distance > foregroundThreshold {
                    foregroundMask[index] = true
                    foregroundCount += 1
                }
            }
        }

        // Edge density is the most useful signal for games / artwork.
        var edgeCount = 0
        var edgeSamples = 0
        if width > 2 && height > 2 {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let index = y * width + x
                    let dx = abs(luminance[index + 1] - luminance[index - 1])
                    let dy = abs(luminance[index + width] - luminance[index - width])
                    if dx + dy > 0.19 { edgeCount += 1 }
                    edgeSamples += 1
                }
            }
        }
        let edgeDensity = edgeSamples > 0 ? CGFloat(edgeCount) / CGFloat(edgeSamples) : 1

        // Shannon entropy on luminance. Posters / characters / game artwork tends to be high.
        var entropy: CGFloat = 0
        for count in luminanceHistogram where count > 0 {
            let p = CGFloat(count) / CGFloat(opaqueCount)
            entropy -= p * log2(p)
        }

        // Ignore tiny quantization bins; anti-aliasing should not make a simple logo "complex".
        let minimumBinPopulation = max(2, opaqueCount / 250)
        let occupiedColorBins = colorBins.filter { $0 >= minimumBinPopulation }.count

        let components = connectedComponents(mask: foregroundMask, width: width, height: height)
            .sorted { $0.size > $1.size }

        let coverage = CGFloat(foregroundCount) / CGFloat(width * height)
        let largestRatio: CGFloat
        let centerScore: CGFloat
        if let largest = components.first, foregroundCount > 0 {
            largestRatio = CGFloat(largest.size) / CGFloat(foregroundCount)
            let dx = largest.centerX - 0.5
            let dy = largest.centerY - 0.5
            let normalizedDistance = min(1, sqrt(dx * dx + dy * dy) / 0.7071)
            centerScore = 1 - normalizedDistance
        } else {
            largestRatio = 0
            centerScore = 0
        }

        let meaningfulComponents = components.filter {
            $0.size >= max(8, Int(CGFloat(width * height) * 0.0025))
        }.count

        let edgeScore = normalizedScore(edgeDensity, low: 0.045, high: 0.235)
        let colorScore = normalizedScore(CGFloat(occupiedColorBins), low: 7, high: 34)
        let entropyScore = normalizedScore(entropy, low: 2.15, high: 3.75)
        let backgroundScore = normalizedScore(backgroundVariation, low: 0.035, high: 0.205)
        let componentScore = normalizedScore(CGFloat(meaningfulComponents), low: 1, high: 7)

        var complexity =
            edgeScore * 0.34 +
            colorScore * 0.27 +
            entropyScore * 0.20 +
            backgroundScore * 0.12 +
            componentScore * 0.07

        // A single centered foreground shape is a strong "logo" signal.
        let logoStructure = largestRatio * 0.68 + centerScore * 0.32
        complexity -= max(0, logoStructure - 0.56) * 0.28
        complexity = clamp(complexity)

        var confidence = 1 - complexity

        // Bad segmentation -> always prefer the safe tint fallback.
        if coverage < 0.035 || coverage > 0.68 { confidence -= 0.42 }
        if largestRatio < 0.38 { confidence -= 0.22 }
        if backgroundVariation > 0.24 { confidence -= 0.18 }
        confidence = clamp(confidence)

        let smart =
            confidence >= 0.56 &&
            edgeDensity < 0.235 &&
            occupiedColorBins <= 34 &&
            entropy < 3.82 &&
            coverage >= 0.035 && coverage <= 0.68 &&
            largestRatio >= 0.38

        return Analysis(
            shouldUseSmartLogo: smart,
            backgroundReferences: references,
            foregroundThreshold: foregroundThreshold,
            backgroundColor: backgroundMean.color
        )
    }

    // MARK: - Smart logo mask

    private func buildSmartLogoMask(
        from image: UIImage,
        backgroundReferences: [RGB],
        threshold: CGFloat
    ) -> UIImage? {
        let width = 256
        let height = 256
        guard let pixels = rgbaPixels(from: image, width: width, height: height) else { return nil }

        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let p = index * 4
                let alpha = CGFloat(pixels[p + 3]) / 255.0
                guard alpha > 0.16 else { continue }

                let rgb = RGB(
                    r: CGFloat(pixels[p]) / 255.0,
                    g: CGFloat(pixels[p + 1]) / 255.0,
                    b: CGFloat(pixels[p + 2]) / 255.0
                )
                let distance = backgroundReferences.map { rgb.distance(to: $0) }.min() ?? 1
                mask[index] = distance > threshold
            }
        }

        // Two gentle majority passes remove compression noise while preserving thin logo strokes.
        mask = majorityFilter(mask, width: width, height: height)
        mask = majorityFilter(mask, width: width, height: height)

        let components = connectedComponents(mask: mask, width: width, height: height)
        guard let largest = components.max(by: { $0.size < $1.size }) else { return nil }

        let totalForeground = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard totalForeground > 0 else { return nil }

        let largestRatio = CGFloat(largest.size) / CGFloat(totalForeground)
        guard largestRatio >= 0.34 else { return nil }

        // Keep all meaningful pieces. This preserves detached dots/marks in simple logos but drops noise.
        let minimumComponent = max(18, Int(CGFloat(width * height) * 0.0012))
        let cleaned = keepMeaningfulComponents(
            mask: mask,
            width: width,
            height: height,
            minimumSize: minimumComponent
        )

        let cleanedCount = cleaned.reduce(0) { $0 + ($1 ? 1 : 0) }
        let cleanedCoverage = CGFloat(cleanedCount) / CGFloat(width * height)
        guard cleanedCoverage >= 0.025, cleanedCoverage <= 0.72 else { return nil }

        return maskImage(from: cleaned, width: width, height: height)
    }

    private func majorityFilter(_ source: [Bool], width: Int, height: Int) -> [Bool] {
        var result = source
        guard width > 2, height > 2 else { return result }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var neighbors = 0
                for oy in -1...1 {
                    for ox in -1...1 {
                        if source[(y + oy) * width + (x + ox)] { neighbors += 1 }
                    }
                }

                let index = y * width + x
                if source[index] {
                    result[index] = neighbors >= 3
                } else {
                    result[index] = neighbors >= 6
                }
            }
        }
        return result
    }

    private func keepMeaningfulComponents(
        mask: [Bool],
        width: Int,
        height: Int,
        minimumSize: Int
    ) -> [Bool] {
        var visited = [Bool](repeating: false, count: mask.count)
        var output = [Bool](repeating: false, count: mask.count)
        let directions = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for start in 0..<mask.count where mask[start] && !visited[start] {
            var queue = [start]
            var head = 0
            var component: [Int] = []
            visited[start] = true

            while head < queue.count {
                let index = queue[head]
                head += 1
                component.append(index)

                let x = index % width
                let y = index / width
                for (dx, dy) in directions {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    guard mask[next], !visited[next] else { continue }
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

    private func connectedComponents(mask: [Bool], width: Int, height: Int) -> [Component] {
        var visited = [Bool](repeating: false, count: mask.count)
        var result: [Component] = []
        let directions = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for start in 0..<mask.count where mask[start] && !visited[start] {
            var queue = [start]
            var head = 0
            var count = 0
            var xSum: CGFloat = 0
            var ySum: CGFloat = 0
            visited[start] = true

            while head < queue.count {
                let index = queue[head]
                head += 1

                let x = index % width
                let y = index / width
                count += 1
                xSum += CGFloat(x)
                ySum += CGFloat(y)

                for (dx, dy) in directions {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    guard mask[next], !visited[next] else { continue }
                    visited[next] = true
                    queue.append(next)
                }
            }

            if count > 0 {
                result.append(Component(
                    size: count,
                    centerX: (xSum / CGFloat(count)) / CGFloat(max(1, width - 1)),
                    centerY: (ySum / CGFloat(count)) / CGFloat(max(1, height - 1))
                ))
            }
        }

        return result
    }

    // MARK: - Rendering

    private func renderSmartLogo(
        source: UIImage,
        mask: UIImage,
        tint: UIColor,
        intensity: CGFloat,
        fallbackBackground: UIColor
    ) -> UIImage? {
        let size = CGSize(width: 1024, height: 1024)
        let rect = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1

        let strength = clamp((intensity - 0.35) / 0.65)
        // Even at the maximum setting the logo should stay mostly white.
        let bottomTintAmount = 0.08 + strength * 0.14
        let bottomColor = mixedColor(.white, tint, amount: bottomTintAmount)

        let overlay = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let cg = rendererContext.cgContext
            let colors = [UIColor.white.cgColor, UIColor.white.cgColor, bottomColor.cgColor] as CFArray
            let locations: [CGFloat] = [0.0, 0.50, 1.0]
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

            cg.interpolationQuality = .high
            mask.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }

        let finalFormat = UIGraphicsImageRendererFormat()
        finalFormat.opaque = true
        finalFormat.scale = 1

        return UIGraphicsImageRenderer(size: size, format: finalFormat).image { rendererContext in
            rendererContext.cgContext.setFillColor(fallbackBackground.cgColor)
            rendererContext.cgContext.fill(rect)
            source.draw(in: rect)
            overlay.draw(in: rect)
        }
    }

    private func renderTint(source: UIImage, tint: UIColor, intensity: CGFloat) -> UIImage? {
        guard let input = CIImage(image: source) else { return nil }

        let filter = CIFilter.colorMonochrome()
        filter.inputImage = input
        filter.color = CIColor(color: tint)
        filter.intensity = Float(clamp(intensity))

        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }

        let result = UIImage(cgImage: cgImage)
        let size = CGSize(width: 1024, height: 1024)
        let rect = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            rendererContext.cgContext.setFillColor(tint.cgColor)
            rendererContext.cgContext.fill(rect)
            result.draw(in: rect)
        }
    }

    private func normalizedIcon(_ source: UIImage) -> UIImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }

        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            rendererContext.cgContext.interpolationQuality = .high

            let scale = max(size.width / source.size.width, size.height / source.size.height)
            let drawSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            let origin = CGPoint(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2
            )
            source.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    // MARK: - Pixel helpers

    private func rgbaPixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func maskImage(from mask: [Bool], width: Int, height: Int) -> UIImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<mask.count where mask[index] {
            let p = index * 4
            pixels[p] = 255
            pixels[p + 1] = 255
            pixels[p + 2] = 255
            pixels[p + 3] = 255
        }

        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let cgImage = ctx.makeImage() else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private func backgroundReferences(
        pixels: [UInt8],
        width: Int,
        height: Int,
        fallback: RGB
    ) -> [RGB] {
        let patch = max(2, min(width, height) / 16)
        let centers = [
            (patch, patch),
            (width - patch - 1, patch),
            (patch, height - patch - 1),
            (width - patch - 1, height - patch - 1)
        ]

        var references: [RGB] = []
        for (cx, cy) in centers {
            var colors: [RGB] = []
            for y in max(0, cy - patch)..<min(height, cy + patch + 1) {
                for x in max(0, cx - patch)..<min(width, cx + patch + 1) {
                    let p = (y * width + x) * 4
                    let alpha = CGFloat(pixels[p + 3]) / 255.0
                    guard alpha > 0.12 else { continue }
                    colors.append(RGB(
                        r: CGFloat(pixels[p]) / 255.0,
                        g: CGFloat(pixels[p + 1]) / 255.0,
                        b: CGFloat(pixels[p + 2]) / 255.0
                    ))
                }
            }

            guard !colors.isEmpty else { continue }
            let candidate = meanColor(colors)
            if !references.contains(where: { $0.distance(to: candidate) < 0.055 }) {
                references.append(candidate)
            }
        }

        if !references.contains(where: { $0.distance(to: fallback) < 0.055 }) {
            references.append(fallback)
        }

        return references.isEmpty ? [fallback] : Array(references.prefix(5))
    }

    private func meanColor(_ colors: [RGB]) -> RGB {
        guard !colors.isEmpty else { return RGB(r: 0.5, g: 0.5, b: 0.5) }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        for color in colors {
            r += color.r
            g += color.g
            b += color.b
        }
        let count = CGFloat(colors.count)
        return RGB(r: r / count, g: g / count, b: b / count)
    }

    private func mixedColor(_ first: UIColor, _ second: UIColor, amount: CGFloat) -> UIColor {
        let t = clamp(amount)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        first.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        second.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: a1 + (a2 - a1) * t
        )
    }

    private func normalizedScore(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard high > low else { return 0 }
        return clamp((value - low) / (high - low))
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}
