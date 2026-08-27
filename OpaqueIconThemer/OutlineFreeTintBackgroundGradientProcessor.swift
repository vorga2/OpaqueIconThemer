import Foundation
import UIKit

/// Background-only gradient compositor for Tint modes.
///
/// The foreground geometry is binary and inset exactly like the no-rim Tint+ renderer. The
/// gradient is written only outside that silhouette, so changing colours/direction can never
/// manufacture a white/blue contour around the icon material.
final class OutlineFreeTintBackgroundGradientProcessor {
    static let shared = OutlineFreeTintBackgroundGradientProcessor()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    func apply(
        source: UIImage,
        rendered: UIImage,
        colors: [UIColor],
        directionRaw: String,
        backgroundIntensity: CGFloat
    ) -> UIImage? {
        let width = 1024
        let height = 1024
        let count = width * height
        guard colors.count >= 2,
              let sourcePixels = rgbaPixels(from: source, width: width, height: height),
              let renderedPixels = rgbaPixels(from: rendered, width: width, height: height),
              let softMask = LayerAwareForegroundDetector.shared.foregroundMask(
                source: source,
                width: width,
                height: height
              ),
              softMask.count == count else {
            return rendered
        }

        let locked = TintForegroundGeometry.shared.lockedCoverage(
            softMask: softMask,
            width: width,
            height: height
        )
        guard locked.count == count else { return rendered }

        var detected = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            detected[i] = locked[i] >= 0.75 ? 1 : 0
        }
        var silhouette = erodeBinaryMask(detected, width: width, height: height, radius: 2)
        if !silhouette.contains(where: { $0 > 0.5 }) {
            silhouette = detected
        }

        let palette = colors.prefix(4).map { srgbToLinear(rgb(from: $0)) }
        guard palette.count >= 2 else { return rendered }
        let corners = backgroundCorners(pixels: sourcePixels, width: width, height: height)
        let strength = clamp(backgroundIntensity, 0, 1)

