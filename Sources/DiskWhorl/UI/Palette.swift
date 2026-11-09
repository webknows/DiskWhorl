import AppKit
import SwiftUI

/// Colour coding shared by the map, the contents list and the legend.
///
/// Folders take their hue from their angular position around the map, so every branch
/// keeps one family of colour from the centre outward; deeper rings are lighter and less
/// saturated. Files are gray. Space that is not a file has its own neutral tones.
enum Palette {
    /// Rotates the colour wheel so the largest items (which start at 12 o'clock) are blue.
    private static let hueOffset: CGFloat = 0.56

    static func folder(fraction: CGFloat, ring: Int) -> NSColor {
        var hue = (fraction + hueOffset).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        let saturation = max(0.26, 0.68 - CGFloat(ring) * 0.065)
        let brightness = min(0.97, 0.80 + CGFloat(ring) * 0.028)
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    static func file(ring: Int) -> NSColor {
        NSColor(calibratedWhite: min(0.80, 0.60 + CGFloat(ring) * 0.03), alpha: 1)
    }

    static let smallerItems = NSColor(calibratedWhite: 0.86, alpha: 0.85)
    static let hiddenSpace = NSColor(calibratedWhite: 0.34, alpha: 1)
    static let purgeable = NSColor(calibratedHue: 0.74, saturation: 0.26, brightness: 0.74, alpha: 1)
    static let freeSpace = NSColor(calibratedHue: 0.38, saturation: 0.35, brightness: 0.78, alpha: 1)

    static func color(for node: FSNode, fraction: CGFloat, ring: Int) -> NSColor {
        switch node.kind {
        case .directory: return folder(fraction: fraction, ring: ring)
        case .hiddenSpace: return hiddenSpace
        case .purgeable: return purgeable
        case .file, .symlink, .special: return file(ring: ring)
        }
    }

    /// Colours for the immediate children of `parent`, matching the first ring of the map.
    static func childColors(of parent: FSNode, limit: Int) -> [ObjectIdentifier: Color] {
        var result: [ObjectIdentifier: Color] = [:]
        let total = CGFloat(max(1, parent.physicalSize))
        var cumulative: CGFloat = 0
        for child in parent.children.prefix(limit) {
            let share = CGFloat(child.physicalSize) / total
            let fraction = cumulative + share / 2
            result[child.id] = Color(nsColor: color(for: child, fraction: fraction, ring: 0))
            cumulative += share
        }
        return result
    }

    static func highlighted(_ color: NSColor) -> NSColor {
        color.blended(withFraction: 0.35, of: .white) ?? color
    }
}
