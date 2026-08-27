from pathlib import Path

path = Path("OpaqueIconThemer/AppleMonoDepthProcessor.swift")
text = path.read_text(encoding="utf-8")

old_support = '''        // Depth must never create a stroke around the OUTER logo silhouette. Build an
        // interior-only support mask: internal petals/gears/overlaps keep their relief, while
        // the outer 2–4 px transition remains a clean white body edge.
        let interiorSupport = boxBlur(logoMask, width: width, height: height, radius: 3).map { value in
            clamp((value - 0.78) / 0.20, 0, 1)
        }
'''
new_support = '''        // Depth/shadow is allowed only well INSIDE the foreground. A blur-based support mask
        // still leaks into the silhouette edge and creates the gray rim visible on simple marks.
        // A minimum filter behaves like a real erosion: if any nearby sample belongs to the
        // background, this pixel is excluded from every darkening/depth pass.
        let interiorSupport = erodeMask(
            logoMask,
            width: width,
            height: height,
            radius: 5
        ).map { value in
            smoothstep(edge0: 0.55, edge1: 0.92, value: value)
        }
'''
if old_support not in text:
    raise SystemExit("interiorSupport marker not found; clean-edge patch must run first")
text = text.replace(old_support, new_support, 1)

old_fill = '''                let cleanFillCoverage = clamp(logo, 0, 1)
                result = mix(result, white, amount: cleanFillCoverage)
'''
new_fill = '''                // The body is white. Saturate the detector's soft AA coverage quickly enough
                // that the old gray base ramp cannot remain visible as a rim, while keeping the
                // last fractional edge pixels antialiased against the blue background.
                let cleanFillCoverage = smoothstep(
                    edge0: 0.012,
                    edge1: 0.42,
                    value: clamp(logo, 0, 1)
                )
                result = mix(result, white, amount: cleanFillCoverage)
'''
if old_fill not in text:
    raise SystemExit("cleanFillCoverage marker not found; true-no-rim patch must run first")
text = text.replace(old_fill, new_fill, 1)

marker = '''    // MARK: - Fast image math

    private func boxBlur(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
'''
replacement = '''    // MARK: - Fast image math

    private func erodeMask(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
        guard radius > 0, input.count == width * height else { return input }
        var output = [CGFloat](repeating: 0, count: input.count)

        for y in 0..<height {
            for x in 0..<width {
                var minimum: CGFloat = 1
                let y0 = max(0, y - radius)
                let y1 = min(height - 1, y + radius)
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)

                for yy in y0...y1 {
                    let row = yy * width
                    for xx in x0...x1 {
                        minimum = min(minimum, input[row + xx])
                        if minimum <= 0.001 { break }
                    }
                    if minimum <= 0.001 { break }
                }
                output[y * width + x] = minimum
            }
        }
        return output
    }

    private func boxBlur(_ input: [CGFloat], width: Int, height: Int, radius: Int) -> [CGFloat] {
'''
if marker not in text:
    raise SystemExit("Fast image math marker not found")
text = text.replace(marker, replacement, 1)

path.write_text(text, encoding="utf-8")
print("Apple Mono shadows/depth restricted to eroded interior; outer white edge cleaned")
