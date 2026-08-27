import Foundation
import UIKit

/// Applies independent foreground and background tint strengths in one linear-light pass.
///
/// Foreground membership is no longer based on a single border-color threshold. The shared
/// LayerAwareForegroundDetector keeps low-contrast, semi-transparent and nested icon material,
/// which prevents inner artwork such as the Settings center from collapsing into the background.
final class CombinedTintIntensityProcessor {
    static let shared = CombinedTintIntensityProcessor()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
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
        guard let renderedPixels = rgbaPixels(from: rendered, width: width, height: height),
              let foregroundMask = LayerAwareForegroundDetector.shared.foregroundMask(
                source: source,
                width: width,
                height: height
              ),
              foregroundMask.count == width * height else {
            return rendered
        }

        let bgTintLinear = srgbToLinear(rgb(from: backgroundTint))
        let iconTintLinear = srgbToLinear(rgb(from: iconTint))
        var output = renderedPixels

        for i in 0..<(width * height) {
            let p = i * 4
            let foregroundConfidence = clamp(foregroundMask[i], 0, 1)
            let backgroundConfidence = 1 - foregroundConfidence

            let bgWeight = backgroundConfidence * bgStrength
            let fgWeight = foregroundConfidence * fgStrength
            let combined = bgWeight + fgWeight
            let totalWeight = clamp(combined, 0, 1)

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

            // The target color is the weighted material mix. Nested / translucent foreground
            // remains partially assigned to iconTint instead of being mistaken for flat background.
            let backgroundShare = bgWeight / max(0.0001, combined)
            let targetLinear = mix(
                iconTintLinear,
                bgTintLinear,
                amount: backgroundShare
            )

            let resultLinear = mix(renderedLinear, targetLinear, amount: totalWeight)
            let result = linearToSRGB(resultLinear)

            output[p] = byte(result.r)
            output[p + 1] = byte(result.g)
            output[p + 2] = byte(result.b)
            output[p + 3] = 255
        }

        return finalImage(output, width: width, height: height)
    }

    // MARK: - Color math

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

    private func mix(_ a: RGB, _ b: RGB, amount: CGFloat) -> RGB {
        let t = clamp(amount, 0, 1)
        return RGB(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t
        )
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
