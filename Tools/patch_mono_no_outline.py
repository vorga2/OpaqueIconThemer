from pathlib import Path

# Apple Mono depth: keep internal layer separation, but remove any bevel that follows
# the OUTER silhouette of the logo. The user wants the logo body clean white, with
# depth only inside the artwork — no gray stroke/rim around Discord/Hiddify/etc.
depth_path = Path("OpaqueIconThemer/AppleMonoDepthProcessor.swift")
depth = depth_path.read_text(encoding="utf-8")

old_soft_logo = '''        let chromaMean = boxBlur(chroma, width: width, height: height, radius: 8)\n        let softLogo = boxBlur(logoMask, width: width, height: height, radius: 4)\n'''
new_soft_logo = '''        let chromaMean = boxBlur(chroma, width: width, height: height, radius: 8)\n'''
if old_soft_logo not in depth:
    raise SystemExit("mono no-outline patch: softLogo marker not found")
depth = depth.replace(old_soft_logo, new_soft_logo, 1)

old_offsets = '''        let layerOffset = 4\n        let bevelOffset = 3\n        let white = RGB(r: 1, g: 1, b: 1)\n'''
new_offsets = '''        let layerOffset = 4\n        let white = RGB(r: 1, g: 1, b: 1)\n'''
if old_offsets not in depth:
    raise SystemExit("mono no-outline patch: bevelOffset marker not found")
depth = depth.replace(old_offsets, new_offsets, 1)

old_bevel = '''                // Directional bevel only on the foreground shape. No tile-perimeter shading.\n                let maskTopLeft = sample(\n                    softLogo,\n                    width: width,\n                    height: height,\n                    x: x - bevelOffset,\n                    y: y - bevelOffset\n                )\n                let maskBottomRight = sample(\n                    softLogo,\n                    width: width,\n                    height: height,\n                    x: x + bevelOffset,\n                    y: y + bevelOffset\n                )\n                let topLeftEdge = clamp(logo * (1 - maskTopLeft), 0, 1)\n                let bottomRightEdge = clamp(logo * (1 - maskBottomRight), 0, 1)\n\n                if topLeftEdge > 0.001 {\n                    result = screen(\n                        result,\n                        white,\n                        amount: clamp(topLeftEdge * 0.20 * amount, 0, 0.16)\n                    )\n                }\n                if bottomRightEdge > 0.001 {\n                    result = mix(\n                        result,\n                        depthShadow,\n                        amount: clamp(bottomRightEdge * 0.13 * amount, 0, 0.11)\n                    )\n                }\n\n'''
new_bevel = '''                // Intentionally NO outer-silhouette bevel/stroke here.\n                // Internal contact shadows, cavities and overlap highlights above preserve depth,\n                // but the outside edge of the white logo stays clean instead of getting a gray rim.\n\n'''
if old_bevel not in depth:
    raise SystemExit("mono no-outline patch: outer bevel block not found")
depth = depth.replace(old_bevel, new_bevel, 1)

depth_path.write_text(depth, encoding="utf-8")

# Liquid editor rendering: the generic IconShadowProcessor creates a drop/inner bevel
# around the whole detected logo silhouette. Disable that extra pass for Apple Mono;
# AppleMonoDepthProcessor already supplies INTERNAL depth. Keep it for advanced Tint+.
ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")
old_shadow_flag = '''            logoShadows: snapshot.resolvedMode == .smartLogo || snapshot.tintVariant == .advanced\n'''
new_shadow_flag = '''            logoShadows: snapshot.tintVariant == .advanced\n'''
if old_shadow_flag not in ui:
    raise SystemExit("mono no-outline patch: logoShadows marker not found")
ui = ui.replace(old_shadow_flag, new_shadow_flag, 1)
ui_path.write_text(ui, encoding="utf-8")

print("Apple Mono outer gray outline removed; internal depth preserved")