        var output = renderedPixels
        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            for x in 0..<width {
                let i = y * width + x
                guard silhouette[i] <= 0.5 else {
                    output[i * 4 + 3] = 255
                    continue
                }

                let p = i * 4
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))
                let originalBackground = srgbToLinear(bilinear(corners, x: xNorm, y: yNorm))
                let t = gradientPosition(x: xNorm, y: yNorm, directionRaw: directionRaw)
                let target = gradientColor(palette, position: t)
                let material = mix(originalBackground, target, amount: strength)
                write(linearToSRGB(material), to: &output, offset: p)
            }
        }

        return imageFromRGBA(output, width: width, height: height)
    }

    private func gradientPosition(x: CGFloat, y: CGFloat, directionRaw: String) -> CGFloat {
        switch directionRaw {
        case "bottomToTop": return 1 - y
        case "rightToLeft": return 1 - x
        default: return y // topToBottom
        }
    }

    private func gradientColor(_ colors: [RGB], position: CGFloat) -> RGB {
        guard colors.count > 1 else { return colors.first ?? RGB(r: 0, g: 0.478, b: 1) }
        let t = clamp(position, 0, 1)
        let scaled = t * CGFloat(colors.count - 1)
        let lower = min(colors.count - 1, Int(floor(scaled)))
        let upper = min(colors.count - 1, lower + 1)
        return mix(colors[lower], colors[upper], amount: scaled - CGFloat(lower))
    }

    private func backgroundCorners(pixels: [UInt8], width: Int, height: Int) -> (RGB, RGB, RGB, RGB) {
        let radius = max(8, min(width, height) / 28)
        let tl = patchMean(pixels: pixels, width: width, height: height, cx: radius, cy: radius, radius: radius)
        let tr = patchMean(pixels: pixels, width: width, height: height, cx: width - 1 - radius, cy: radius, radius: radius)
        let bl = patchMean(pixels: pixels, width: width, height: height, cx: radius, cy: height - 1 - radius, radius: radius)
        let br = patchMean(pixels: pixels, width: width, height: height, cx: width - 1 - radius, cy: height - 1 - radius, radius: radius)
        let fallback = tl ?? tr ?? bl ?? br ?? RGB(r: 0.5, g: 0.5, b: 0.5)
        return (tl ?? fallback, tr ?? fallback, bl ?? fallback, br ?? fallback)
    }

    private func patchMean(pixels: [UInt8], width: Int, height: Int, cx: Int, cy: Int, radius: Int) -> RGB? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var n: CGFloat = 0
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                let p = (y * width + x) * 4
                r += CGFloat(pixels[p]) / 255.0
                g += CGFloat(pixels[p + 1]) / 255.0
                b += CGFloat(pixels[p + 2]) / 255.0
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return RGB(r: r / n, g: g / n, b: b / n)
    }

    private func bilinear(_ c: (RGB, RGB, RGB, RGB), x: CGFloat, y: CGFloat) -> RGB {
        let top = mix(c.0, c.1, amount: clamp(x, 0, 1))
        let bottom = mix(c.2, c.3, amount: clamp(x, 0, 1))
        return mix(top, bottom, amount: clamp(y, 0, 1))
    }

    private func erodeBinaryMask(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, input.count == width * height else { return input }
        let averaged = boxBlur(input, width: width, height: height, radius: radius)
        return averaged.map { $0 >= 0.999 ? 1 : 0 }
    }

    private func boxBlur(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, input.count == width * height else { return input }
        var horizontal = [CGFloat](repeating: 0, count: input.count)
        var output = [CGFloat](repeating: 0, count: input.count)

        for y in 0..<height {
            let row = y * width
            var sum: CGFloat = 0
            var samples = 0
            for x in 0...min(width - 1, radius) {
                sum += input[row + x]
                samples += 1
            }
            for x in 0..<width {
                horizontal[row + x] = sum / CGFloat(max(1, samples))
                let remove = x - radius
                let add = x + radius + 1
                if remove >= 0 { sum -= input[row + remove]; samples -= 1 }
                if add < width { sum += input[row + add]; samples += 1 }
            }
        }

        for x in 0..<width {
            var sum: CGFloat = 0
            var samples = 0
            for y in 0...min(height - 1, radius) {
                sum += horizontal[y * width + x]
                samples += 1
            }
            for y in 0..<height {
                output[y * width + x] = sum / CGFloat(max(1, samples))
                let remove = y - radius
                let add = y + radius + 1
                if remove >= 0 { sum -= horizontal[remove * width + x]; samples -= 1 }
                if add < height { sum += horizontal[add * width + x]; samples += 1 }
            }
        }
        return output
    }

    private func rgbaPixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: bitmap) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func imageFromRGBA(_ data: [UInt8], width: Int, height: Int) -> UIImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: bitmap), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func rgb(from color: UIColor) -> RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return RGB(r: 0, g: 0.478, b: 1) }
        return RGB(r: r, g: g, b: b)
    }

    private func srgbToLinear(_ c: RGB) -> RGB { RGB(r: srgbToLinear(c.r), g: srgbToLinear(c.g), b: srgbToLinear(c.b)) }
    private func srgbToLinear(_ v: CGFloat) -> CGFloat {
        let x = clamp(v, 0, 1)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    private func linearToSRGB(_ c: RGB) -> RGB { RGB(r: linearToSRGB(c.r), g: linearToSRGB(c.g), b: linearToSRGB(c.b)) }
    private func linearToSRGB(_ v: CGFloat) -> CGFloat {
        let x = max(0, v)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }
    private func mix(_ a: RGB, _ b: RGB, amount: CGFloat) -> RGB {
        let t = clamp(amount, 0, 1)
        return RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }
    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }
    private func write(_ c: RGB, to out: inout [UInt8], offset: Int) {
        out[offset] = byte(c.r); out[offset + 1] = byte(c.g); out[offset + 2] = byte(c.b); out[offset + 3] = 255
    }
    private func byte(_ v: CGFloat) -> UInt8 { UInt8(clamping: Int(clamp(v, 0, 1) * 255 + 0.5)) }
}
