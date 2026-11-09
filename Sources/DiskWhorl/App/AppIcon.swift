import AppKit

/// Draws the application icon (a small sunburst on a dark tile). The build script calls
/// the executable with `--render-iconset <dir>` to produce the .icns; when the bundle has
/// no icon file the app sets the same drawing as its Dock icon at launch.
enum AppIcon {

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let inset = rect.width * 0.1
        let tile = rect.insetBy(dx: inset, dy: inset)
        let corner = tile.width * 0.225
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
        let gradient = NSGradient(colors: [
            NSColor(calibratedHue: 0.62, saturation: 0.50, brightness: 0.30, alpha: 1),
            NSColor(calibratedHue: 0.66, saturation: 0.62, brightness: 0.13, alpha: 1)
        ])
        gradient?.draw(in: tilePath, angle: -90)

        let center = CGPoint(x: tile.midX, y: tile.midY)
        let radius = tile.width * 0.42
        let hole = radius * 0.24
        let ringWidths: [CGFloat] = [0.30, 0.26, 0.20]
        var radii: [(CGFloat, CGFloat)] = []
        var cursor = hole
        let unit = (radius - hole) / ringWidths.reduce(0, +)
        for width in ringWidths {
            radii.append((cursor, cursor + width * unit))
            cursor += width * unit
        }

        let shares: [CGFloat] = [0.31, 0.22, 0.16, 0.12, 0.10, 0.09]
        var start: CGFloat = 0
        let separator = NSColor(calibratedHue: 0.66, saturation: 0.62, brightness: 0.13, alpha: 1).cgColor
        context.setLineWidth(max(0.5, rect.width / 256))
        for (index, share) in shares.enumerated() {
            let span = share * 2 * .pi
            let fraction = (start + span / 2) / (2 * .pi)
            sector(context, center, radii[0], start, start + span, Palette.folder(fraction: fraction, ring: 0), separator)
            // Second ring: sub-folders and a file.
            let subShares: [CGFloat] = index % 2 == 0 ? [0.52, 0.30, 0.12] : [0.62, 0.24]
            var subStart = start
            for (subIndex, subShare) in subShares.enumerated() {
                let subSpan = span * subShare
                let subFraction = (subStart + subSpan / 2) / (2 * .pi)
                let isFile = subIndex == subShares.count - 1 && subShares.count == 3
                let color = isFile ? Palette.file(ring: 1) : Palette.folder(fraction: subFraction, ring: 1)
                sector(context, center, radii[1], subStart, subStart + subSpan, color, separator)
                if subIndex == 0 {
                    let deepSpan = subSpan * 0.7
                    let deepFraction = (subStart + deepSpan / 2) / (2 * .pi)
                    sector(context, center, radii[2], subStart, subStart + deepSpan,
                           Palette.folder(fraction: deepFraction, ring: 2), separator)
                }
                subStart += subSpan
            }
            start += span
        }

        let holeRect = CGRect(x: center.x - hole + 1, y: center.y - hole + 1, width: hole * 2 - 2, height: hole * 2 - 2)
        context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor)
        context.fillEllipse(in: holeRect)
    }

    private static func sector(_ context: CGContext, _ center: CGPoint, _ radii: (CGFloat, CGFloat),
                               _ start: CGFloat, _ end: CGFloat, _ color: NSColor, _ separator: CGColor) {
        let path = CGMutablePath()
        let a1 = CGFloat.pi / 2 - start
        let a2 = CGFloat.pi / 2 - end
        path.addArc(center: center, radius: radii.1, startAngle: a1, endAngle: a2, clockwise: true)
        path.addArc(center: center, radius: radii.0, startAngle: a2, endAngle: a1, clockwise: false)
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(separator)
        context.strokePath()
    }

    /// `DiskWhorl --render-iconset <folder>` writes the PNGs iconutil expects.
    static func renderIconSetIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-iconset"), index + 1 < args.count else { return false }
        let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let variants: [(Int, String)] = [
            (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
            (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
            (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")
        ]
        for (pixels, name) in variants {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent(name + ".png"))
            }
        }
        return true
    }
}
