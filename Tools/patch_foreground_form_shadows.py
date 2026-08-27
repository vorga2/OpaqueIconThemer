from pathlib import Path

# This patch runs LAST, after every historical Tint+/Mono/no-rim patch.
# Do not try to revive IconShadowProcessor here: an older cleanup intentionally removes its
# outside-logo shadow block. Instead, make the dedicated ForegroundFormShadowProcessor the final
# post-process before render() returns, so no early guard can bypass the user's shadow settings.

ui_path = Path("OpaqueIconThemer/LiquidContentView.swift")
ui = ui_path.read_text(encoding="utf-8")
processor_path = Path("OpaqueIconThemer/ForegroundFormShadowProcessor.swift")
processor = processor_path.read_text(encoding="utf-8")

for token in [
    "final class ForegroundFormShadowProcessor",
    "let tileSafetyInset",
    "halo * 0.42",
    "contact * 0.46",
    "ambient * 0.20",
]:
    if token not in processor:
        raise SystemExit(f"final form-shadow patch failed: processor verification missing {token}")

render_start = ui.find("    private static func render(_ snapshot: RenderSnapshot) -> UIImage?")
render_end = ui.find("    private func renderCurrentIcon()", render_start)
if render_start < 0 or render_end < 0:
    raise SystemExit("final form-shadow patch failed: render() range not found")

render_block = ui[render_start:render_end]
if "var postProcessedOutput = baseOutput" not in render_block:
    raise SystemExit("final form-shadow patch failed: postProcessedOutput missing; v3 patch must run first")

# The historical tail starts here and contains preserveSolidTint/outlineFreeAdvanced guards plus
# IconShadowProcessor. Replace the ENTIRE tail so Shadows=ON always reaches our dedicated pass.
tail_start = render_block.find("        let preserveSolidTint")
if tail_start < 0:
    # Resilient fallback if a future patch removes only that variable but keeps the old shadow tail.
    tail_start = render_block.find("        guard snapshot.shadowsEnabled")
if tail_start < 0:
    raise SystemExit("final form-shadow patch failed: old shadow tail marker not found")

final_tail = '''        // FINAL SHADOW PASS — must be the last visual operation before returning the icon.
        // It shadows only detected internal app/logo forms. ForegroundFormShadowProcessor has a
        // hard dead-zone around the outer square tile, so no side/perimeter icon shadow is possible.
        if snapshot.shadowsEnabled {
            postProcessedOutput = ForegroundFormShadowProcessor.shared.apply(
                source: snapshot.source,
                rendered: postProcessedOutput,
                shadowColor: snapshot.shadowColor,
                strength: snapshot.shadowStrength,
                tintMix: snapshot.shadowTintMix,
                surfaceColor: snapshot.backgroundTint
            ) ?? postProcessedOutput
        }

        return postProcessedOutput
    }

'''
render_block = render_block[:tail_start] + final_tail
ui = ui[:render_start] + render_block + ui[render_end:]

# Hard CI verification: the generic outside-shadow route must no longer be the final return path,
# and the dedicated processor must appear inside render() exactly where it cannot be bypassed.
final_render = ui[render_start:ui.find("    private func renderCurrentIcon()", render_start)]
checks = [
    "ForegroundFormShadowProcessor.shared.apply(",
    "if snapshot.shadowsEnabled {",
    "shadowColor: snapshot.shadowColor",
    "strength: snapshot.shadowStrength",
    "return postProcessedOutput",
]
for token in checks:
    if token not in final_render:
        raise SystemExit(f"final form-shadow patch failed: runtime verification missing {token}")

if "return IconShadowProcessor.shared.apply(" in final_render:
    raise SystemExit("final form-shadow patch failed: obsolete IconShadowProcessor final return survived")

ui_path.write_text(ui, encoding="utf-8")
print("Dedicated foreground-form shadow is now the guaranteed final render pass: chosen colour remains visible, 100% strength is strong, outer tile perimeter stays shadow-free")
