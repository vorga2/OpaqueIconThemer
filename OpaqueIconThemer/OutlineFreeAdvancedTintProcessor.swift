import Foundation
import UIKit

/// Final advanced Tint+ compositor.
///
/// The previous versions still produced a visible rim because they reconstructed a soft
/// antialiased coverage band around the detected silhouette. Even though that band only mixed two
/// colours, tint/gradient made it visible as a coloured outline and background intensity exposed
/// residual pale source pixels.
///
/// This version deliberately has NO generated soft exterior band at all:
/// - one fixed binary foreground silhouette is built at the final 1024px resolution;
/// - pixels outside that silhouette are always background, period;
/// - tint strength and gradient only change foreground MATERIAL colour;
/// - background intensity only changes background MATERIAL colour;
/// - source edge pixels never decide geometry;
/// - contaminated boundary colour is replaced from an eroded interior colour field;
/// - no 512 -> 1024 scaling pass and no silhouette shadow/bevel pass are involved.
///
/// SpringBoard / SwiftUI performs the final display downsampling of the 1024px bitmap, which gives
/// normal visual antialiasing without baking a white/blue third-colour rim into the icon itself.
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

        // IMPORTANT: geometry is binary and is never blurred/dilated afterwards. The old
        // boxBlur(hard, radius: 1) created non-zero pixels outside the real silhouette; that was the
        // persistent coloured outline seen when tint strength or gradient increased.
        var hard = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            hard[i] = locked[i] >= 0.66 ? 1 : 0
        }

        // Only deep interior pixels are allowed to provide the source material colour. The outer
        // 2–3 px of the detected logo can contain the original white/pale background baked by the
        // source icon's own antialiasing, so never use those pixels as boundary colour.
        var deepCore = erodeBinaryMask(hard, width: width, height: height, radius: 3)
        if !deepCore.contains(where: { $0 > 0.5 }) {
            // Very thin artwork can disappear under erosion. Keep it renderable, while geometry is
            // still strict and cannot grow because `hard` remains the only output silhouette.
            deepCore = hard
        }

        var coreWeight = [CGFloat](repeating: 0, count: count)
        var coreR = [CGFloat](repeating: 0, count: count)
        var coreG = [CGFloat](repeating: 0, count: count)
        var coreB = [CGFloat](repeating: 0, count: count)

        for i in 0..<count where deepCore[i] > 0.5 {
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

        // Propagate real interior colour to the strict boundary. This field is used ONLY for colour;
        // it can never affect shape/coverage.
        let colourRadius = 11
        let localWeight = boxBlur(coreWeight, width: width, height: height, radius: colourRadius)
        let localR = boxBlur(coreR, width: width, height: height, radius: colourRadius)
        let localG = boxBlur(coreG, width: width, height: height, radius: colourRadius)
        let localB = boxBlur(coreB, width: width, height: height, radius: colourRadius)

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
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))

                let originalBackground = srgbToLinear(bilinear(corners, x: xNorm, y: yNorm))
                let backgroundMaterial = mix(originalBackground, bgTint, amount: bgStrength)

                // Outside is background with ZERO foreground contribution. No feather, no halo,
                // no gradient/tint can ever make this pixel part of the logo.
                guard hard[i] > 0.5 else {
                    write(linearToSRGB(backgroundMaterial), to: &out, offset: p)
                    continue
                }

                let sourcePixel = srgbToLinear(RGB(
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
                    propagated = sourcePixel
                }

                // Deep interior keeps original local detail. Every boundary pixel uses propagated
                // interior colour instead of its possibly white-contaminated flattened source RGB.
                let cleanBase = deepCore[i] > 0.5 ? sourcePixel : propagated

                // "Сила тинта" changes only foreground material. It has no access to `hard`.
                var foregroundMaterial = mix(cleanBase, fgTint, amount: fgStrength)

                // Gradient changes only foreground material, is independent from tint strength, and
                // uses background tint colour as requested. It also has no access to geometry.
                if gradientAmount > 0.0001 {
                    foregroundMaterial = mix(foregroundMaterial, bgTint, amount: gradientAmount)
                }

                // Binary material selection is intentional. Display-time downsampling gives normal
                // AA; the stored icon itself contains no generated outline band.
                write(linearToSRGB(foregroundMaterial), to: &out, offset: p)
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

    // MARK: - Geometry / filters

    private func erodeBinaryMask(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, input.count == width * height else { return input }
        var out = [CGFloat](repeating: 0, count: input.count)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard input[i] > 0.5 else { continue }

                var survives = true
                let minY = max(0, y - radius)
                let maxY = min(height - 1, y + radius)
                let minX = max(0, x - radius)
                let maxX = min(width - 1, x + radius)

                outer: for yy in minY...maxY {
                    for xx in minX...maxX {
                        if input[yy * width + xx] <= 0.5 {
                            survives = false
                            break outer
                        }
                    }
                }
                out[i] = survives ? 1 : 0
            }
        }
        return out
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

    // MARK: - Pixels / colour

    private func rgbaPixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: bitmap) else { return nil }

        // Do not invent interpolated pale/blue source-edge pixels while preparing the working copy.
        // Geometry is generated separately by the detector; source RGB is only material data.
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
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return RGB(r: 0, g: 0.478, b: 1)
        }
        return RGB(r: r, g: g, b: b)
    }

    private func srgbToLinear(_ c: RGB) -> RGB {
        RGB(r: srgbToLinear(c.r), g: srgbToLinear(c.g), b: srgbToLinear(c.b))
    }

    private func srgbToLinear(_ v: CGFloat) -> CGFloat {
        let x = clamp(v, 0, 1)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private func linearToSRGB(_ c: RGB) -> RGB {
        RGB(r: linearToSRGB(c.r), g: linearToSRGB(c.g), b: linearToSRGB(c.b))
    }

    private func linearToSRGB(_ v: CGFloat) -> CGFloat {
        let x = max(0, v)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    private func mix(_ a: RGB, _ b: RGB, amount: CGFloat) -> RGB {
        let t = clamp(amount, 0, 1)
        return RGB(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t
        )
    }

    private func clampRGB(_ c: RGB) -> RGB {
        RGB(r: clamp(c.r, 0, 1), g: clamp(c.g, 0, 1), b: clamp(c.b, 0, 1))
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }

    private func write(_ c: RGB, to out: inout [UInt8], offset: Int) {
        out[offset] = byte(c.r)
        out[offset + 1] = byte(c.g)
        out[offset + 2] = byte(c.b)
        out[offset + 3] = 255
    }

    private func byte(_ v: CGFloat) -> UInt8 {
        UInt8(clamping: Int(clamp(v, 0, 1) * 255 + 0.5))
    }
}
