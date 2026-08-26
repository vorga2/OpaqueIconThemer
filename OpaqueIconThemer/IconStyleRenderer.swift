import Foundation
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

    private init() {}

    func render(source: UIImage, tint: UIColor, options: IconRenderOptions) -> UIImage? {
        guard let normalized = normalizedIcon(source) else { return nil }

        switch resolvedMode(source: normalized, requested: options.mode) {
        case .smartLogo:
            if let result = AppleLikeLogoRenderer.shared.render(
                source: normalized,
                tint: tint,
                gradientStart: options.gradientStart,
                gradientStrength: options.gradientStrength
            ) {
                return result
            }
            return renderLinearTint(source: normalized, tint: tint, intensity: options.tintIntensity)

        case .tint:
            return renderLinearTint(source: normalized, tint: tint, intensity: options.tintIntensity)

        case .auto:
            return renderLinearTint(source: normalized, tint: tint, intensity: options.tintIntensity)
        }
    }

    func resolvedMode(source: UIImage, requested: IconRenderMode) -> IconRenderMode {
        if requested == .smartLogo { return .smartLogo }
        if requested == .tint { return .tint }
        guard let normalized = normalizedIcon(source) else { return .tint }
        return looksLikeSimpleLogo(normalized) ? .smartLogo : .tint
    }

    // MARK: - Auto classification

    /// Auto is conservative: icons that look like artwork/game scenes stay in full-icon tint mode.
    /// Simple logo-like icons are sent to the layered renderer where the actual shape/material
    /// extraction is much more expensive and much more detailed.
    private func looksLikeSimpleLogo(_ image: UIImage) -> Bool {
        let width = 96
        let height = 96
        guard let pixels = rgbaPixels(from: image, width: width, height: height) else { return false }

        var luminance = [CGFloat](repeating: 0, count: width * height)
        var histogram = [Int](repeating: 0, count: 16)
        var colorBins = [Int](repeating: 0, count: 64)
        var opaque = 0
        var chromaSum: CGFloat = 0

        for i in 0..<(width * height) {
            let p = i * 4
            let alpha = CGFloat(pixels[p + 3]) / 255
            guard alpha > 0.05 else { continue }

            let r = min(1, CGFloat(pixels[p]) / 255 / alpha)
            let g = min(1, CGFloat(pixels[p + 1]) / 255 / alpha)
            let b = min(1, CGFloat(pixels[p + 2]) / 255 / alpha)
            let lr = srgbToLinear(r)
            let lg = srgbToLinear(g)
            let lb = srgbToLinear(b)
            let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
            luminance[i] = y
            histogram[min(15, max(0, Int(y * 15.999)))] += 1

            let qr = min(3, Int(r * 3.999))
            let qg = min(3, Int(g * 3.999))
            let qb = min(3, Int(b * 3.999))
            colorBins[(qr << 4) | (qg << 2) | qb] += 1

            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            chromaSum += maxC - minC
            opaque += 1
        }

        guard opaque > width * height / 3 else { return false }

        var edges = 0
        var edgeSamples = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let dx = abs(luminance[i + 1] - luminance[i - 1])
                let dy = abs(luminance[i + width] - luminance[i - width])
                if dx + dy > 0.16 { edges += 1 }
                edgeSamples += 1
            }
        }

        let edgeDensity = edgeSamples > 0 ? CGFloat(edges) / CGFloat(edgeSamples) : 1
        var entropy: CGFloat = 0
        for count in histogram where count > 0 {
            let p = CGFloat(count) / CGFloat(opaque)
            entropy -= p * log2(p)
        }

        let minimumPopulation = max(2, opaque / 260)
        let occupiedColors = colorBins.filter { $0 >= minimumPopulation }.count
        let meanChroma = chromaSum / CGFloat(max(1, opaque))

        let edgeScore = normalizedScore(edgeDensity, low: 0.045, high: 0.22)
        let colorScore = normalizedScore(CGFloat(occupiedColors), low: 8, high: 30)
        let entropyScore = normalizedScore(entropy, low: 2.0, high: 3.75)
        let chromaScore = normalizedScore(meanChroma, low: 0.10, high: 0.46)

        let complexity =
            edgeScore * 0.39 +
            colorScore * 0.28 +
            entropyScore * 0.23 +
            chromaScore * 0.10

        return complexity < 0.53 &&
            edgeDensity < 0.215 &&
            occupiedColors <= 31 &&
            entropy < 3.72
    }

    // MARK: - Full icon tint

    /// Linear-light duotone surrogate for artwork-heavy icons. This keeps luminance hierarchy much
    /// better than CIColorMonochrome/gamma-space multiplication and always writes an opaque output.
    private func renderLinearTint(source: UIImage, tint: UIColor, intensity: CGFloat) -> UIImage? {
        let workSize = 512
        guard let pixels = rgbaPixels(from: source, width: workSize, height: workSize) else { return nil }

        let tintRGB = rgb(from: tint)
        let amount = min(1, max(0, intensity))
        let tintLinear = toLinear(tintRGB)
        let whiteLinear = RGB(r: 1, g: 1, b: 1)

        // A one-color tonal ramp: selected color carries shadows/midtones, highlights remain bright.
        let shadow = RGB(
            r: tintLinear.r * (0.26 + 0.34 * amount),
            g: tintLinear.g * (0.26 + 0.34 * amount),
            b: tintLinear.b * (0.26 + 0.34 * amount)
        )
        let highlight = mix(tintLinear, whiteLinear, amount: 0.58 - 0.26 * amount)

        var output = [UInt8](repeating: 0, count: pixels.count)
        for i in 0..<(workSize * workSize) {
            let p = i * 4
            let alpha = CGFloat(pixels[p + 3]) / 255
            let original: RGB
            if alpha > 0.0001 {
                original = RGB(
                    r: min(1, CGFloat(pixels[p]) / 255 / alpha),
                    g: min(1, CGFloat(pixels[p + 1]) / 255 / alpha),
                    b: min(1, CGFloat(pixels[p + 2]) / 255 / alpha)
                )
            } else {
                original = tintRGB
            }

            let linear = toLinear(original)
            let y = min(1, max(0, 0.2126 * linear.r + 0.7152 * linear.g + 0.0722 * linear.b))
            let mapped = fromLinear(mix(shadow, highlight, amount: y))

            // If a source PNG actually contains transparency, flatten it onto a matching dark tint
            // canvas instead of leaking transparent pixels into a Home Screen shortcut image.
            let base = fromLinear(RGB(
                r: tintLinear.r * 0.18,
                g: tintLinear.g * 0.18,
                b: tintLinear.b * 0.18
            ))
            let final = mix(base, mapped, amount: alpha)

            output[p] = byte(final.r)
            output[p + 1] = byte(final.g)
            output[p + 2] = byte(final.b)
            output[p + 3] = 255
        }

        guard let workImage = imageFromOpaqueRGBA(output, width: workSize, height: workSize) else { return nil }
        let finalSize = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: finalSize, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            workImage.draw(in: CGRect(origin: .zero, size: finalSize))
        }
    }

    // MARK: - Image/color helpers

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    private func normalizedIcon(_ source: UIImage) -> UIImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .high
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

    private func toLinear(_ c: RGB) -> RGB {
        RGB(r: srgbToLinear(c.r), g: srgbToLinear(c.g), b: srgbToLinear(c.b))
    }

    private func fromLinear(_ c: RGB) -> RGB {
        RGB(r: linearToSRGB(c.r), g: linearToSRGB(c.g), b: linearToSRGB(c.b))
    }

    private func srgbToLinear(_ value: CGFloat) -> CGFloat {
        let v = min(1, max(0, value))
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private func linearToSRGB(_ value: CGFloat) -> CGFloat {
        let v = max(0, value)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private func mix(_ first: RGB, _ second: RGB, amount: CGFloat) -> RGB {
        let t = min(1, max(0, amount))
        return RGB(
            r: first.r + (second.r - first.r) * t,
            g: first.g + (second.g - first.g) * t,
            b: first.b + (second.b - first.b) * t
        )
    }

    private func normalizedScore(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard high > low else { return 0 }
        return min(1, max(0, (value - low) / (high - low)))
    }

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(min(1, max(0, value)) * 255 + 0.5))
    }
}