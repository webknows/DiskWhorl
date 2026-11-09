import AppKit
import SwiftUI

/// Callbacks from the map to the app.
struct SunburstActions {
    var quickLook: (FSNode) -> Void
    var reveal: (FSNode) -> Void
    var collect: (FSNode) -> Void
    var copyPath: (FSNode) -> Void
}

/// The interactive sunburst ("daisy") map, drawn with Core Graphics so it stays sharp on
/// Retina displays and responsive with thousands of arcs.
final class SunburstNSView: NSView, NSDraggingSource {

    weak var scan: ScanSession?
    var actions: SunburstActions?

    private var centerNode: FSNode?
    private var revision = -1
    private var ringCount = 7
    private var externalHighlight: FSNode?
    private var selectedNode: FSNode?

    private var geometry: SunburstGeometry?
    private var rings: [[SunburstSegment]] = []
    private var paths: [[CGPath]] = []
    private var builtSize: CGSize = .zero

    private var hoverIndex: (ring: Int, index: Int)?
    private var hoverOnCenter = false
    private var mouseLocation: CGPoint?
    private var mouseDownLocation: CGPoint?
    private var mouseDownIndex: (ring: Int, index: Int)?
    private var mouseDownOnCenter = false
    private var dragStarted = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: Updates from SwiftUI

