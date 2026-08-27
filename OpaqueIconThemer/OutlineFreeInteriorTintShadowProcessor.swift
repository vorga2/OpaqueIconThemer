import Foundation
import UIKit

/// Visible Tint shadow/depth pass that is forbidden from touching the outer silhouette.
/// It works only on a safely eroded foreground interior, so the shadow controls can have a real
/// visual effect without bringing back the white/blue contour that the no-rim pipeline removed.
final class OutlineFreeInteriorTintShadowProcessor {
    static let shared = OutlineFreeInteriorTintShadowProcessor()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    func apply(
        source: UIImage,
        rendered: UIImage,
        shadowColor: UIColor,
        strength: CGFloat,
        tintMix: CGFloat,
        surfaceColor: UIColor
    ) -> UIImage? {
        let amount = clamp(strength, 0, 1.5)
        guard amount > 0.001 else { return rendered }

        let width = 1024
        let height = 1024
        let count = width * height
        guard let renderedPixels = rgbaPixels(from: rendered, width: width, height: height),
              let softMask = LayerAwareForegroundDetector.shared.foregroundMask(source: source, width: width, height: height),
              softMask.count == count else { return rendered }

        let locked = TintForegroundGeometry.shared.lockedCoverage(softMask: softMask, width: width, height: height)
        guard locked.count == count else { return rendered }

        var detected = [CGFloat](repeating: 0, count: count)
        for i in 0..<count { detected[i] = locked[i] >= 0.75 ? 1 : 0 }
        var silhouette = erodeBinaryMask(detected, width: width, height: height, radius: 2)
        if !silhouette.contains(where: { $0 > 0.5 }) { silhouette = detected }

        // Keep a wide untouched band around the silhouette. This is the no-outline guarantee.
        let deepInterior = erodeBinaryMask(silhouette, width: width, height: height, radius: 9)
        let support = boxBlur(deepInterior, width: width, height: height, radius: 12)

        let selectedShadow = mix(rgb(from: shadowColor), rgb(from: surfaceColor), amount: clamp(tintMix, 0, 1))
        let shadowLinear = srgbToLinear(selectedShadow)
        let white = RGB(r: 1, g: 1, b: 1)
        var output = renderedPixels

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            for x in 0..<width {
                let i = y * width + x
                let interior = clamp(support[i], 0, 1) * silhouette[i]
                guard interior > 0.001 else { continue }

                let p = i * 4
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))
                var material = srgbToLinear(RGB(
                    r: CGFloat(renderedPixels[p]) / 255.0,
                    g: CGFloat(renderedPixels[p + 1]) / 255.0,
                    b: CGFloat(renderedPixels[p + 2]) / 255.0
                ))

                // Strong enough to be visible at the default 90% control, but still broad/material
                // lighting rather than a contour stroke.
                let lowerRight = clamp((xNorm + yNorm - 0.58) / 1.42, 0, 1)
                let dark = interior * lowerRight * 0.34 * amount
                if dark > 0.0001 {
                    material = mix(material, shadowLinear, amount: clamp(dark, 0, 0.42))
                }

                let upperLeft = clamp((0.72 - (xNorm + yNorm) * 0.5) / 0.72, 0, 1)
                let light = interior * upperLeft * 0.10 * amount
                if light > 0.0001 {
                    material = screen(material, white, amount: clamp(light, 0, 0.16))
                }

                write(linearToSRGB(material), to: &output, offset: p)
            }
        }

        return imageFromRGBA(output, width: width, height: height)
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
            for x in 0...min(width - 1, radius) { sum += input[row + x]; samples += 1 }
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
            for y in 0...min(height - 1, radius) { sum += horizontal[y * width + x]; samples += 1 }
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
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return RGB(r: 0, g: 0, b: 0) }
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
    private func screen(_ base: RGB, _ light: RGB, amount: CGFloat) -> RGB {
        let t = clamp(amount, 0, 1)
        let screened = RGB(r: 1 - (1 - base.r) * (1 - light.r),
                           g: 1 - (1 - base.g) * (1 - light.g),
                           b: 1 - (1 - base.b) * (1 - light.b))
        return mix(base, screened, amount: t)
    }
    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }
    private func write(_ c: RGB, to out: inout [UInt8], offset: Int) {
        out[offset] = byte(c.r); out[offset + 1] = byte(c.g); out[offset + 2] = byte(c.b); out[offset + 3] = 255
    }
    private func byte(_ v: CGFloat) -> UInt8 { UInt8(clamping: Int(clamp(v, 0, 1) * 255 + 0.5)) }
}
