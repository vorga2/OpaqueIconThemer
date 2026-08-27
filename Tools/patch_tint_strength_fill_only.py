from pathlib import Path

# Tint+ halo fix.
#
# Root cause: advanced Tint+ was tinting the full bitmap once in renderTintedBitmap(), then
# tinting foreground/background a second time in CombinedTintIntensityProcessor. That first pass
# also colours antialias/fringe/shadow pixels, so increasing "Сила тинта" can create a blue rim.
# Keep the base bitmap neutral and let the layer-aware combined pass own the tint completely.

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")

old = '''        } else {
            guard let base = renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.iconTint,
                intensity: snapshot.tintIntensity
            ) else { return nil }

            baseOutput = CombinedTintIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                backgroundTint: snapshot.backgroundTint,
                iconTint: snapshot.iconTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                iconIntensity: snapshot.tintIntensity
            ) ?? base
        }
'''

new = '''        } else {
            // Tint+ must not pre-tint the whole bitmap. A whole-image tint colours the soft
            // antialias/fringe and any baked shadow before the layer mask is applied, which turns
            // "Сила тинта" into a visible coloured halo around simple logos. Build a neutral,
            // fully-opaque base first; the layer-aware combined pass below is the ONLY place where
            // background/icon tint strength is applied.
            guard let base = renderer.renderTintedBitmap(
                source: snapshot.source,
                tint: snapshot.iconTint,
                intensity: 0.0
            ) else { return nil }

            baseOutput = CombinedTintIntensityProcessor.shared.apply(
                source: snapshot.source,
                rendered: base,
                backgroundTint: snapshot.backgroundTint,
                iconTint: snapshot.iconTint,
                backgroundIntensity: snapshot.backgroundIntensity,
                iconIntensity: snapshot.tintIntensity
            ) ?? base
        }
'''

if old not in ui:
    raise SystemExit("Tint+ render block not found")
ui = ui.replace(old, new, 1)
ui_path.write_text(ui, encoding="utf-8")

# The optional Tint+ shadow pass used to cast a blurred shadow OUTSIDE the logo silhouette. On a
# pale background this reads as the same blue/gray rim the user is reporting, especially when the
# logo tint gets stronger. Keep depth inside the artwork only: inner bevel/highlight remain, but no
# outside/contact glow is painted around the logo.
shadow_path = Path("OpaqueIconThemer/IconShadowProcessor.swift")
shadow = shadow_path.read_text(encoding="utf-8")

old_shadow = '''                // Drop/contact shadow belongs only to the detected foreground logo. The background
                // itself is never darkened at the image borders or side edges.
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
                let outside = 1 - logo
                let logoDrop = outside * amount * (contact * 0.30 + ambient * 0.12)
                if logoDrop > 0.0001 {
                    result = mix(result, effectiveShadowLinear, amount: clamp(logoDrop, 0, 0.48))
                }

'''

new_shadow = '''                // No outside drop/glow for Tint+. Depth is restricted to pixels inside the
                // detected logo. This prevents a coloured rim from appearing as tint strength rises.
                // Internal lower/right bevel and upper/left highlight below are intentionally kept.

'''

if old_shadow not in shadow:
    raise SystemExit("IconShadowProcessor outside-shadow block not found")
shadow = shadow.replace(old_shadow, new_shadow, 1)

# Remove now-unused outside-shadow blur/offset calculations so the compiler stays clean and the
# processor does less work per generated icon.
shadow = shadow.replace('''        let contactBlur = boxBlur(
            logoMask,
            width: width,
            height: height,
            radius: max(1, Int((4.0 * designScale).rounded()))
        )
        let ambientBlur = boxBlur(
            logoMask,
            width: width,
            height: height,
            radius: max(1, Int((10.0 * designScale).rounded()))
        )
''', '', 1)
shadow = shadow.replace('''        let contactOffset = max(1, Int((2.0 * designScale).rounded()))
        let ambientOffset = max(1, Int((5.0 * designScale).rounded()))
''', '', 1)

shadow_path.write_text(shadow, encoding="utf-8")
print("Tint+ strength now affects layer fill only; outside logo shadow/glow removed")
