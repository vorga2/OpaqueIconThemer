import Foundation
import CoreGraphics

/// Converts the permissive layer-aware mask into a stable Tint+ coverage map.
///
/// The shared layer detector intentionally keeps weak neighbouring pixels so translucent
/// nested artwork is not lost. That is useful for reconstruction, but it is too permissive
/// for a colour-strength slider: low-confidence pixels around the OUTSIDE silhouette become
/// visible as the tint colour gets stronger and the logo appears to grow.
///
/// This pass separates those two jobs:
/// - outside-connected pixels use a strict, narrow edge curve;
/// - weak material enclosed inside a confident logo may still use the richer layer mask;
/// - the returned coverage never depends on tint strength.
final class TintForegroundGeometry {
    static let shared = TintForegroundGeometry()

    private init() {}

    func lockedCoverage(
        softMask: [CGFloat],
        width: Int,
        height: Int
    ) -> [CGFloat] {
        guard width > 2, height > 2, softMask.count == width * height else {
            return softMask
        }

        let count = width * height
        var strict = [CGFloat](repeating: 0, count: count)

        // Deliberately reject the broad low-confidence fringe produced by the layer-aware
        // recovery pass. The transition remains soft enough for AA, but it is only ~1 px wide
        // at the 512 px working resolution and does not spread into neighbouring background.
        for i in 0..<count {
            strict[i] = smoothstep(
                edge0: 0.48,
                edge1: 0.76,
                value: clamp(softMask[i], 0, 1)
            )
        }

        // Find background that is actually connected to the image border. Weak pixels in this
        // exterior region are fringe/background and must never receive icon tint. Weak material
        // enclosed by strong foreground (Settings centre, Photos overlaps, etc.) is not exterior
        // and is therefore allowed to keep the richer layer-aware coverage below.
        let wallThreshold: CGFloat = 0.60
        var exterior = [Bool](repeating: false, count: count)
        var queue = [Int]()
        queue.reserveCapacity(count / 3)

        func canFlood(_ index: Int) -> Bool {
            clamp(softMask[index], 0, 1) < wallThreshold
        }

        func enqueue(_ index: Int) {
            guard index >= 0, index < count, !exterior[index], canFlood(index) else { return }
            exterior[index] = true
            queue.append(index)
        }

        for x in 0..<width {
            enqueue(x)
            enqueue((height - 1) * width + x)
        }
        for y in 0..<height {
            enqueue(y * width)
            enqueue(y * width + width - 1)
        }

        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width

            if x > 0 { enqueue(index - 1) }
            if x + 1 < width { enqueue(index + 1) }
            if y > 0 { enqueue(index - width) }
            if y + 1 < height { enqueue(index + width) }
        }

        var result = strict
        for i in 0..<count where !exterior[i] {
            // Interior/nested material may be faint. Preserve it without reopening the outside
            // halo. This is why we do connectivity rather than just raising one global threshold.
            let nested = smoothstep(
                edge0: 0.12,
                edge1: 0.70,
                value: clamp(softMask[i], 0, 1)
            )
            result[i] = max(result[i], nested)
        }

        return result.map { clamp($0, 0, 1) }
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }
}
