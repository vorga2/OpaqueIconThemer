import Foundation
import SwiftUI

/// Keeps the native iOS 18 slider untouched, while giving iOS 26/27 a lightweight
/// Liquid-Glass-like container without depending on iOS 26 SDK-only symbols.
struct AdaptiveSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var usesGlassPresentation: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    var body: some View {
        if usesGlassPresentation {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.7
                        )
                }
                .shadow(color: Color.black.opacity(0.10), radius: 5, y: 2)
        } else {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }
}
