import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

final class IconTintEngine {
    static let shared = IconTintEngine()
    private let context = CIContext()

    private init() {}

    func render(source: UIImage, tint: UIColor, intensity: CGFloat) -> UIImage? {
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1

        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            tint.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let sourceSize = source.size
            guard sourceSize.width > 0, sourceSize.height > 0 else { return }
            let scale = max(size.width / sourceSize.width, size.height / sourceSize.height)
            let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            source.draw(in: CGRect(origin: origin, size: drawSize))
        }

        guard let input = CIImage(image: normalized) else { return nil }
        let filter = CIFilter.colorMonochrome()
        filter.inputImage = input
        filter.color = CIColor(color: tint)
        filter.intensity = Float(max(0, min(1, intensity)))

        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }

        let result = UIImage(cgImage: cgImage)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            tint.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            result.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
