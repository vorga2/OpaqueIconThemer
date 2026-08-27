import Foundation
import SwiftUI

/// iOS 18 keeps the stock slider. iOS 26/27 gets a lightweight Liquid-Glass-like
/// presentation that still compiles with the project's Xcode 16.4 / iOS 18.5 SDK.
struct AdaptiveSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var usesGlassPresentation: Bool {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return major == 26 || major == 27
    }

    var body: some View {
        if usesGlassPresentation {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.13),
                                    Color.white.opacity(0.025)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .allowsHitTesting(false)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.42),
                                    Color.white.opacity(0.10),
                                    Color.black.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                        .allowsHitTesting(false)
                }
                .shadow(color: Color.black.opacity(0.10), radius: 5, y: 2)
        } else {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }
}
