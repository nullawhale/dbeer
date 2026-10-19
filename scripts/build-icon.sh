#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
resources="$repo_root/macos/Resources"
for name in AppIcon AppIconDark; do
    iconset="$repo_root/build/$name.iconset"
    mkdir -p "$iconset" "$repo_root/build/.cache/clang"

    swift -module-cache-path "$repo_root/build/.cache/clang" - "$resources" "$iconset" "$name" <<'SWIFT'
import AppKit

let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = URL(fileURLWithPath: CommandLine.arguments[2])
let name = CommandLine.arguments[3]
guard let image = NSImage(contentsOf: resources.appendingPathComponent("\(name).svg")) else {
    fatalError("Cannot read \(name).svg")
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if pixels == 1024 {
            try png.write(to: resources.appendingPathComponent("\(name).png"))
        }
    }
}
SWIFT

    iconutil --convert icns --output "$resources/$name.icns" "$iconset"
    printf 'Built %s\n' "$resources/$name.icns"
done
