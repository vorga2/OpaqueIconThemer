import Foundation
import UIKit

/// Whole-image color tint similar to classic photo-editor "Color Tint" / Color blend behavior.
///
/// Unlike the layer-aware Tint+ path, this intentionally does *no* foreground/background
/// segmentation. The selected hue/saturation is applied to every source pixel while the original
/// lightness is preserved, so whites stay white, blacks stay dark and all relief/details remain.
/// Intensity blends between the original and the fully colorized result. Output is always opaque.
final class GlobalColorTintProcessor {
    static let shared = GlobalColorTintProcessor()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    private struct HSL {
        var h: CGFloat
        var s: CGFloat
        var l: CGFloat
    }

    func apply(source: UIImage, tint: UIColor, intensity: CGFloat) -> UIImage? {
        let width = 512
        let height = 512
        guard let pixels = rgbaPixels(from: source, width: width, height: height) else { return nil }

        let amount = clamp(intensity, 0, 1)
        let tintHSL = hsl(from: rgb(from: tint))
        let fallback = rgb(from: tint)
        var output = [UInt8](repeating: 0, count: pixels.count)

        for i in 0..<(width * height) {
            let p = i * 4
            let alpha = CGFloat(pixels[p + 3]) / 255.0
            let original = alpha > 0.0001
                ? straightRGB(pixels: pixels, offset: p, alpha: alpha)
                : fallback

            let sourceHSL = hsl(from: original)

            // "Color" style tint: take hue+saturation from the selected color, but preserve the
            // source lightness. This is why a 100% tint still keeps white highlights, dark shadows,
            // bevels and semi-transparent-looking internal layers instead of becoming a flat tile.
            let colorized = rgb(from: HSL(h: tintHSL.h, s: tintHSL.s, l: sourceHSL.l))
            let blended = mix(original, colorized, amount: amount)

            // Home-screen shortcut artwork must remain opaque. For real alpha input, composite the
            // tinted pixel over a same-hue background whose lightness comes from the original.
            let base = rgb(from: HSL(h: tintHSL.h, s: tintHSL.s, l: sourceHSL.l * 0.88))
            let final = mix(base, blended, amount: alpha)

            output[p] = byte(final.r)
            output[p + 1] = byte(final.g)
            output[p + 2] = byte(final.b)
            output[p + 3] = 255
        }

        return finalImage(output, width: width, height: height)
    }

    private func hsl(from c: RGB) -> HSL {
        let maxC = max(c.r, max(c.g, c.b))
        let minC = min(c.r, min(c.g, c.b))
        let delta = maxC - minC
        let l = (maxC + minC) * 0.5

        guard delta > 0.000001 else {
            return HSL(h: 0, s: 0, l: l)
        }

        let s = delta / max(0.000001, 1 - abs(2 * l - 1))
        let h: CGFloat
        if maxC == c.r {
            h = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maxC == c.g {
            h = (((c.b - c.r) / delta) + 2) / 6
        } else {
            h = (((c.r - c.g) / delta) + 4) / 6
        }

        return HSL(h: h < 0 ? h + 1 : h, s: clamp(s, 0, 1), l: clamp(l, 0, 1))
    }

    private func rgb(from hsl: HSL) -> RGB {
        let h = hsl.h - floor(hsl.h)
        let s = clamp(hsl.s, 0, 1)
        let l = clamp(hsl.l, 0, 1)

        guard s > 0.000001 else { return RGB(r: l, g: l, b: l) }

        let c = (1 - abs(2 * l - 1)) * s
        let h6 = h * 6
        let x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c * 0.5

        let raw: RGB
        switch h6 {
        case 0..<1: raw = RGB(r: c, g: x, b: 0)
        case 1..<2: raw = RGB(r: x, g: c, b: 0)
        case 2..<3: raw = RGB(r: 0, g: c, b: x)
        case 3..<4: raw = RGB(r: 0, g: x, b: c)
        case 4..<5: raw = RGB(r: x, g: 0, b: c)
        default: raw = RGB(r: c, g: 0, b: x)
        }

        return RGB(r: raw.r + m, g: raw.g + m, b: raw.b + m)
    }

    private func rgb(from color: UIColor) -> RGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return RGB(r: 0, g: 0.655, b: 1)
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
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
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

        let image = UIImage(cgImage: cgImage)
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(clamp(value, 0, 1) * 255.0 + 0.5))
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }
}
