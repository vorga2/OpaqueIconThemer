import Foundation
import UIKit

/// Advanced Tint+ compositor.
///
/// The important difference from the older combined pass is that antialiased edge pixels are
/// decontaminated from the *original* icon background before the new background colour is applied.
/// Reusing the already-flattened edge pixel directly leaves a pale/white rim when
/// `backgroundIntensity` rises, because that pixel still contains the old light background.
///
/// Pipeline:
/// 1. build one fixed foreground geometry (independent from both intensity sliders);
/// 2. infer the original local background from the icon border;
/// 3. unmix the original foreground colour at soft edge pixels;
/// 4. tint background and foreground independently;
/// 5. apply the optional lower icon gradient using *backgroundTint* as its colour;
/// 6. composite foreground back over the tinted background using the same fixed coverage.
///
/// The gradient strength is intentionally independent from icon tint strength.
final class AdvancedTintCompositeProcessor {
    static let shared = AdvancedTintCompositeProcessor()

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
        iconIntensity: CGFloat,
        gradientStart: CGFloat,
        gradientStrength: CGFloat
    ) -> UIImage? {
        let width = 512
        let height = 512
        let bgStrength = clamp(backgroundIntensity, 0, 1)
        let fgStrength = clamp(iconIntensity, 0, 1)
        let gradStart = clamp(gradientStart, 0, 1)
        let gradStrength = clamp(gradientStrength, 0, 1)

        guard let sourcePixels = rgbaPixels(from: source, width: width, height: height),
              let renderedPixels = rgbaPixels(from: rendered, width: width, height: height),
              let softMask = LayerAwareForegroundDetector.shared.foregroundMask(
                source: source,
                width: width,
                height: height
              ),
              softMask.count == width * height else {
            return rendered
        }

        let locked = TintForegroundGeometry.shared.lockedCoverage(
            softMask: softMask,
            width: width,
            height: height
        )
        guard locked.count == width * height else { return rendered }

        let border = borderReferences(pixels: sourcePixels, width: width, height: height)
        let fallback = border.isEmpty ? RGB(r: 0.5, g: 0.5, b: 0.5) : mean(border)
        let corners = cornerBackgrounds(
            pixels: sourcePixels,
            width: width,
            height: height,
            fallback: fallback
        )

        let bgTintLinear = srgbToLinear(rgb(from: backgroundTint))
        let iconTintLinear = srgbToLinear(rgb(from: iconTint))
        var output = renderedPixels

        for y in 0..<height {
            let yNorm = CGFloat(y) / CGFloat(max(1, height - 1))
            let spatialGradient: CGFloat
            if yNorm <= gradStart || gradStrength <= 0.0001 {
                spatialGradient = 0
            } else {
                let t = clamp((yNorm - gradStart) / max(0.001, 1 - gradStart), 0, 1)
                spatialGradient = (t * t * (3 - 2 * t)) * gradStrength
            }

            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let xNorm = CGFloat(x) / CGFloat(max(1, width - 1))

                // Keep the geometry fixed and slightly suppress only the extremely weak residual
                // edge coverage. Neither slider participates in this calculation.
                let rawCoverage = clamp(locked[i], 0, 1)
                let edgeT = clamp((rawCoverage - 0.025) / 0.975, 0, 1)
                let coverage = edgeT * edgeT * (3 - 2 * edgeT)

                let localBackgroundSRGB = bilinear(corners, x: xNorm, y: yNorm)
                let localBackground = srgbToLinear(localBackgroundSRGB)
                let tintedBackground = mix(localBackground, bgTintLinear, amount: bgStrength)

                if coverage <= 0.0001 {
                    let final = linearToSRGB(tintedBackground)
                    write(final, to: &output, offset: p)
                    continue
                }

                let sourceRGB = RGB(
                    r: CGFloat(sourcePixels[p]) / 255.0,
                    g: CGFloat(sourcePixels[p + 1]) / 255.0,
                    b: CGFloat(sourcePixels[p + 2]) / 255.0
                )
                let sourceLinear = srgbToLinear(sourceRGB)

                // The source bitmap is already flattened. At an AA edge it is approximately:
                // source = foreground * coverage + oldBackground * (1 - coverage).
                // Solve that equation before compositing onto the *new* background. This is the
                // key step that removes the white outline caused by background intensity.
                let solveCoverage = max(coverage, 0.055)
                var recoveredForeground = RGB(
                    r: (sourceLinear.r - localBackground.r * (1 - solveCoverage)) / solveCoverage,
                    g: (sourceLinear.g - localBackground.g * (1 - solveCoverage)) / solveCoverage,
                    b: (sourceLinear.b - localBackground.b * (1 - solveCoverage)) / solveCoverage
                )
                recoveredForeground = clampRGB(recoveredForeground)

                var foregroundMaterial = mix(
                    recoveredForeground,
                    iconTintLinear,
                    amount: fgStrength
                )

                // Advanced Tint gradient: colour always comes from the background colour and the
                // amount is completely independent of `fgStrength` / “Сила тинта”.
                if spatialGradient > 0.0001 {
                    foregroundMaterial = mix(
                        foregroundMaterial,
                        bgTintLinear,
                        amount: spatialGradient
                    )
                }

                let resultLinear = mix(
                    tintedBackground,
                    foregroundMaterial,
                    amount: coverage
                )
                let final = linearToSRGB(resultLinear)
                write(final, to: &output, offset: p)
            }
        }

        return finalImage(output, width: width, height: height)
    }

    // MARK: - Background inference

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

    private func cornerBackgrounds(
        pixels: [UInt8],
        width: Int,
        height: Int,
        fallback: RGB
    ) -> (RGB, RGB, RGB, RGB) {
        let radius = max(5, min(width, height) / 24)
        let tl = patchMean(pixels: pixels, width: width, height: height, cx: radius, cy: radius, radius: radius) ?? fallback
        let tr = patchMean(pixels: pixels, width: width, height: height, cx: width - 1 - radius, cy: radius, radius: radius) ?? fallback
        let bl = patchMean(pixels: pixels, width: width, height: height, cx: radius, cy: height - 1 - radius, radius: radius) ?? fallback
        let br = patchMean(pixels: pixels, width: width, height: height, cx: width - 1 - radius, cy: height - 1 - radius, radius: radius) ?? fallback
        return (tl, tr, bl, br)
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
        var count: CGFloat = 0
        let minY = max(0, cy - radius)
        let maxY = min(height - 1, cy + radius)
        let minX = max(0, cx - radius)
        let maxX = min(width - 1, cx + radius)

        for y in minY...maxY {
            for x in minX...maxX {
                let p = (y * width + x) * 4
                r += CGFloat(pixels[p]) / 255.0
                g += CGFloat(pixels[p + 1]) / 255.0
                b += CGFloat(pixels[p + 2]) / 255.0
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return RGB(r: r / count, g: g / count, b: b / count)
    }

    private func bilinear(_ corners: (RGB, RGB, RGB, RGB), x: CGFloat, y: CGFloat) -> RGB {
        let top = mix(corners.0, corners.1, amount: clamp(x, 0, 1))
        let bottom = mix(corners.2, corners.3, amount: clamp(x, 0, 1))
        return mix(top, bottom, amount: clamp(y, 0, 1))
    }

    private func mean(_ values: [RGB]) -> RGB {
        guard !values.isEmpty else { return RGB(r: 0.5, g: 0.5, b: 0.5) }
        let n = CGFloat(values.count)
        let sum = values.reduce((CGFloat.zero, CGFloat.zero, CGFloat.zero)) {
            ($0.0 + $1.r, $0.1 + $1.g, $0.2 + $1.b)
        }
        return RGB(r: sum.0 / n, g: sum.1 / n, b: sum.2 / n)
    }

    // MARK: - Color math / image helpers

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

    private func mix(_ a: RGB, _ b: RGB, amount: CGFloat) -> RGB {
        let t = clamp(amount, 0, 1)
        return RGB(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t
        )
    }

    private func clampRGB(_ value: RGB) -> RGB {
        RGB(r: clamp(value.r, 0, 1), g: clamp(value.g, 0, 1), b: clamp(value.b, 0, 1))
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

    private func finalImage(_ rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let work = imageFromRGBA(rgba, width: width, height: height) else { return nil }
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            // High-quality scaling remains safe here because the edge colour is already
            // decontaminated before this point; interpolation no longer reintroduces a white rim.
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

    private func write(_ rgb: RGB, to output: inout [UInt8], offset: Int) {
        output[offset] = byte(rgb.r)
        output[offset + 1] = byte(rgb.g)
        output[offset + 2] = byte(rgb.b)
        output[offset + 3] = 255
    }

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(clamp(value, 0, 1) * 255.0 + 0.5))
    }
}
