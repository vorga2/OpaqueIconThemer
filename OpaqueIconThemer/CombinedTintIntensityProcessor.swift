import Foundation
import UIKit

/// Applies foreground tint strength and background tint strength in one linear-light pass.
/// At foreground=1 and background=1, using the same selected color for both zones produces
/// an exactly solid selected-color icon (while final alpha remains 1.0 everywhere).
final class CombinedTintIntensityProcessor {
    static let shared = CombinedTintIntensityProcessor()

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
        backgroundTint: UIColor,
        iconTint: UIColor,
        backgroundIntensity: CGFloat,
        iconIntensity: CGFloat
    ) -> UIImage? {
        let bgStrength = clamp(backgroundIntensity, 0, 1)
        let fgStrength = clamp(iconIntensity, 0, 1)
        guard bgStrength > 0.001 || fgStrength > 0.001 else { return rendered }

        let width = 512
        let height = 512
        guard let sourcePixels = rgbaPixels(from: source, width: width, height: height),
              let renderedPixels = rgbaPixels(from: rendered, width: width, height: height) else {
            return rendered
        }

        let references = borderReferences(pixels: sourcePixels, width: width, height: height)
        guard !references.isEmpty else { return rendered }

        let referenceLabs = references.map(oklab)
        let meanBackground = mean(references)
        let meanLab = oklab(meanBackground)
        let variation = referenceLabs.reduce(CGFloat.zero) {
            $0 + $1.distance(to: meanLab)
        } / CGFloat(max(1, referenceLabs.count))

        let threshold = min(0.24, max(0.040, 0.055 + variation * 1.05))
        let bgTintLinear = srgbToLinear(rgb(from: backgroundTint))
        let iconTintLinear = srgbToLinear(rgb(from: iconTint))

        var output = renderedPixels

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let sourceAlpha = CGFloat(sourcePixels[p + 3]) / 255.0

                let sourceRGB: RGB
                if sourceAlpha > 0.0001 {
                    sourceRGB = straightRGB(pixels: sourcePixels, offset: p, alpha: sourceAlpha)
                } else {
                    sourceRGB = meanBackground
                }

                let lab = oklab(sourceRGB)
                let distance = referenceLabs.map { lab.distance(to: $0) }.min() ?? 1

                let backgroundConfidence = 1 - smoothstep(
                    edge0: threshold * 0.38,
                    edge1: max(threshold * 1.85, threshold + 0.055),
                    value: distance
                )
                let foregroundConfidence = 1 - backgroundConfidence

                let bgWeight = backgroundConfidence * bgStrength
                let fgWeight = foregroundConfidence * fgStrength
                let totalWeight = clamp(bgWeight + fgWeight, 0, 1)

                guard totalWeight > 0.0001 else {
                    output[p + 3] = 255
                    continue
                }

                let renderedRGB = RGB(
                    r: CGFloat(renderedPixels[p]) / 255.0,
                    g: CGFloat(renderedPixels[p + 1]) / 255.0,
                    b: CGFloat(renderedPixels[p + 2]) / 255.0
                )
                let renderedLinear = srgbToLinear(renderedRGB)

                let normalizedBackgroundShare = bgWeight / max(0.0001, bgWeight + fgWeight)
                let targetLinear = mix(
                    iconTintLinear,
                    bgTintLinear,
                    amount: normalizedBackgroundShare
                )

                let resultLinear = mix(renderedLinear, targetLinear, amount: totalWeight)
                let result = linearToSRGB(resultLinear)

                output[p] = byte(result.r)
                output[p + 1] = byte(result.g)
                output[p + 2] = byte(result.b)
                output[p + 3] = 255
            }
        }

        return finalImage(output, width: width, height: height)
    }

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

    private func rgb(from color: UIColor) -> RGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return RGB(r: 0, g: 0.478, b: 1)
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
