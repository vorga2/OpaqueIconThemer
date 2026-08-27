from pathlib import Path

path = Path("OpaqueIconThemer/AppleMonoDepthProcessor.swift")
text = path.read_text(encoding="utf-8")

old_blurs = '''        let lumaSmall = boxBlur(luminance, width: width, height: height, radius: 4)\n        let lumaLarge = boxBlur(luminance, width: width, height: height, radius: 17)\n        let chromaMean = boxBlur(chroma, width: width, height: height, radius: 8)\n'''
new_blurs = '''        let lumaSmall = boxBlur(luminance, width: width, height: height, radius: 4)\n        let lumaLarge = boxBlur(luminance, width: width, height: height, radius: 17)\n        let chromaMean = boxBlur(chroma, width: width, height: height, radius: 8)\n\n        // Depth must never create a stroke around the OUTER logo silhouette. Build an\n        // interior-only support mask: internal petals/gears/overlaps keep their relief, while\n        // the outer 2–4 px transition remains a clean white body edge.\n        let interiorSupport = boxBlur(logoMask, width: width, height: height, radius: 3).map { value in\n            clamp((value - 0.78) / 0.20, 0, 1)\n        }\n'''
if old_blurs not in text:
    raise SystemExit("clean-edge patch: blur marker not found")
text = text.replace(old_blurs, new_blurs, 1)

old_signal = '''            let logo = clamp(logoMask[i], 0, 1)\n            guard logo > 0.001 else { continue }\n\n            let fine = luminance[i] - lumaSmall[i]\n'''
new_signal = '''            let logo = clamp(logoMask[i], 0, 1)\n            let interior = clamp(interiorSupport[i] * logo, 0, 1)\n            guard logo > 0.001 else { continue }\n\n            let fine = luminance[i] - lumaSmall[i]\n'''
if old_signal not in text:
    raise SystemExit("clean-edge patch: signal marker not found")
text = text.replace(old_signal, new_signal, 1)

text = text.replace(
    '''            raised[i] = smoothstep(edge0: 0.010, edge1: 0.105, value: raisedSignal) * logo\n''',
    '''            raised[i] = smoothstep(edge0: 0.010, edge1: 0.105, value: raisedSignal) * interior\n''',
    1,
)
text = text.replace(
    '''            cavity[i] = smoothstep(edge0: 0.010, edge1: 0.095, value: cavitySignal) * logo\n''',
    '''            cavity[i] = smoothstep(edge0: 0.010, edge1: 0.095, value: cavitySignal) * interior\n''',
    1,
)
text = text.replace(
    '''            ) * logo\n        }\n\n        let raisedBlur''',
    '''            ) * interior\n        }\n\n        let raisedBlur''',
    1,
)

old_white = '''                result = mix(result, white, amount: clamp(logo, 0, 1))\n'''
new_white = '''                // Slightly strengthen only the antialiased fill coverage. The old soft mask\n                // left a strip of the pre-Mono gray ramp visible at the silhouette, which looked\n                // like a gray outline on simple marks such as Hiddify. Shadows are added later\n                // from the interior-only masks, so this does not whiten them.\n                let cleanFillCoverage = clamp(logo * 1.45, 0, 1)\n                result = mix(result, white, amount: cleanFillCoverage)\n'''
if old_white not in text:
    raise SystemExit("clean-edge patch: white fill marker not found; ensure white-fill patch runs first")
text = text.replace(old_white, new_white, 1)

path.write_text(text, encoding="utf-8")
print("Apple Mono outer logo edge forced clean white; depth restricted to interior")
