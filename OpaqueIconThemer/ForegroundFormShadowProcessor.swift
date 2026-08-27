import Foundation
import UIKit

/// Final, dedicated cast-shadow pass for the detected foreground artwork.
///
/// This processor deliberately does NOT shade the outer app-icon tile. It only paints a soft,
/// user-coloured shadow outside the detected logo/form, with a hard safety band around all four
/// sides of the square icon. It runs after the historical no-rim pipeline, so the shadow cannot
/// alter foreground geometry or bring back silhouette bevel/AA contours.
final class ForegroundFormShadowProcessor {
    static let shared = ForegroundFormShadowProcessor()

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

        guard let renderedCG = rendered.cgImage else { return rendered }
        let width = max(64, renderedCG.width)
        let height = max(64, renderedCG.height)
        let count = width * height

        guard let renderedPixels = rgbaPixels(from: rendered, width: width, height: height),
              let softMask = LayerAwareForegroundDetector.shared.foregroundMask(
                source: source,
                width: width,
                height: height
              ),
              softMask.count == count else {
            return rendered
        }

        // Strict geometry: the shadow is derived from the foreground body, never from fringe pixels.
        var form = [CGFloat](repeating: 0, count: count)
        var foregroundCount = 0
        for i in 0..<count {
            let covered = softMask[i] >= 0.72
            form[i] = covered ? 1 : 0
            if covered { foregroundCount += 1 }
        }

        let coverage = CGFloat(foregroundCount) / CGFloat(max(1, count))
        // Full-art/game icons do not have a stable isolated logo. Do nothing rather than shadowing
        // the whole tile or manufacturing a perimeter effect.
        guard coverage >= 0.004, coverage <= 0.78 else { return rendered }

        let designScale = CGFloat(min(width, height)) / 180.0
        let contactRadius = max(1, Int((4.5 * designScale).rounded()))
        let ambientRadius = max(contactRadius + 1, Int((11.0 * designScale).rounded()))
        let contactOffset = max(1, Int((2.0 * designScale).rounded()))
        let ambientOffset = max(contactOffset + 1, Int((5.0 * designScale).rounded()))

        let contactBlur = boxBlur(form, width: width, height: height, radius: contactRadius)
        let ambientBlur = boxBlur(form, width: width, height: height, radius: ambientRadius)

        // A larger exclusion band than the old implementation: absolutely no shadow may appear on
        // the left/right/top/bottom edge of the app icon itself.
        let tileSafetyInset = max(5, Int((7.0 * designScale).rounded()))

        let selected = rgb(from: shadowColor)
        let surface = rgb(from: surfaceColor)
        // Preserve the user's chosen colour. Tint mix is intentionally weaker here so red at 100%
        // remains visibly red instead of being washed into the background colour.
        let effective = mix(selected, surface, amount: clamp(tintMix, 0, 1) * 0.45)

        var output = renderedPixels

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let outside = 1 - form[i]
                guard outside > 0.001 else { continue }

                let inTileSafetyBand = x < tileSafetyInset ||
                    x >= width - tileSafetyInset ||
                    y < tileSafetyInset ||
                    y >= height - tileSafetyInset
                guard !inTileSafetyBand else { continue }

                let halo = contactBlur[i]
                let contact = sample(
                    contactBlur,
                    width: width,
                    height: height,
                    x: x,
                    y: y - contactOffset
                )
                let ambient = sample(
                    ambientBlur,
                    width: width,
                    height: height,
                    x: x,
                    y: y - ambientOffset
                )

                // The unshifted term gives a visible soft outline-like shadow around the FORM,
                // while the shifted terms provide a small contact/ambient depth below it.
                // This is a blur, not a stroke: there is no hard 1px contour.
                let shadowAlpha = clamp(
                    outside * amount * (
                        halo * 0.42 +
                        contact * 0.46 +
                        ambient * 0.20
                    ),
                    0,
                    0.78
                )
                guard shadowAlpha > 0.002 else { continue }

                let p = i * 4
                let base = RGB(
                    r: CGFloat(renderedPixels[p]) / 255.0,
                    g: CGFloat(renderedPixels[p + 1]) / 255.0,
                    b: CGFloat(renderedPixels[p + 2]) / 255.0
                )
                let mixed = mix(base, effective, amount: shadowAlpha)
                output[p] = byte(mixed.r)
                output[p + 1] = byte(mixed.g)
                output[p + 2] = byte(mixed.b)
                output[p + 3] = 255
            }
        }

        return imageFromRGBA(output, width: width, height: height)
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

    private func sample(
        _ values: [CGFloat],
        width: Int,
        height: Int,
        x: Int,
        y: Int
    ) -> CGFloat {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return values[y * width + x]
    }

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
        ctx.interpolationQuality = .high
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
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func rgb(from color: UIColor) -> RGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return RGB(r: 0, g: 0, b: 0)
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

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(clamp(value, 0, 1) * 255.0 + 0.5))
    }
}
