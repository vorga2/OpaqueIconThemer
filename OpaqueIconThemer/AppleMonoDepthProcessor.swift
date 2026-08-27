import Foundation
import UIKit

/// Restores the depth cues that are lost when a colorful legacy icon is flattened into Mono.
///
/// This is deliberately a *foreground-only* post-process. It never shades the outer app tile.
/// The pass uses the original icon as a depth reference and reconstructs:
/// - low/high frequency luminance relief;
/// - raised translucent/overlap regions;
/// - recessed/cavity regions;
/// - contact shadows between internal layers;
/// - a subtle top-left highlight / bottom-right bevel.
///
/// The result remains a fully opaque bitmap, so there is no runtime shader cost in SpringBoard.
final class AppleMonoDepthProcessor {
    static let shared = AppleMonoDepthProcessor()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    func apply(
        source: UIImage,
        rendered: UIImage,
        strength: CGFloat = 1.0
    ) -> UIImage? {
        let amount = clamp(strength, 0, 1.35)
        guard amount > 0.001 else { return rendered }

        let width = 512
        let height = 512
        guard let sourcePixels = rgbaPixels(from: source, width: width, height: height),
              let renderedPixels = rgbaPixels(from: rendered, width: width, height: height),
              let logoMask = LayerAwareForegroundDetector.shared.foregroundMask(
                source: source,
                width: width,
                height: height
              ),
              logoMask.count == width * height else {
            return rendered
        }

        let pixelCount = width * height
        var luminance = [CGFloat](repeating: 0, count: pixelCount)
        var chroma = [CGFloat](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let p = i * 4
            let alpha = CGFloat(sourcePixels[p + 3]) / 255.0
            let sourceRGB = alpha > 0.0001
                ? straightRGB(pixels: sourcePixels, offset: p, alpha: alpha)
                : RGB(r: 0, g: 0, b: 0)
            let linear = srgbToLinear(sourceRGB)

            luminance[i] = clamp(
                0.2126 * linear.r +
                0.7152 * linear.g +
                0.0722 * linear.b,
                0,
                1
            )

            let maxChannel = max(linear.r, max(linear.g, linear.b))
            let minChannel = min(linear.r, min(linear.g, linear.b))
            chroma[i] = maxChannel - minChannel
        }

        // Two scales separate material relief from broad petal/body shading.
        let lumaSmall = boxBlur(luminance, width: width, height: height, radius: 4)
        let lumaLarge = boxBlur(luminance, width: width, height: height, radius: 17)
        let chromaMean = boxBlur(chroma, width: width, height: height, radius: 8)
        let softLogo = boxBlur(logoMask, width: width, height: height, radius: 4)

        var raised = [CGFloat](repeating: 0, count: pixelCount)
        var cavity = [CGFloat](repeating: 0, count: pixelCount)
        var detail = [CGFloat](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let logo = clamp(logoMask[i], 0, 1)
            guard logo > 0.001 else { continue }

            let fine = luminance[i] - lumaSmall[i]
            let broad = lumaSmall[i] - lumaLarge[i]
            let chromaStructure = abs(chroma[i] - chromaMean[i])

            // Bright overlap/highlight regions become a shallow upper layer. Chroma structure
            // contributes only a little: it helps recover overlaps from flattened colorful art
            // without inventing large fake height changes from hue alone.
            let raisedSignal = fine * 1.25 + broad * 0.85 + chromaStructure * 0.16
            raised[i] = smoothstep(edge0: 0.010, edge1: 0.105, value: raisedSignal) * logo

            let cavitySignal = -(fine * 1.05 + broad * 0.75)
            cavity[i] = smoothstep(edge0: 0.010, edge1: 0.095, value: cavitySignal) * logo

            // Preserve both fine ridges and broad layer separation. This is the main fix for
            // Photos/Settings-like icons where a simple two-point luminance ramp looks flat.
            detail[i] = clamp(
                fine * 2.35 + broad * 1.35,
                -0.28,
                0.28
            ) * logo
        }

        let raisedBlur = boxBlur(raised, width: width, height: height, radius: 5)
        let cavityBlur = boxBlur(cavity, width: width, height: height, radius: 3)

        let layerOffset = 4
        let bevelOffset = 3
        let white = RGB(r: 1, g: 1, b: 1)
        let depthShadow = RGB(r: 0.09, g: 0.10, b: 0.12)

        var output = renderedPixels

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = i * 4
                let logo = clamp(logoMask[i], 0, 1)
                guard logo > 0.001 else {
                    output[p + 3] = 255
                    continue
                }

                let renderedRGB = RGB(
                    r: CGFloat(renderedPixels[p]) / 255.0,
                    g: CGFloat(renderedPixels[p + 1]) / 255.0,
                    b: CGFloat(renderedPixels[p + 2]) / 255.0
                )
                var result = srgbToLinear(renderedRGB)

                // Restore source-local tonal relief while keeping the already chosen Mono hue.
                let localDetail = detail[i] * amount
                if localDetail > 0 {
                    result = screen(
                        result,
                        white,
                        amount: clamp(localDetail * 0.62, 0, 0.22)
                    )
                } else if localDetail < 0 {
                    result = mix(
                        result,
                        depthShadow,
                        amount: clamp(-localDetail * 0.48, 0, 0.18)
                    )
                }

                // Raised inner material casts a short contact shadow down/right. We sample the
                // upper-left neighborhood because a raised piece there shades the current pixel.
                let upperLeftLayer = sample(
                    raisedBlur,
                    width: width,
                    height: height,
                    x: x - layerOffset,
                    y: y - layerOffset
                )
                let contact = clamp(
                    (upperLeftLayer - raised[i] * 0.58) * logo,
                    0,
                    1
                )
                if contact > 0.001 {
                    result = mix(
                        result,
                        depthShadow,
                        amount: clamp(contact * 0.18 * amount, 0, 0.17)
                    )
                }

                // Recessed areas (for example the Photos center) receive soft ambient occlusion.
                let recess = clamp(cavityBlur[i] * logo, 0, 1)
                if recess > 0.001 {
                    result = mix(
                        result,
                        depthShadow,
                        amount: clamp(recess * 0.115 * amount, 0, 0.12)
                    )
                }

                // Raised translucent/overlap pieces keep a lighter top surface instead of turning
                // into the same opaque white mass as the lower layer.
                let topLayer = clamp(raised[i], 0, 1)
                if topLayer > 0.001 {
                    result = screen(
                        result,
                        white,
                        amount: clamp(topLayer * 0.105 * amount, 0, 0.11)
                    )
                }

                // Directional bevel only on the foreground shape. No tile-perimeter shading.
                let maskTopLeft = sample(
                    softLogo,
                    width: width,
                    height: height,
                    x: x - bevelOffset,
                    y: y - bevelOffset
                )
                let maskBottomRight = sample(
                    softLogo,
                    width: width,
                    height: height,
                    x: x + bevelOffset,
                    y: y + bevelOffset
                )
                let topLeftEdge = clamp(logo * (1 - maskTopLeft), 0, 1)
                let bottomRightEdge = clamp(logo * (1 - maskBottomRight), 0, 1)

                if topLeftEdge > 0.001 {
                    result = screen(
                        result,
                        white,
                        amount: clamp(topLeftEdge * 0.20 * amount, 0, 0.16)
                    )
                }
                if bottomRightEdge > 0.001 {
                    result = mix(
                        result,
                        depthShadow,
                        amount: clamp(bottomRightEdge * 0.13 * amount, 0, 0.11)
                    )
                }

                let final = linearToSRGB(result)
                output[p] = byte(final.r)
                output[p + 1] = byte(final.g)
                output[p + 2] = byte(final.b)
                output[p + 3] = 255
            }
        }

        return finalImage(output, width: width, height: height)
    }

    // MARK: - Fast image math

    private func boxBlur(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, input.count == width * height else { return input }
        var horizontal = [CGFloat](repeating: 0, count: input.count)
        var output = [CGFloat](repeating: 0, count: input.count)

        for y in 0..<height {
            let row = y * width
            var sum: CGFloat = 0
            var samples = 0
            for x in -radius...radius where x >= 0 && x < width {
                sum += input[row + x]
                samples += 1
            }
            for x in 0..<width {
                horizontal[row + x] = sum / CGFloat(max(1, samples))
                let removeX = x - radius
                let addX = x + radius + 1
                if removeX >= 0 {
                    sum -= input[row + removeX]
                    samples -= 1
                }
                if addX < width {
                    sum += input[row + addX]
                    samples += 1
                }
            }
        }

        for x in 0..<width {
            var sum: CGFloat = 0
            var samples = 0
            for y in -radius...radius where y >= 0 && y < height {
                sum += horizontal[y * width + x]
                samples += 1
            }
            for y in 0..<height {
                output[y * width + x] = sum / CGFloat(max(1, samples))
                let removeY = y - radius
                let addY = y + radius + 1
                if removeY >= 0 {
                    sum -= horizontal[removeY * width + x]
                    samples -= 1
                }
                if addY < height {
                    sum += horizontal[addY * width + x]
                    samples += 1
                }
            }
        }

        return output
    }

    private func sample(_ values: [CGFloat], width: Int, height: Int, x: Int, y: Int) -> CGFloat {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return values[y * width + x]
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

    private func srgbToLinear(_ rgb: RGB) -> RGB {
        RGB(r: srgbToLinear(rgb.r), g: srgbToLinear(rgb.g), b: srgbToLinear(rgb.b))
    }

    private func srgbToLinear(_ value: CGFloat) -> CGFloat {
        let v = clamp(value, 0, 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private func linearToSRGB(_ rgb: RGB) -> RGB {
        RGB(r: linearToSRGB(rgb.r), g: linearToSRGB(rgb.g), b: linearToSRGB(rgb.b))
    }

    private func linearToSRGB(_ value: CGFloat) -> CGFloat {
        let v = max(0, value)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
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
        let t = clamp(amount, 0, 1)
        let screened = RGB(
            r: 1 - (1 - base.r) * (1 - light.r),
            g: 1 - (1 - base.g) * (1 - light.g),
            b: 1 - (1 - base.b) * (1 - light.b)
        )
        return mix(base, screened, amount: t)
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    private func byte(_ value: CGFloat) -> UInt8 {
        UInt8(clamping: Int(clamp(value, 0, 1) * 255.0 + 0.5))
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }
}
