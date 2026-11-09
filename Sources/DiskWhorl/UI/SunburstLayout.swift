import AppKit

/// One arc of the map.
struct SunburstSegment {
    /// nil for the aggregated "smaller items" arc of a folder.
    let node: FSNode?
    let parent: FSNode
    let ring: Int
    let startAngle: CGFloat
    let endAngle: CGFloat
    let color: NSColor
    let aggregateCount: Int
    let aggregateBytes: Int64

    var bytes: Int64 { node?.physicalSize ?? aggregateBytes }

    func contains(angle: CGFloat) -> Bool { angle >= startAngle && angle < endAngle }
}

/// Ring radii for a given view size. Rings narrow slightly toward the rim, so the
/// inner levels, which matter most, get the most room.
struct SunburstGeometry {
    let center: CGPoint
    let holeRadius: CGFloat
    let inner: [CGFloat]
    let outer: [CGFloat]

    var ringCount: Int { inner.count }
    var outerRadius: CGFloat { outer.last ?? holeRadius }

    init(bounds: CGRect, rings: Int) {
        center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(60, min(bounds.width, bounds.height) / 2 - 18)
        holeRadius = radius * 0.19
        let decay: CGFloat = 0.87
        var weights: [CGFloat] = []
        var weight: CGFloat = 1
        for _ in 0..<max(1, rings) {
            weights.append(weight)
            weight *= decay
        }
        let unit = (radius - holeRadius) / weights.reduce(0, +)
        var cursor = holeRadius
        var inner: [CGFloat] = []
        var outer: [CGFloat] = []
        for w in weights {
            inner.append(cursor)
            cursor += w * unit
            outer.append(cursor)
        }
        self.inner = inner
        self.outer = outer
    }

    /// Smallest arc worth drawing: about one point of arc length at the ring's middle.
    func minimumAngle(ring: Int) -> CGFloat {
        let middle = (inner[ring] + outer[ring]) / 2
        return 1.1 / max(middle, 1)
    }

    func ring(atRadius radius: CGFloat) -> Int? {
        for index in 0..<ringCount where radius >= inner[index] && radius < outer[index] {
            return index
        }
        return nil
    }

    /// Angle measured clockwise from 12 o'clock, in [0, 2π).
    func angle(of point: CGPoint) -> CGFloat {
        var a = atan2(point.x - center.x, point.y - center.y)
        if a < 0 { a += 2 * .pi }
        return a
    }

    func distance(of point: CGPoint) -> CGFloat {
        hypot(point.x - center.x, point.y - center.y)
    }

    /// Annular sector path. Angles are clockwise from 12 o'clock; the view is not flipped.
    func path(ring: Int, start: CGFloat, end: CGFloat, inset: CGFloat = 0.6) -> CGPath {
        let r1 = inner[ring] + inset
        let r2 = outer[ring] - inset
        let span = min(end - start, 2 * .pi - 0.0001)
        let a1 = CGFloat.pi / 2 - start
        let a2 = CGFloat.pi / 2 - (start + span)
        let path = CGMutablePath()
        path.addArc(center: center, radius: r2, startAngle: a1, endAngle: a2, clockwise: true)
        path.addArc(center: center, radius: r1, startAngle: a2, endAngle: a1, clockwise: false)
        path.closeSubpath()
        return path
    }
}

enum SunburstLayout {
    /// Lays out `center`'s descendants into rings. Arcs too thin to see are merged into a
    /// single light-gray "smaller items" arc per folder.
    static func build(center: FSNode, geometry: SunburstGeometry) -> [[SunburstSegment]] {
        var rings = Array(repeating: [SunburstSegment](), count: geometry.ringCount)
        guard center.physicalSize > 0, geometry.ringCount > 0 else { return rings }
        let fullCircle: CGFloat = 2 * .pi

        func visit(_ node: FSNode, ring: Int, start: CGFloat, end: CGFloat) {
            guard ring < geometry.ringCount, node.physicalSize > 0 else { return }
            let span = end - start
            let total = CGFloat(node.physicalSize)
            let minimum = geometry.minimumAngle(ring: ring)
            var angle = start
            var index = 0
            let children = node.children
            while index < children.count {
                let child = children[index]
                if child.physicalSize <= 0 { break }
                let width = span * CGFloat(child.physicalSize) / total
                if width < minimum { break }
                let fraction = (angle + width / 2) / fullCircle
                rings[ring].append(SunburstSegment(
                    node: child, parent: node, ring: ring,
                    startAngle: angle, endAngle: angle + width,
                    color: Palette.color(for: child, fraction: fraction, ring: ring),
                    aggregateCount: 0, aggregateBytes: 0))
                if child.isDirectory && !child.children.isEmpty {
                    visit(child, ring: ring + 1, start: angle, end: angle + width)
                }
                angle += width
                index += 1
            }
            if index < children.count {
                var rest: Int64 = 0
                for child in children[index...] { rest += child.physicalSize }
                let width = span * CGFloat(rest) / total
                if rest > 0 && width > 0.0004 {
                    rings[ring].append(SunburstSegment(
                        node: nil, parent: node, ring: ring,
                        startAngle: angle, endAngle: min(end, angle + width),
                        color: Palette.smallerItems,
                        aggregateCount: children.count - index, aggregateBytes: rest))
                }
            }
        }

        visit(center, ring: 0, start: 0, end: fullCircle)
        return rings
    }
}
