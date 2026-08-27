import Foundation
import UIKit

/// Advanced Tint+ compositor with a strict no-outline contract.
///
/// The important rule is that boundary pixels never own a separate material. The logo shape is
/// fixed once, slightly inset from the detector's fringe, then the FINAL processed material from
/// confident interior pixels is propagated to that boundary. Tint strength, icon gradient,
/// background intensity and shadows therefore cannot manufacture a third white/blue contour.
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
        gradientStrength: CGFloat,
        customGradientColorEnabled: Bool = false,
        gradientTint: UIColor? = nil,
        shadowsEnabled: Bool = true,
        shadowColor: UIColor = .black,
        shadowStrength: CGFloat = 0.90,
        shadowTintMix: CGFloat = 0.30
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

        // The detector still contains the source icon's own pale/coloured antialias fringe.
        // Build one strict silhouette and inset it by two final-resolution pixels. That removes the
        // source fringe itself instead of recolouring it, so increasing tint strength cannot make
        // the logo physically grow into those neighbouring pixels.
        var detected = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            detected[i] = locked[i] >= 0.72 ? 1 : 0
        }

        var silhouette = erodeBinaryMask(detected, width: width, height: height, radius: 2)
        if !silhouette.contains(where: { $0 > 0.5 }) {
            silhouette = detected
        }

        // Only a safely eroded interior may provide source RGB. The whole boundary band is banned
        // from source colour because it can contain the old white background or coloured AA.
        var materialCore = erodeBinaryMask(silhouette, width: width, height: height, radius: 5)
        if !materialCore.contains(where: { $0 > 0.5 }) {
            materialCore = erodeBinaryMask(silhouette, width: width, height: height, radius: 1)
        }
        if !materialCore.contains(where: { $0 > 0.5 }) {
            materialCore = silhouette
        }

        let bgTintLinear = srgbToLinear(rgb(from: backgroundTint))
        let iconTintLinear = srgbToLinear(rgb(from: iconTint))
        let selectedGradientTint = customGradientColorEnabled ? (gradientTint ?? backgroundTint) : backgroundTint
        let gradientTintLinear = srgbToLinear(rgb(from: selectedGradientTint))
        let userShadowLinear = srgbToLinear(rgb(from: shadowColor))
        let tintedShadowLinear = srgbToLinear(
            mix(
                rgb(from: shadowColor),
                rgb(from: backgroundTint),
                amount: clamp(shadowTintMix, 0, 1)
            )
        )

        let bgStrength = clamp(backgroundIntensity, 0, 1)
        let fgStrength = clamp(iconIntensity, 0, 1)
        let gradStart = clamp(gradientStart, 0, 1)
        let gradStrength = clamp(gradientStrength, 0, 1)
        let depthStrength = shadowsEnabled ? clamp(shadowStrength, 0, 1.5) : 0

        // Compute FINAL foreground material only in the safe interior first. Tint, gradient and
        // shadows are all applied here before any boundary colour exists.
        var coreWeight = [CGFloat](repeating: 0, count: count)
        var coreR = [CGFloat](repeating: 0, count: count)
        var coreG = [CGFloat](repeating: 0, count: count)
        var coreB = [CGFloat](repeating: 0, count: count)

        var globalR: CGFloat = 0
        var globalG: CGFloat = 0
        var globalB: CGFloat = 0
        var globalWeight: CGFloat = 0

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            let gradientAmount = gradientAmountAt(
                yNorm: yNorm,
                start: gradStart,
                strength: gradStrength
            )

            for x in 0..<width {
                let i = y * width + x
                guard materialCore[i] > 0.5 else { continue }
                let p = i * 4

                let sourceLinear = srgbToLinear(RGB(
                    r: CGFloat(pixels[p]) / 255.0,
                    g: CGFloat(pixels[p + 1]) / 255.0,
                    b: CGFloat(pixels[p + 2]) / 255.0
                ))

                var material = mix(sourceLinear, iconTintLinear, amount: fgStrength)

                if gradientAmount > 0.0001 {
                    material = mix(material, gradientTintLinear, amount: gradientAmount)
                }

                // Restore Tint+ shadows, but ONLY as broad interior lighting. No contour bevel,
                // drop shadow or edge highlight is allowed. Keeping this pass inside materialCore
                // leaves at least five untouched pixels between the effect and the silhouette.
                if depthStrength > 0.0001 {
                    let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))
                    let diagonal = clamp((xNorm + yNorm - 0.72) / 1.28, 0, 1)
                    let darkAmount = diagonal * 0.13 * depthStrength
                    if darkAmount > 0.0001 {
                        let effectiveShadow = mix(
                            userShadowLinear,
                            tintedShadowLinear,
                            amount: clamp(shadowTintMix, 0, 1)
                        )
                        material = mix(material, effectiveShadow, amount: clamp(darkAmount, 0, 0.24))
                    }

                    let highlightDirection = clamp((0.62 - (xNorm + yNorm) * 0.5) / 0.62, 0, 1)
                    let highlightAmount = highlightDirection * 0.045 * depthStrength
                    if highlightAmount > 0.0001 {
                        material = screen(
                            material,
                            RGB(r: 1, g: 1, b: 1),
                            amount: clamp(highlightAmount, 0, 0.10)
                        )
                    }
                }

                coreWeight[i] = 1
                coreR[i] = material.r
                coreG[i] = material.g
                coreB[i] = material.b

                globalR += material.r
                globalG += material.g
                globalB += material.b
                globalWeight += 1
            }
        }

        let fallbackMaterial: RGB
        if globalWeight > 0 {
            fallbackMaterial = clampRGB(RGB(
                r: globalR / globalWeight,
                g: globalG / globalWeight,
                b: globalB / globalWeight
            ))
        } else {
            fallbackMaterial = iconTintLinear
        }

        // Propagate the already-processed FINAL material from the interior to the silhouette edge.
        // This is the key no-rim rule: boundary pixels do not independently apply tint/gradient or
        // read source RGB, so there is no mechanism left that can make a separate coloured ring.
        let propagationRadius = 18
        let localWeight = boxBlur(coreWeight, width: width, height: height, radius: propagationRadius)
        let localR = boxBlur(coreR, width: width, height: height, radius: propagationRadius)
        let localG = boxBlur(coreG, width: width, height: height, radius: propagationRadius)
        let localB = boxBlur(coreB, width: width, height: height, radius: propagationRadius)

        let corners = backgroundCorners(pixels: pixels, width: width, height: height)
        var out = [UInt8](repeating: 255, count: count * 4)

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))

                let originalBackground = srgbToLinear(bilinear(corners, x: xNorm, y: yNorm))
                let backgroundMaterial = mix(originalBackground, bgTintLinear, amount: bgStrength)

                guard silhouette[i] > 0.5 else {
                    write(linearToSRGB(backgroundMaterial), to: &out, offset: p)
                    continue
                }

                let foregroundMaterial: RGB
                if materialCore[i] > 0.5 {
                    foregroundMaterial = RGB(r: coreR[i], g: coreG[i], b: coreB[i])
                } else {
                    let support = localWeight[i]
                    if support > 0.001 {
                        foregroundMaterial = clampRGB(RGB(
                            r: localR[i] / support,
                            g: localG[i] / support,
                            b: localB[i] / support
                        ))
                    } else {
                        foregroundMaterial = fallbackMaterial
                    }
                }

                // Binary two-material selection at 1024px. The PNG stores no transition colour and
                // no parameter-dependent coverage. Display-time downsampling handles visual AA.
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
                if remove >= 0 {
                    sum -= input[row + remove]
                    samples -= 1
                }
                if add < width {
                    sum += input[row + add]
                    samples += 1
                }
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
                if remove >= 0 {
                    sum -= horizontal[remove * width + x]
                    samples -= 1
                }
                if add < height {
                    sum += horizontal[add * width + x]
                    samples += 1
                }
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
        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: bitmap
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func imageFromRGBA(_ data: [UInt8], width: Int, height: Int) -> UIImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Colour math

    private func gradientAmountAt(yNorm: CGFloat, start: CGFloat, strength: CGFloat) -> CGFloat {
        guard strength > 0.0001, yNorm > start else { return 0 }
        let t = clamp((yNorm - start) / max(0.001, 1 - start), 0, 1)
        return smoothstep(edge0: 0, edge1: 1, value: t) * strength
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

    private func screen(_ base: RGB, _ light: RGB, amount: CGFloat) -> RGB {
        let a = clamp(amount, 0, 1)
        let screened = RGB(
            r: 1 - (1 - base.r) * (1 - light.r),
            g: 1 - (1 - base.g) * (1 - light.g),
            b: 1 - (1 - base.b) * (1 - light.b)
        )
        return mix(base, screened, amount: a)
    }

    private func clampRGB(_ c: RGB) -> RGB {
        RGB(
            r: clamp(c.r, 0, 1),
            g: clamp(c.g, 0, 1),
            b: clamp(c.b, 0, 1)
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
