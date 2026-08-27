from pathlib import Path

# Final Apple Mono rim cleanup. Earlier passes removed explicit bevel/drop-shadow strokes,
# but two subtler sources could still leave a gray/blue rim on simple logos:
# 1) the base Mono renderer used a gray->white luminance ramp inside the glyph;
# 2) background-strengthening could still classify antialiased glyph edge pixels as background.
# Keep the body white/gradient exactly as intended and reserve darkness for INTERNAL depth only.

renderer_path = Path("OpaqueIconThemer/ReferenceAppleMonotoneRenderer.swift")
renderer = renderer_path.read_text(encoding="utf-8")

old_ramp = '''        let monoShadow = RGB(r: 0.72, g: 0.72, b: 0.72)\n        let monoHighlight = RGB(r: 1.00, g: 1.00, b: 1.00)\n'''
new_ramp = '''        // The base Apple Mono body has no gray silhouette ramp. Keep the entire untinted\n        // foreground surface white; any darker values must come later from internal cavities,\n        // overlap/contact shadows and optional logo-gradient colouring — never from the outer edge.\n        let monoShadow = RGB(r: 1.00, g: 1.00, b: 1.00)\n        let monoHighlight = RGB(r: 1.00, g: 1.00, b: 1.00)\n'''
if old_ramp not in renderer:
    raise SystemExit("true-no-rim patch: Mono ramp marker not found")
renderer = renderer.replace(old_ramp, new_ramp, 1)
renderer_path.write_text(renderer, encoding="utf-8")

background_path = Path("OpaqueIconThemer/BackgroundIntensityProcessor.swift")
background = background_path.read_text(encoding="utf-8")

old_guard = '''        guard let sourcePixels = rgbaPixels(from: source, width: width, height: height),\n              let renderedPixels = rgbaPixels(from: rendered, width: width, height: height) else {\n            return rendered\n        }\n\n        let references = borderReferences(pixels: sourcePixels, width: width, height: height)\n'''
new_guard = '''        guard let sourcePixels = rgbaPixels(from: source, width: width, height: height),\n              let renderedPixels = rgbaPixels(from: rendered, width: width, height: height) else {\n            return rendered\n        }\n\n        // Exclude even soft/antialiased foreground coverage from the background colour pull.\n        // Otherwise those edge pixels get darkened once as background and then lightened once\n        // as logo, which is exactly the visible gray halo/rim on simple marks such as Hiddify.\n        let foregroundMask = LayerAwareForegroundDetector.shared.foregroundMask(\n            source: source,\n            width: width,\n            height: height\n        ) ?? [CGFloat](repeating: 0, count: width * height)\n\n        let references = borderReferences(pixels: sourcePixels, width: width, height: height)\n'''
if old_guard not in background:
    raise SystemExit("true-no-rim patch: BackgroundIntensity guard marker not found")
background = background.replace(old_guard, new_guard, 1)

old_confidence = '''                let backgroundConfidence = 1 - smoothstep(\n                    edge0: threshold * 0.38,\n                    edge1: max(threshold * 1.85, threshold + 0.055),\n                    value: distance\n                )\n\n                guard backgroundConfidence > 0.001 else {\n'''
new_confidence = '''                let rawBackgroundConfidence = 1 - smoothstep(\n                    edge0: threshold * 0.38,\n                    edge1: max(threshold * 1.85, threshold + 0.055),\n                    value: distance\n                )\n                let foregroundCoverage = clamp(foregroundMask[i], 0, 1)\n                let edgeExclusion = smoothstep(\n                    edge0: 0.015,\n                    edge1: 0.20,\n                    value: foregroundCoverage\n                )\n                let backgroundConfidence = rawBackgroundConfidence * (1 - edgeExclusion)\n\n                guard backgroundConfidence > 0.001 else {\n'''
if old_confidence not in background:
    raise SystemExit("true-no-rim patch: backgroundConfidence marker not found")
background = background.replace(old_confidence, new_confidence, 1)
background_path.write_text(background, encoding="utf-8")

# The previous clean-edge pass intentionally boosted soft coverage by 1.45x. That can itself
# look like a thin light/gray halo on high-contrast backgrounds. With the base ramp fixed above,
# use the detector's true antialias coverage instead of expanding the silhouette.
depth_path = Path("OpaqueIconThemer/AppleMonoDepthProcessor.swift")
depth = depth_path.read_text(encoding="utf-8")
old_coverage = '''                let cleanFillCoverage = clamp(logo * 1.45, 0, 1)\n                result = mix(result, white, amount: cleanFillCoverage)\n'''
new_coverage = '''                let cleanFillCoverage = clamp(logo, 0, 1)\n                result = mix(result, white, amount: cleanFillCoverage)\n'''
if old_coverage not in depth:
    raise SystemExit("true-no-rim patch: boosted cleanFillCoverage marker not found")
depth = depth.replace(old_coverage, new_coverage, 1)
depth_path.write_text(depth, encoding="utf-8")

print("Apple Mono true no-rim cleanup applied: white base, protected AA edge, no mask expansion")
