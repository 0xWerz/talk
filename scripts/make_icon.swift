#!/usr/bin/env swift
// Renders Talk's app icon: the same waveform as the menu bar and the pill,
// white on the coral the app uses for "listening".
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./Talk.iconset"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

/// Bar heights as a fraction of the icon's inner box, centre-weighted.
let bars: [CGFloat] = [0.30, 0.56, 0.86, 0.62, 0.38]

func render(size: Int) -> Data? {
    let side = CGFloat(size)
    let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
        let inset = side * 0.085
        let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = box.width * 0.225

        let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 1.00, green: 0.55, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.36, blue: 0.33, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.26, blue: 0.52, alpha: 1)
        ])!
        gradient.draw(in: squircle, angle: -62)

        // Inner highlight, so the icon has a little depth at large sizes.
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let rim = NSBezierPath(
            roundedRect: box.insetBy(dx: side * 0.012, dy: side * 0.012),
            xRadius: radius, yRadius: radius
        )
        rim.lineWidth = max(1, side * 0.008)
        rim.stroke()

        let barWidth = box.width * 0.088
        let spacing = box.width * 0.055
        let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        var x = box.midX - totalWidth / 2

        for fraction in bars {
            let height = box.height * fraction
            let bar = CGRect(x: x, y: box.midY - height / 2, width: barWidth, height: height)
            NSColor.white.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + spacing
        }
        return true
    }

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    bitmap.size = CGSize(width: side, height: side)
    return bitmap.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = render(size: size) else { continue }
    let scale1 = "\(outputDirectory)/icon_\(size)x\(size).png"
    try? data.write(to: URL(fileURLWithPath: scale1))
    // The @2x slot of the next size down shares the same pixels.
    if size >= 32 {
        let half = size / 2
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/icon_\(half)x\(half)@2x.png"))
    }
}
print("wrote iconset to \(outputDirectory)")
