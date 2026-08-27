from pathlib import Path
import re

# Final Tint+ render-path override.
# This deliberately runs LAST after every historical patch. It makes the advanced mode use the
# strict two-material compositor directly and bypasses every generic silhouette shadow/bevel pass.

path = Path("OpaqueIconThemer/LiquidContentView.swift")
text = path.read_text(encoding="utf-8")

# Force the advanced branch onto the no-outline compositor. Historical patches may have left either
# the old Combined processor or the first Advanced processor in place; normalize both.
text = text.replace(
    "AdvancedTintCompositeProcessor.shared.apply(",
    "OutlineFreeAdvancedTintProcessor.shared.apply("
)

# The no-outline compositor intentionally ignores the pre-rendered bitmap. Remove the old argument
# only from the OutlineFree call so other processors keep their signatures untouched.
pattern = re.compile(
    r"(OutlineFreeAdvancedTintProcessor\.shared\.apply\(\s*\n\s*source:\s*snapshot\.source,\s*\n)\s*rendered:\s*base,\s*\n",
    re.M,
)
text, count = pattern.subn(r"\1", text, count=1)
if count != 1:
    raise SystemExit(f"outline-free patch: advanced call signature replacements={count}")

# Advanced Tint+ must never pass through IconShadowProcessor. Even an inner bevel/highlight on the
# silhouette is perceived as an outline and also changes with colour. Preserve the shadow UI for
# other modes, but return the advanced result directly.
old_guard = """        guard snapshot.shadowsEnabled && !preserveSolidTint else {
            return baseOutput
        }
"""
new_guard = """        let outlineFreeAdvanced = snapshot.resolvedMode == .tint && snapshot.tintVariant == .advanced
        guard snapshot.shadowsEnabled && !preserveSolidTint && !outlineFreeAdvanced else {
            return baseOutput
        }
"""
if old_guard in text:
    text = text.replace(old_guard, new_guard, 1)
elif "let outlineFreeAdvanced = snapshot.resolvedMode == .tint" not in text:
    raise SystemExit("outline-free patch: shadow guard marker not found")

# Put the actual installed build number on screen. NoRim-3 means strict binary geometry: there is no
# generated AA ring in the bitmap itself; tint/gradient/background intensity cannot widen the logo.
marker = """                    Text(colorDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
"""
replacement = marker + """

                    if resolvedMode == .tint && tintVariant == .advanced {
                        Text("Tint+ NoRim-3 • build \\(Bundle.main.object(forInfoDictionaryKey: \"CFBundleVersion\") as? String ?? \"?\")")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
"""
if marker in text and "Tint+ NoRim-3" not in text:
    text = text.replace(marker, replacement, 1)

path.write_text(text, encoding="utf-8")
print("Forced OutlineFreeAdvancedTintProcessor NoRim-3, bypassed Tint+ silhouette shadows, added build marker")
