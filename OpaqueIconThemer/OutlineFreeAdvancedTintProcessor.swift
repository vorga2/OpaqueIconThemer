import Foundation
import UIKit

/// Tint+ compositor that is deliberately incapable of drawing a third-colour rim.
///
/// Output is built from exactly two materials:
/// - background material;
/// - foreground/logo material.
///
/// The antialiased edge is only coverage between those two materials. Source edge pixels are
/// never sampled as foreground colour, so a white/pale background baked into the original icon
/// cannot survive as an outline. Tint strength and gradient never affect geometry.
final class OutlineFreeAdvancedTintProcessor {
    static let shared = OutlineFreeAdvancedTintProcessor()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    func apply(
        source: UIImage,
        backgroundTint: UIColor,
        iconTint: UIColor,
        backgroundIntensity: CGFloat,
        iconIntensity: CGFloat,
        gradientStart: CGFloat,
        gradientStrength: CGFloat
    ) -> UIImage? {
        // Work at final resolution. No later 512 -> 1024 interpolation pass is allowed to grow
        // the silhouette or create a coloured fringe.
        let width = 1024
        let height = 1024
        let count = width * height

        guard let pixels = rgbaPixels(from: source, width: width, height: height),
              let softMask = LayerAwareForegroundDetector.shared.foregroundMask(
                source: source,
                width: width,
                height: height
              ),
              softMask.count == count else {
            return nil
        }

        let locked = TintForegroundGeometry.shared.lockedCoverage(
            softMask: softMask,
            width: width,
            height: height
        )
        guard locked.count == count else { return nil }

        // Convert the permissive detector into one strict silhouette. The only soft area is a
        // one-pixel antialias transition reconstructed from this binary silhouette; weak detected
        // fringe outside the real logo is discarded completely.
        var hard = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            hard[i] = locked[i] >= 0.62 ? 1 : 0
        }
        let feathered = boxBlur(hard, width: width, height: height, radius: 1)
        var coverage = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            coverage[i] = smoothstep(edge0: 0.16, edge1: 0.84, value: feathered[i])
        }

        // Core pixels provide the logo's real source colour. Edge pixels NEVER provide colour:
        // their foreground colour is propagated from nearby confident core pixels instead.
        var coreWeight = [CGFloat](repeating: 0, count: count)
        var coreR = [CGFloat](repeating: 0, count: count)
        var coreG = [CGFloat](repeating: 0, count: count)
        var coreB = [CGFloat](repeating: 0, count: count)

        for i in 0..<count where hard[i] > 0.5 {
            let p = i * 4
            let c = srgbToLinear(RGB(
                r: CGFloat(pixels[p]) / 255.0,
                g: CGFloat(pixels[p + 1]) / 255.0,
                b: CGFloat(pixels[p + 2]) / 255.0
            ))
            coreWeight[i] = 1
            coreR[i] = c.r
            coreG[i] = c.g
            coreB[i] = c.b
        }

        // A small local colour field carries real interior material into the AA transition without
        // smearing distant artwork together.
        let radius = 7
        let localWeight = boxBlur(coreWeight, width: width, height: height, radius: radius)
        let localR = boxBlur(coreR, width: width, height: height, radius: radius)
        let localG = boxBlur(coreG, width: width, height: height, radius: radius)
        let localB = boxBlur(coreB, width: width, height: height, radius: radius)

        let corners = backgroundCorners(pixels: pixels, width: width, height: height)
        let bgTint = srgbToLinear(rgb(from: backgroundTint))
        let fgTint = srgbToLinear(rgb(from: iconTint))
        let bgStrength = clamp(backgroundIntensity, 0, 1)
        let fgStrength = clamp(iconIntensity, 0, 1)
        let gradStart = clamp(gradientStart, 0, 1)
        let gradStrength = clamp(gradientStrength, 0, 1)

        var out = [UInt8](repeating: 255, count: count * 4)

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            let gradientAmount: CGFloat
            if gradStrength <= 0.0001 || yNorm <= gradStart {
                gradientAmount = 0
            } else {
                let t = clamp((yNorm - gradStart) / max(0.001, 1 - gradStart), 0, 1)
                gradientAmount = smoothstep(edge0: 0, edge1: 1, value: t) * gradStrength
            }

            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let cov = coverage[i]
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))

                let originalBackground = srgbToLinear(bilinear(corners, x: xNorm, y: yNorm))
                let backgroundMaterial = mix(originalBackground, bgTint, amount: bgStrength)

                guard cov > 0.0001 else {
                    write(linearToSRGB(backgroundMaterial), to: &out, offset: p)
                    continue
                }

                let sourceCore = srgbToLinear(RGB(
                    r: CGFloat(pixels[p]) / 255.0,
                    g: CGFloat(pixels[p + 1]) / 255.0,
                    b: CGFloat(pixels[p + 2]) / 255.0
                ))

                let support = localWeight[i]
                let propagated: RGB
                if support > 0.001 {
                    propagated = clampRGB(RGB(
                        r: localR[i] / support,
                        g: localG[i] / support,
                        b: localB[i] / support
                    ))
                } else {
                    propagated = sourceCore
                }

                // Fully interior pixels may keep their source detail. The AA transition always uses
                // propagated interior colour, never the flattened source edge colour.
                let interior = smoothstep(edge0: 0.88, edge1: 1.0, value: cov)
                let cleanBase = mix(propagated, sourceCore, amount: interior)

                // "Сила тинта" changes material colour only.
                var foregroundMaterial = mix(cleanBase, fgTint, amount: fgStrength)

                // Advanced gradient is independent from tint strength and always uses background
                // tint colour, exactly as requested. It is still clipped to the same fixed logo
                // coverage so it cannot create an outline.
                if gradientAmount > 0.0001 {
                    foregroundMaterial = mix(foregroundMaterial, bgTint, amount: gradientAmount)
                }

                // This is the only edge operation: a two-material coverage mix. There is no third
                // white/blue/gray outline colour anywhere in the pipeline.
                let result = mix(backgroundMaterial, foregroundMaterial, amount: cov)
                write(linearToSRGB(result), to: &out, offset: p)
            }
        }

        return imageFromRGBA(out, width: width, height: height)
    }

    // MARK: - Background

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

    // MARK: - Filters

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

    // MARK: - Pixels / colour

    private func rgbaPixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: bitmap) else { return nil }
        ctx.interpolationQuality = .high
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
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
    private func mix(_ a: RGB, _ b: RGB, amount: CGFloat) -> RGB {
        let t = clamp(amount, 0, 1)
        return RGB(r: a.r + (b.r - a.r) * t,
                   g: a.g + (b.g - a.g) * t,
                   b: a.b + (b.b - a.b) * t)
    }
    private func clampRGB(_ c: RGB) -> RGB { RGB(r: clamp(c.r, 0, 1), g: clamp(c.g, 0, 1), b: clamp(c.b, 0, 1)) }
    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }
    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(high, max(low, value)) }
    private func write(_ c: RGB, to out: inout [UInt8], offset: Int) {
        out[offset] = byte(c.r); out[offset + 1] = byte(c.g); out[offset + 2] = byte(c.b); out[offset + 3] = 255
    }
    private func byte(_ v: CGFloat) -> UInt8 { UInt8(clamping: Int(clamp(v, 0, 1) * 255 + 0.5)) }
}
