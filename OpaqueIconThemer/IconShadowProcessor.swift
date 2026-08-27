import Foundation
import UIKit

/// Static shadow/bevel post-process for generated opaque icons.
///
/// It intentionally keeps the final bitmap fully opaque. The defaults approximate the material
/// hierarchy used by iOS-style icon artwork: top highlight, lower/side inner shade, ambient edge
/// depth, contact/ambient logo shadows, a small logo bevel and a directional perimeter highlight.
/// Shadow color is black by default, but callers can supply any color. A small surface-color mix
/// keeps shadows material-looking instead of dirty neutral black.
final class IconShadowProcessor {
    static let shared = IconShadowProcessor()

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

    func apply(
        source: UIImage,
        rendered: UIImage,
        surfaceColor: UIColor,
        shadowColor: UIColor = .black,
        strength: CGFloat = 0.90,
        tintMix: CGFloat = 0.30,
        logoShadows: Bool = true
    ) -> UIImage? {
        let amount = clamp(strength, 0, 1.5)
        guard amount > 0.001 else { return rendered }

        let width = 512
        let height = 512
        guard let sourcePixels = rgbaPixels(from: source, width: width, height: height),
              let renderedPixels = rgbaPixels(from: rendered, width: width, height: height) else {
            return rendered
        }

        let surface = rgb(from: surfaceColor)
        let userShadow = rgb(from: shadowColor)
        let effectiveShadow = mix(userShadow, surface, amount: clamp(tintMix, 0, 1))
        let effectiveShadowLinear = srgbToLinear(effectiveShadow)
        let topLight = mix(RGB(r: 1, g: 1, b: 1), surface, amount: 0.18)
        let topLightLinear = srgbToLinear(topLight)
        let whiteLinear = RGB(r: 1, g: 1, b: 1)

        var logoMask = logoShadows
            ? inferredLogoMask(pixels: sourcePixels, width: width, height: height)
            : [CGFloat](repeating: 0, count: width * height)

        // If segmentation treats most of a complex/game icon as one foreground object, logo
        // shadows would look artificial. Keep the tile material shadows but disable logo beveling.
        if logoShadows {
            let count = logoMask.reduce(0) { $0 + ($1 > 0.45 ? 1 : 0) }
            let coverage = CGFloat(count) / CGFloat(max(1, width * height))
            if coverage < 0.008 || coverage > 0.68 {
                logoMask = [CGFloat](repeating: 0, count: width * height)
            }
        }

        let designScale = CGFloat(width) / 180.0
        let contactBlur = boxBlur(logoMask, width: width, height: height, radius: max(1, Int((4.0 * designScale).rounded())))
        let ambientBlur = boxBlur(logoMask, width: width, height: height, radius: max(1, Int((10.0 * designScale).rounded())))
        let innerBlur = boxBlur(logoMask, width: width, height: height, radius: max(1, Int((3.0 * designScale).rounded())))
        let lightInnerBlur = boxBlur(logoMask, width: width, height: height, radius: max(1, Int((2.0 * designScale).rounded())))

        let contactOffset = max(1, Int((2.0 * designScale).rounded()))
        let ambientOffset = max(1, Int((5.0 * designScale).rounded()))
        let darkInnerOffset = max(1, Int((1.0 * designScale).rounded()))
        let lightInnerOffset = max(1, Int((1.0 * designScale).rounded()))

        var output = renderedPixels

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            let dTop = CGFloat(y) / designScale
            let dBottom = CGFloat(height - 1 - y) / designScale

            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))
                let dLeft = CGFloat(x) / designScale
                let dRight = CGFloat(width - 1 - x) / designScale
                let minEdge = min(min(dTop, dBottom), min(dLeft, dRight))

                let renderedRGB = RGB(
                    r: CGFloat(renderedPixels[p]) / 255.0,
                    g: CGFloat(renderedPixels[p + 1]) / 255.0,
                    b: CGFloat(renderedPixels[p + 2]) / 255.0
                )
                var result = srgbToLinear(renderedRGB)

                // Background/tile material defaults, scaled from the ~180 px reference recipe.
                let bottomInner = 0.35 * amount * gaussianEdge(distance: dBottom, offset: 5, blur: 14)
                let topInner = 0.30 * amount * gaussianEdge(distance: dTop, offset: 2, blur: 7)
                let rightSide = 0.14 * amount * gaussianEdge(distance: dRight, offset: 2, blur: 8)
                let leftSide = 0.14 * 0.55 * amount * gaussianEdge(distance: dLeft, offset: 1, blur: 9)
                let ambientInner = 0.12 * amount * gaussianEdge(distance: minEdge, offset: 0, blur: 22)

                // True external shadows cannot live outside a fully opaque square PNG. Bake their
                // perceptual contribution into the inner edge instead, with a deliberately reduced
                // weight so the icon does not acquire a dirty frame.
                let contactEdge = 0.25 * 0.34 * amount * gaussianEdge(distance: dBottom, offset: 1, blur: 4)
                let ambientEdge = 0.15 * 0.30 * amount * gaussianEdge(distance: minEdge, offset: 0, blur: 18)

                let darkWeight = clamp(
                    bottomInner + rightSide + leftSide + ambientInner + contactEdge + ambientEdge,
                    0,
                    0.72
                )
                result = mix(result, effectiveShadowLinear, amount: darkWeight)

                // Top-left light source: soft upper inner highlight, not a hard white outline.
                let topDirection = 0.72 + 0.28 * (1 - xNorm)
                result = screen(result, topLightLinear, amount: clamp(topInner * topDirection, 0, 0.48))

                let logo = clamp(logoMask[i], 0, 1)
                if logo > 0.0001 || !logoMask.isEmpty {
                    // Contact shadow under the foreground object.
                    let contact = sample(
                        contactBlur,
                        width: width,
                        height: height,
                        x: x,
                        y: y - contactOffset
                    )
                    let ambient = sample(
                        ambientBlur,
                        width: width,
                        height: height,
                        x: x,
                        y: y - ambientOffset
                    )
                    let outside = 1 - logo
                    let logoDrop = outside * amount * (contact * 0.30 + ambient * 0.12)
                    if logoDrop > 0.0001 {
                        result = mix(result, effectiveShadowLinear, amount: clamp(logoDrop, 0, 0.48))
                    }

                    if logo > 0.0001 {
                        // Dark inner bevel on the lower/right-facing edge.
                        let insideBelow = sample(
                            innerBlur,
                            width: width,
                            height: height,
                            x: x + darkInnerOffset,
                            y: y + darkInnerOffset
                        )
                        let darkBevel = logo * (1 - insideBelow) * 0.18 * amount
                        if darkBevel > 0.0001 {
                            result = mix(result, effectiveShadowLinear, amount: clamp(darkBevel, 0, 0.26))
                        }

                        // White inner bevel on the upper/left-facing edge.
                        let insideAbove = sample(
                            lightInnerBlur,
                            width: width,
                            height: height,
                            x: x - lightInnerOffset,
                            y: y - lightInnerOffset
                        )
                        let lightBevel = logo * (1 - insideAbove) * 0.45 * amount
                        if lightBevel > 0.0001 {
                            result = screen(result, whiteLinear, amount: clamp(lightBevel, 0, 0.52))
                        }
                    }
                }

                // Directional 1 px-design perimeter highlight: strongest top-left, very subtle at
                // the bottom. This reads more naturally than a uniform stroke.
                let border = 1 - smoothstep(edge0: 0.35, edge1: 1.85, value: minEdge)
                if border > 0.0001 {
                    let direction = clamp(0.92 - 0.50 * yNorm - 0.20 * xNorm, 0.18, 1)
                    let strokeWeight = border * direction * 0.30 * amount
                    result = screen(result, topLightLinear, amount: clamp(strokeWeight, 0, 0.38))
                }

                let final = linearToSRGB(result)
                output[p] = byte(final.r)
                output[p + 1] = byte(final.g)
                output[p + 2] = byte(final.b)
                output[p + 3] = 255
            }
        }

        return finalImage(output, width: width, height: height)
    }

    // MARK: - Logo segmentation

    private func inferredLogoMask(pixels: [UInt8], width: Int, height: Int) -> [CGFloat] {
        let references = borderReferences(pixels: pixels, width: width, height: height)
        guard !references.isEmpty else {
            return [CGFloat](repeating: 0, count: width * height)
        }

        let referenceLabs = references.map(oklab)
        let meanBackground = mean(references)
        let meanLab = oklab(meanBackground)
        let variation = referenceLabs.reduce(CGFloat.zero) {
            $0 + $1.distance(to: meanLab)
        } / CGFloat(max(1, referenceLabs.count))
        let threshold = min(0.22, max(0.036, 0.050 + variation * 0.96))

        var mask = [CGFloat](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let p = i * 4
            let alpha = CGFloat(pixels[p + 3]) / 255.0
            guard alpha > 0.001 else { continue }
            let sourceRGB = straightRGB(pixels: pixels, offset: p, alpha: alpha)
            let lab = oklab(sourceRGB)

            var distance = CGFloat.greatestFiniteMagnitude
            for reference in referenceLabs {
                distance = min(distance, lab.distance(to: reference))
            }

            let confidence = smoothstep(
                edge0: threshold * 0.22,
                edge1: max(threshold * 1.80, threshold + 0.050),
                value: distance
            )
            mask[i] = confidence * alpha
        }

        // Two light box passes remove threshold chatter while preserving antialiased coverage.
        mask = boxBlur(mask, width: width, height: height, radius: 1)
        mask = boxBlur(mask, width: width, height: height, radius: 1)
        return mask
    }

    // MARK: - Fast mask blur

    private func boxBlur(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, input.count == width * height else { return input }
        var horizontal = [CGFloat](repeating: 0, count: input.count)
        var output = [CGFloat](repeating: 0, count: input.count)

        for y in 0..<height {
            let row = y * width
            var sum: CGFloat = 0
            var count = 0
            for x in -radius...radius {
                if x >= 0 && x < width {
                    sum += input[row + x]
                    count += 1
                }
            }
            for x in 0..<width {
                horizontal[row + x] = sum / CGFloat(max(1, count))
                let removeX = x - radius
                let addX = x + radius + 1
                if removeX >= 0 {
                    sum -= input[row + removeX]
                    count -= 1
                }
                if addX < width {
                    sum += input[row + addX]
                    count += 1
                }
            }
        }

        for x in 0..<width {
            var sum: CGFloat = 0
            var count = 0
            for y in -radius...radius {
                if y >= 0 && y < height {
                    sum += horizontal[y * width + x]
                    count += 1
                }
            }
            for y in 0..<height {
                output[y * width + x] = sum / CGFloat(max(1, count))
                let removeY = y - radius
                let addY = y + radius + 1
                if removeY >= 0 {
                    sum -= horizontal[removeY * width + x]
                    count -= 1
                }
                if addY < height {
                    sum += horizontal[addY * width + x]
                    count += 1
                }
            }
        }
        return output
    }

    private func sample(
        _ values: [CGFloat],
        width: Int,
        height: Int,
        x: Int,
        y: Int
    ) -> CGFloat {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return values[y * width + x]
    }

    // MARK: - Background sampling

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

    // MARK: - Color math

    private func gaussianEdge(distance: CGFloat, offset: CGFloat, blur: CGFloat) -> CGFloat {
        let d = max(0, distance - offset)
        let sigma = max(0.001, blur * 0.52)
        return exp(-(d * d) / (2 * sigma * sigma))
    }

    private func oklab(_ rgb: RGB) -> Lab {
        let linear = srgbToLinear(rgb)
        let l = 0.4122214708 * linear.r + 0.5363325363 * linear.g + 0.0514459929 * linear.b
        let m = 0.2119034982 * linear.r + 0.6806995451 * linear.g + 0.1073969566 * linear.b
        let s = 0.0883024619 * linear.r + 0.2817188376 * linear.g + 0.6299787005 * linear.b

        let lRoot = cbrt(max(0, l))
        let mRoot = cbrt(max(0, m))
        let sRoot = cbrt(max(0, s))

        return Lab(
            l: 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
            a: 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
            b: 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
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

    private func linearToSRGB(_ rgb: RGB) -> RGB {
        RGB(r: linearToSRGB(rgb.r), g: linearToSRGB(rgb.g), b: linearToSRGB(rgb.b))
    }

    private func linearToSRGB(_ value: CGFloat) -> CGFloat {
        let v = max(0, value)
        if v <= 0.0031308 { return 12.92 * v }
        return 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    private func screen(_ base: RGB, _ light: RGB, amount: CGFloat) -> RGB {
        let a = clamp(amount, 0, 1)
        let screened = RGB(
            r: 1 - (1 - base.r) * (1 - light.r),
            g: 1 - (1 - base.g) * (1 - light.g),
            b: 1 - (1 - base.b) * (1 - light.b)
        )
        return mix(base, screened, amount: a)
    }

    private func rgb(from color: UIColor) -> RGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return RGB(r: 0, g: 0, b: 0)
        }
        return RGB(r: r, g: g, b: b)
    }

    private func mean(_ values: [RGB]) -> RGB {
        guard !values.isEmpty else { return RGB(r: 0.12, g: 0.12, b: 0.13) }
        let n = CGFloat(values.count)
        let sums = values.reduce((CGFloat.zero, CGFloat.zero, CGFloat.zero)) {
            ($0.0 + $1.r, $0.1 + $1.g, $0.2 + $1.b)
        }
        return RGB(r: sums.0 / n, g: sums.1 / n, b: sums.2 / n)
    }

    private func mix(_ a: RGB, _ b: RGB, amount: CGFloat) -> RGB {
        let t = clamp(amount, 0, 1)
        return RGB(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t
        )
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }

    // MARK: - Image helpers

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

    private func straightRGB(pixels: [UInt8], offset: Int, alpha: CGFloat) -> RGB {
        guard alpha > 0.0001 else { return RGB(r: 0, g: 0, b: 0) }
        return RGB(
            r: clamp(CGFloat(pixels[offset]) / 255.0 / alpha, 0, 1),
            g: clamp(CGFloat(pixels[offset + 1]) / 255.0 / alpha, 0, 1),
            b: clamp(CGFloat(pixels[offset + 2]) / 255.0 / alpha, 0, 1)
        )
    }

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

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(clamp(value, 0, 1) * 255.0 + 0.5))
    }
}