    func update(center: FSNode?, revision: Int, rings: Int, highlight: FSNode?, selected: FSNode?) {
        var needsRebuild = false
        if center !== centerNode || revision != self.revision || rings != ringCount {
            centerNode = center
            self.revision = revision
            ringCount = rings
            needsRebuild = true
        }
        if needsRebuild {
            rebuild()
        }
        if highlight !== externalHighlight || selected !== selectedNode {
            externalHighlight = highlight
            selectedNode = selected
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize != builtSize { rebuild() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func rebuild() {
        builtSize = bounds.size
        hoverIndex = nil
        guard let centerNode, bounds.width > 40, bounds.height > 40 else {
            geometry = nil
            rings = []
            paths = []
            needsDisplay = true
            return
        }
        let geo = SunburstGeometry(bounds: bounds, rings: ringCount)
        geometry = geo
        rings = SunburstLayout.build(center: centerNode, geometry: geo)
        paths = rings.map { ring in
            ring.map { geo.path(ring: $0.ring, start: $0.startAngle, end: $0.endAngle) }
        }
        if let location = mouseLocation { updateHover(at: location, notify: true) }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let geometry, let centerNode else {
            drawPlaceholder()
            return
        }

        let separator = NSColor.windowBackgroundColor.cgColor
        let highlight = currentHighlightNode()
        context.setLineWidth(0.75)
        context.setLineJoin(.round)

        for (ringIndex, ring) in rings.enumerated() {
            for (index, segment) in ring.enumerated() {
                let path = paths[ringIndex][index]
                var color = segment.color
                let isHovered = hoverIndex.map { $0.ring == ringIndex && $0.index == index } ?? false
                if isHovered {
                    color = Palette.highlighted(color)
                } else if let highlight, let node = segment.node, node.isSelfOrDescendant(of: highlight) {
                    color = Palette.highlighted(color)
                } else if let highlight, segment.node == nil, segment.parent.isSelfOrDescendant(of: highlight) {
                    color = Palette.highlighted(color)
                }
                context.addPath(path)
                context.setFillColor(color.cgColor)
                context.fillPath()
                context.addPath(path)
                context.setStrokeColor(separator)
                context.strokePath()
            }
        }

        // Selection outline.
        if let selectedNode {
            for (ringIndex, ring) in rings.enumerated() {
                if let index = ring.firstIndex(where: { $0.node === selectedNode }) {
                    context.addPath(paths[ringIndex][index])
                    context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                    context.setLineWidth(2.5)
                    context.strokePath()
                    break
                }
            }
        }

        drawCenter(context: context, geometry: geometry, node: centerNode)
        drawTooltip()
    }

    private func drawPlaceholder() {
        let text = "No data to display" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawCenter(context: CGContext, geometry: SunburstGeometry, node: FSNode) {
        let radius = geometry.holeRadius - 2
        let circle = CGRect(x: geometry.center.x - radius, y: geometry.center.y - radius, width: radius * 2, height: radius * 2)
        let fill = hoverOnCenter && node.parent != nil
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.controlBackgroundColor
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: circle)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: circle)

        var lines: [(String, NSFont, NSColor)] = []
        let maxWidth = radius * 1.7
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .bold)
        let captionFont = NSFont.systemFont(ofSize: 11)
        lines.append((truncate(node.title, width: maxWidth, font: titleFont), titleFont, NSColor.labelColor))
        if node.isScanRoot, let accounting = scan?.accounting {
            lines.append((ByteFormat.string(accounting.used) + " used", sizeFont, NSColor.labelColor))
            lines.append((ByteFormat.string(accounting.free) + " free", captionFont, NSColor.secondaryLabelColor))
        } else {
            lines.append((ByteFormat.string(node.physicalSize), sizeFont, NSColor.labelColor))
            lines.append(("\(node.fileCount.formatted()) files", captionFont, NSColor.secondaryLabelColor))
        }
        if node.parent != nil {
            lines.append(("▲ click to go up", NSFont.systemFont(ofSize: 9.5), NSColor.tertiaryLabelColor))
        }

        let rendered = lines.map { line -> (NSString, [NSAttributedString.Key: Any], CGSize) in
            let attributes: [NSAttributedString.Key: Any] = [.font: line.1, .foregroundColor: line.2]
            let string = line.0 as NSString
            return (string, attributes, string.size(withAttributes: attributes))
        }
        let totalHeight = rendered.reduce(0) { $0 + $1.2.height } + CGFloat(max(0, rendered.count - 1)) * 2
        var y = geometry.center.y + totalHeight / 2
        for item in rendered {
            y -= item.2.height
            item.0.draw(at: CGPoint(x: geometry.center.x - item.2.width / 2, y: y), withAttributes: item.1)
            y -= 2
        }
    }

    private func drawTooltip() {
        guard let location = mouseLocation, let geometry else { return }
        var title: String
        var detail: String
        var path: String?
        if hoverOnCenter, let centerNode {
            title = centerNode.title
            detail = ByteFormat.string(centerNode.physicalSize)
            path = centerNode.isPseudo ? nil : centerNode.path
        } else if let hit = hoverIndex {
            let segment = rings[hit.ring][hit.index]
            let parentSize = max(1, segment.parent.physicalSize)
            let percent = Double(segment.bytes) / Double(parentSize) * 100
            let percentText = percent >= 0.1 ? String(format: " · %.1f%% of %@", percent, segment.parent.title) : ""
            if let node = segment.node {
                title = node.title
                detail = ByteFormat.string(node.physicalSize) + percentText
                if node.isDirectory { detail += " · \(node.fileCount.formatted()) files" }
                path = node.isPseudo ? (node.kind == .hiddenSpace ? "Click to investigate snapshots and system data" : "Click to review purgeable space") : node.path
            } else {
                title = "\(segment.aggregateCount.formatted()) smaller items"
                detail = ByteFormat.string(segment.aggregateBytes) + percentText
                path = segment.parent.path
            }
        } else {
            return
        }
        _ = geometry

        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let detailAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let pathAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        let maxWidth: CGFloat = 420
        title = truncate(title, width: maxWidth, font: titleAttributes[.font] as! NSFont)
        detail = truncate(detail, width: maxWidth, font: detailAttributes[.font] as! NSFont)
        let pathText = path.map { truncateMiddle($0, width: maxWidth, font: pathAttributes[.font] as! NSFont) }

        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let detailSize = (detail as NSString).size(withAttributes: detailAttributes)
        let pathSize = pathText.map { ($0 as NSString).size(withAttributes: pathAttributes) } ?? .zero
        let width = max(titleSize.width, detailSize.width, pathSize.width) + 16
        let height = titleSize.height + detailSize.height + (pathText == nil ? 0 : pathSize.height + 2) + 12

        var origin = CGPoint(x: location.x + 16, y: location.y - height - 12)
        if origin.x + width > bounds.maxX - 4 { origin.x = location.x - width - 16 }
        if origin.y < bounds.minY + 4 { origin.y = location.y + 16 }
        origin.x = max(bounds.minX + 4, origin.x)
        let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))

