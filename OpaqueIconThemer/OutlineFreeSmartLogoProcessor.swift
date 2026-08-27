import Foundation
import UIKit

/// Final edge compositor for Smart Logo / Apple Mono.
///
/// Smart Logo has several independent render stages (white/gradient material, background
/// intensity, internal depth). None of those stages is allowed to create a third contour colour
/// around the foreground. This pass converts the detected foreground into the same strict 1024px
/// two-material geometry used by the fixed Tint+ path:
/// - source fringe is excluded from the silhouette;
/// - boundary pixels never read their own flattened source colour;
/// - final foreground material is propagated from confident interior pixels;
/// - residual foreground fringe outside the silhouette is replaced from safe background pixels.
///
/// The stored PNG therefore contains only foreground material or background material at the
/// silhouette boundary. Display-time downsampling supplies normal antialiasing without a white,
/// blue or parameter-dependent outline.
final class OutlineFreeSmartLogoProcessor {
    static let shared = OutlineFreeSmartLogoProcessor()

    private init() {}

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
    }

    func apply(source: UIImage, rendered: UIImage) -> UIImage? {
        let width = 1024
        let height = 1024
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

        let locked = TintForegroundGeometry.shared.lockedCoverage(
            softMask: softMask,
            width: width,
            height: height
        )
        guard locked.count == count else { return rendered }

        // Reject the detector's weak source fringe, then inset by two final-resolution pixels.
        // This is intentionally the same geometry policy that finally removed Tint+ contours.
        var detected = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            detected[i] = locked[i] >= 0.72 ? 1 : 0
        }

        var silhouette = erodeBinaryMask(detected, width: width, height: height, radius: 2)
        if !silhouette.contains(where: { $0 > 0.5 }) {
            silhouette = detected
        }

        // Boundary pixels are not allowed to source their own colour. Take final Smart Logo
        // material only from safely interior pixels (the gradient is already baked into rendered).
        var materialCore = erodeBinaryMask(silhouette, width: width, height: height, radius: 5)
        if !materialCore.contains(where: { $0 > 0.5 }) {
            materialCore = erodeBinaryMask(silhouette, width: width, height: height, radius: 1)
        }
        if !materialCore.contains(where: { $0 > 0.5 }) {
            materialCore = silhouette
        }

        var coreWeight = [CGFloat](repeating: 0, count: count)
        var coreR = [CGFloat](repeating: 0, count: count)
        var coreG = [CGFloat](repeating: 0, count: count)
        var coreB = [CGFloat](repeating: 0, count: count)

        var bgWeight = [CGFloat](repeating: 0, count: count)
        var bgR = [CGFloat](repeating: 0, count: count)
        var bgG = [CGFloat](repeating: 0, count: count)
        var bgB = [CGFloat](repeating: 0, count: count)

        var globalCoreR: CGFloat = 0
        var globalCoreG: CGFloat = 0
        var globalCoreB: CGFloat = 0
        var globalCoreWeight: CGFloat = 0

        for i in 0..<count {
            let p = i * 4
            let value = srgbToLinear(RGB(
                r: CGFloat(renderedPixels[p]) / 255.0,
                g: CGFloat(renderedPixels[p + 1]) / 255.0,
                b: CGFloat(renderedPixels[p + 2]) / 255.0
            ))

            if materialCore[i] > 0.5 {
                coreWeight[i] = 1
                coreR[i] = value.r
                coreG[i] = value.g
                coreB[i] = value.b
                globalCoreR += value.r
                globalCoreG += value.g
                globalCoreB += value.b
                globalCoreWeight += 1
            }

            // Only very safe background pixels can provide edge background colour. Anything in
            // the detector's fringe is deliberately excluded so an old white/blue halo cannot be
            // propagated back into the final image.
            let safeBackground = locked[i] <= 0.08 ? CGFloat(1) : CGFloat(0)
            if safeBackground > 0 {
                bgWeight[i] = safeBackground
                bgR[i] = value.r
                bgG[i] = value.g
                bgB[i] = value.b
            }
        }

        let fallbackForeground: RGB
        if globalCoreWeight > 0 {
            fallbackForeground = clampRGB(RGB(
                r: globalCoreR / globalCoreWeight,
                g: globalCoreG / globalCoreWeight,
                b: globalCoreB / globalCoreWeight
            ))
        } else {
            fallbackForeground = RGB(r: 1, g: 1, b: 1)
        }

        // Wide enough to bridge the banned fringe band, but still local relative to a 1024px icon.
        let propagationRadius = 18
        let localCoreWeight = boxBlur(coreWeight, width: width, height: height, radius: propagationRadius)
        let localCoreR = boxBlur(coreR, width: width, height: height, radius: propagationRadius)
        let localCoreG = boxBlur(coreG, width: width, height: height, radius: propagationRadius)
        let localCoreB = boxBlur(coreB, width: width, height: height, radius: propagationRadius)

        let localBGWeight = boxBlur(bgWeight, width: width, height: height, radius: propagationRadius)
        let localBGR = boxBlur(bgR, width: width, height: height, radius: propagationRadius)
        let localBGG = boxBlur(bgG, width: width, height: height, radius: propagationRadius)
        let localBGB = boxBlur(bgB, width: width, height: height, radius: propagationRadius)

        var output = renderedPixels

        for i in 0..<count {
            let p = i * 4

            if silhouette[i] > 0.5 {
                let material: RGB
                if materialCore[i] > 0.5 {
                    material = srgbToLinear(RGB(
                        r: CGFloat(renderedPixels[p]) / 255.0,
                        g: CGFloat(renderedPixels[p + 1]) / 255.0,
                        b: CGFloat(renderedPixels[p + 2]) / 255.0
                    ))
                } else if localCoreWeight[i] > 0.001 {
                    material = clampRGB(RGB(
                        r: localCoreR[i] / localCoreWeight[i],
                        g: localCoreG[i] / localCoreWeight[i],
                        b: localCoreB[i] / localCoreWeight[i]
                    ))
                } else {
                    material = fallbackForeground
                }

                write(linearToSRGB(material), to: &output, offset: p)
                continue
            }

            // Far background is already correct and is preserved exactly. Only the detector fringe
            // outside the strict silhouette is scrubbed and replaced with nearby safe background.
            if locked[i] > 0.015, localBGWeight[i] > 0.001 {
                let background = clampRGB(RGB(
                    r: localBGR[i] / localBGWeight[i],
                    g: localBGG[i] / localBGWeight[i],
                    b: localBGB[i] / localBGWeight[i]
                ))
                write(linearToSRGB(background), to: &output, offset: p)
            } else {
                output[p + 3] = 255
            }
        }

        return imageFromRGBA(output, width: width, height: height)
    }

    // MARK: - Geometry / filtering

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
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: bitmap
        ) else { return nil }

        // Never manufacture an extra transition colour while sampling the already rendered bitmap.
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
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

    private func clampRGB(_ value: RGB) -> RGB {
        RGB(r: clamp(value.r, 0, 1), g: clamp(value.g, 0, 1), b: clamp(value.b, 0, 1))
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
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
