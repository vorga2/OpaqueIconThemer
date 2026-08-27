from pathlib import Path

# Follow-up refinement after the first Smart Logo no-rim pass.
#
# 1) Smart Logo: build the base image from two explicit materials instead of sampling the old
#    rendered AA edge. This prevents source/background colours from surviving as tiny coloured
#    slivers when the Smart Logo tint/gradient is active. Internal depth is still preserved, then
#    the existing final edge scrubber runs one more time after depth.
# 2) Advanced Tint+: slightly tighten foreground detection and drop only tiny isolated components.
#    This improves background recognition on icons such as Files without changing the general
#    layer-aware detector or breaking legitimate disconnected logo pieces.

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")

old_smart = '''            let outlineFreeSmartLogo = OutlineFreeSmartLogoProcessor.shared.apply(
                source: snapshot.source,
                rendered: backgroundAdjusted
            ) ?? backgroundAdjusted

            baseOutput = AppleMonoDepthProcessor.shared.apply(
                source: snapshot.source,
                rendered: outlineFreeSmartLogo,
                strength: 1.0
            ) ?? outlineFreeSmartLogo
'''

new_smart = '''            // Rebuild Smart Logo from explicit foreground/background materials. The old
            // backgroundAdjusted bitmap is intentionally not used as the logo boundary source:
            // its AA pixels can still contain the original icon background and become coloured
            // slivers when the Smart Logo tint/gradient changes.
            let strictSmartBase = SmartLogoNoRimProcessorV2.shared.apply(
                source: snapshot.source,
                tint: snapshot.backgroundTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                gradientStart: snapshot.gradientStart,
                gradientStrength: snapshot.gradientEnabled ? snapshot.gradientStrength : 0.0,
                gradientEnabled: snapshot.gradientEnabled
            ) ?? backgroundAdjusted

            let depthAdjusted = AppleMonoDepthProcessor.shared.apply(
                source: snapshot.source,
                rendered: strictSmartBase,
                strength: 1.0
            ) ?? strictSmartBase

            // Depth is interior-only, but run the final two-material edge scrub AFTER it as well.
            // That guarantees no later pass can reintroduce a white/blue/red contour.
            baseOutput = OutlineFreeSmartLogoProcessor.shared.apply(
                source: snapshot.source,
                rendered: depthAdjusted
            ) ?? depthAdjusted
'''

if old_smart not in ui:
    raise SystemExit("Smart Logo v2 patch failed: first no-rim Smart Logo render block not found")
ui = ui.replace(old_smart, new_smart, 1)

# Visible generation marker for testing the actually installed build.
marker = 'Text("Tint+ NoRim-4 • build '
if marker in ui and "SmartLogo NR2" not in ui:
    ui = ui.replace(
        'Text("Tint+ NoRim-4 • build \\(Bundle.main.object(forInfoDictionaryKey: \\"CFBundleVersion\\") as? String ?? \\"?\\")")',
        'Text("Tint+ NoRim-4 / SmartLogo NR2 • build \\(Bundle.main.object(forInfoDictionaryKey: \\"CFBundleVersion\\") as? String ?? \\"?\\")")',
        1,
    )

ui_path.write_text(ui, encoding="utf-8")

# Advanced Tint+ background/foreground refinement. Keep the change deliberately small:
# - threshold 0.72 -> 0.75;
# - remove only tiny isolated foreground components (<128 pixels at 1024x1024).
# We do NOT change LayerAwareForegroundDetector globally, so Smart Logo / Photos / Settings
# segmentation behaviour elsewhere remains untouched.
advanced_path = Path("OpaqueIconThemer/OutlineFreeAdvancedTintProcessor.swift")
advanced = advanced_path.read_text(encoding="utf-8")

old_detect = '''        var detected = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            detected[i] = locked[i] >= 0.72 ? 1 : 0
        }

        var silhouette = erodeBinaryMask(detected, width: width, height: height, radius: 2)
'''
new_detect = '''        var detected = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            // Slightly stricter than NoRim-4. This only affects the FINAL advanced Tint+
            // silhouette and helps background-coloured fragments stay background.
            detected[i] = locked[i] >= 0.75 ? 1 : 0
        }

        // Remove only tiny isolated false-positive islands. Real disconnected logo pieces are
        // normally orders of magnitude larger than this at 1024px, so their geometry is kept.
        detected = removeTinyComponents(
            detected,
            width: width,
            height: height,
            minimumSize: 128
        )

        var silhouette = erodeBinaryMask(detected, width: width, height: height, radius: 2)
'''
if old_detect not in advanced:
    raise SystemExit("Tint+ background refinement failed: detected silhouette marker not found")
advanced = advanced.replace(old_detect, new_detect, 1)

helper_marker = '''    // MARK: - Geometry / filters

    private func erodeBinaryMask(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
'''
helper_replacement = '''    // MARK: - Geometry / filters

    private func removeTinyComponents(
        _ input: [CGFloat],
        width: Int,
        height: Int,
        minimumSize: Int
    ) -> [CGFloat] {
        guard input.count == width * height, minimumSize > 1 else { return input }

        let count = input.count
        var output = input
        var visited = [Bool](repeating: false, count: count)
        var queue = [Int]()
        queue.reserveCapacity(2048)
        var component = [Int]()
        component.reserveCapacity(2048)

        for start in 0..<count {
            guard input[start] > 0.5, !visited[start] else { continue }

            queue.removeAll(keepingCapacity: true)
            component.removeAll(keepingCapacity: true)
            queue.append(start)
            visited[start] = true
            var head = 0

            while head < queue.count {
                let index = queue[head]
                head += 1
                component.append(index)

                let x = index % width
                let y = index / width

                if x > 0 {
                    let n = index - 1
                    if input[n] > 0.5, !visited[n] {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if x + 1 < width {
                    let n = index + 1
                    if input[n] > 0.5, !visited[n] {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if y > 0 {
                    let n = index - width
                    if input[n] > 0.5, !visited[n] {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if y + 1 < height {
                    let n = index + width
                    if input[n] > 0.5, !visited[n] {
                        visited[n] = true
                        queue.append(n)
                    }
                }
            }

            if component.count < minimumSize {
                for index in component {
                    output[index] = 0
                }
            }
        }

        return output
    }

    private func erodeBinaryMask(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
'''
if helper_marker not in advanced:
    raise SystemExit("Tint+ background refinement failed: geometry helper marker not found")
advanced = advanced.replace(helper_marker, helper_replacement, 1)

advanced_path.write_text(advanced, encoding="utf-8")

# CI verification: fail loudly if the final runtime is not the refined one.
ui_check = ui_path.read_text(encoding="utf-8")
advanced_check = advanced_path.read_text(encoding="utf-8")
required = [
    ("SmartLogoNoRimProcessorV2.shared.apply(", ui_check),
    ("rendered: depthAdjusted", ui_check),
    ("locked[i] >= 0.75", advanced_check),
    ("minimumSize: 128", advanced_check),
    ("private func removeTinyComponents", advanced_check),
]
for token, haystack in required:
    if token not in haystack:
        raise SystemExit(f"Smart Logo v2 / Tint+ refinement verification failed: {token}")

print("Smart Logo NR2 strict material path wired; Tint+ foreground refined slightly without global detector changes")