        let background = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.lineWidth = 1
        background.stroke()

        var y = rect.maxY - 6 - titleSize.height
        (title as NSString).draw(at: CGPoint(x: rect.minX + 8, y: y), withAttributes: titleAttributes)
        y -= detailSize.height
        (detail as NSString).draw(at: CGPoint(x: rect.minX + 8, y: y), withAttributes: detailAttributes)
        if let pathText {
            y -= pathSize.height + 2
            (pathText as NSString).draw(at: CGPoint(x: rect.minX + 8, y: y), withAttributes: pathAttributes)
        }
    }

    private func truncate(_ text: String, width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= width { return text }
        var characters = Array(text)
        while characters.count > 1 {
            characters.removeLast()
            let candidate = String(characters) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width { return candidate }
        }
        return "…"
    }

    private func truncateMiddle(_ text: String, width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= width { return text }
        let characters = Array(text)
        var keep = characters.count
        while keep > 4 {
            keep -= max(1, keep / 12)
            let head = characters.prefix(keep / 2)
            let tail = characters.suffix(keep - keep / 2)
            let candidate = String(head) + "…" + String(tail)
            if (candidate as NSString).size(withAttributes: attributes).width <= width { return candidate }
        }
        return "…"
    }

    // MARK: Hit testing

    private func hit(at point: CGPoint) -> (onCenter: Bool, index: (ring: Int, index: Int)?) {
        guard let geometry else { return (false, nil) }
        let distance = geometry.distance(of: point)
        if distance < geometry.holeRadius { return (true, nil) }
        guard let ring = geometry.ring(atRadius: distance), ring < rings.count else { return (false, nil) }
        let angle = geometry.angle(of: point)
        let segments = rings[ring]
        // Segments in a ring are produced in angular order: binary search.
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let segment = segments[mid]
            if angle < segment.startAngle { high = mid - 1 }
            else if angle >= segment.endAngle { low = mid + 1 }
            else { return (false, (ring, mid)) }
        }
        return (false, nil)
    }

    private func segmentNode(at index: (ring: Int, index: Int)?) -> FSNode? {
        guard let index, index.ring < rings.count, index.index < rings[index.ring].count else { return nil }
        return rings[index.ring][index.index].node
    }

    private func currentHighlightNode() -> FSNode? {
        if hoverIndex != nil { return segmentNode(at: hoverIndex) }
        if hoverOnCenter { return nil }
        return externalHighlight
    }

    private func updateHover(at point: CGPoint, notify: Bool) {
        let result = hit(at: point)
        let changed = result.onCenter != hoverOnCenter
            || result.index?.ring != hoverIndex?.ring || result.index?.index != hoverIndex?.index
        hoverOnCenter = result.onCenter
        hoverIndex = result.index
        if changed && notify {
            scan?.hover(segmentNode(at: result.index))
        }
        needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point
        updateHover(at: point, notify: true)
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        hoverIndex = nil
        hoverOnCenter = false
        scan?.hover(nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let result = hit(at: point)
        mouseDownLocation = point
        mouseDownIndex = result.index
        mouseDownOnCenter = result.onCenter
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = mouseDownLocation, let node = segmentNode(at: mouseDownIndex), !node.isPseudo else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 5 else { return }
        dragStarted = true

        let item = NSDraggingItem(pasteboardWriter: node.path as NSString)
        let image = dragImage(for: node)
        item.setDraggingFrame(NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height),
                              contents: image)
        scan?.beginDrag([node])
        _ = beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            mouseDownIndex = nil
            mouseDownOnCenter = false
        }
        guard !dragStarted, let scan else { return }
        let point = convert(event.locationInWindow, from: nil)
        let result = hit(at: point)

        if result.onCenter && mouseDownOnCenter {
            scan.goUp()
            return
        }
        guard let index = result.index, let down = mouseDownIndex,
              index.ring == down.ring, index.index == down.index else { return }
        let segment = rings[index.ring][index.index]
        guard let node = segment.node else {
            // "Smaller items": open their folder.
            scan.drill(into: segment.parent)
            return
        }
        if event.clickCount >= 2, !node.isDirectory {
            actions?.quickLook(node)
            return
        }
        if node.isDirectory || node.isPseudo {
            scan.drill(into: node)
        } else {
            scan.select(node)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let result = hit(at: point)
        let target: FSNode? = result.onCenter ? centerNode : segmentNode(at: result.index)
        guard let target, !target.isPseudo else { return }
        scan?.select(target)
        let menu = contextMenu(for: target)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func contextMenu(for node: FSNode) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ selector: Selector, symbol: String) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = node
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return menuItem
        }
        if node.isDirectory && node !== centerNode {
            menu.addItem(item("Open", #selector(menuOpen(_:)), symbol: "arrow.down.right.circle"))
        }
        menu.addItem(item("Quick Look", #selector(menuQuickLook(_:)), symbol: "eye"))
        menu.addItem(item("Reveal in Finder", #selector(menuReveal(_:)), symbol: "folder"))
        menu.addItem(item("Copy Path", #selector(menuCopyPath(_:)), symbol: "doc.on.doc"))
        menu.addItem(.separator())
        menu.addItem(item("Add to Collector", #selector(menuCollect(_:)), symbol: "tray.and.arrow.down"))
        return menu
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FSNode { scan?.drill(into: node) }
    }
    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FSNode { actions?.quickLook(node) }
    }
    @objc private func menuReveal(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FSNode { actions?.reveal(node) }
    }
    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FSNode { actions?.copyPath(node) }
    }
    @objc private func menuCollect(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? FSNode { actions?.collect(node) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let scan else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            if let node = scan.selected ?? scan.hovered { actions?.collect(node) }
        case 53, 123: // escape, left arrow
            scan.goUp()
        case 36, 76, 124: // return, enter, right arrow
            if let node = scan.selected, node.isDirectory { scan.drill(into: node) }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Dragging source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.scan?.endDrag()
        }
    }

    private func dragImage(for node: FSNode) -> NSImage {
        let title = node.title as NSString
        let size = ByteFormat.string(node.physicalSize) as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let sizeAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let titleSize = title.size(withAttributes: titleAttributes)
        let sizeSize = size.size(withAttributes: sizeAttributes)
        let width = min(320, max(titleSize.width, sizeSize.width) + 44)
        let height: CGFloat = 40
        let icon = NSWorkspace.shared.icon(forFile: node.path)
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            background.fill()
            NSColor.separatorColor.setStroke()
            background.stroke()
            icon.draw(in: NSRect(x: 6, y: 6, width: 28, height: 28))
            title.draw(at: NSPoint(x: 38, y: 20), withAttributes: titleAttributes)
            size.draw(at: NSPoint(x: 38, y: 5), withAttributes: sizeAttributes)
            return true
        }
    }
}

/// SwiftUI wrapper.
struct SunburstMap: NSViewRepresentable {
    @ObservedObject var session: ScanSession
    let actions: SunburstActions
    @AppStorage("ringCount") private var ringCount = 7

    func makeNSView(context: Context) -> SunburstNSView {
        let view = SunburstNSView()
        view.scan = session
        view.actions = actions
        return view
    }

    func updateNSView(_ view: SunburstNSView, context: Context) {
        view.scan = session
        view.actions = actions
        view.update(center: session.center,
                    revision: session.revision,
                    rings: max(3, min(12, ringCount)),
                    highlight: session.hovered,
                    selected: session.selected)
    }
}
