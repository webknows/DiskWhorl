import SwiftUI
import AppKit

/// Right-hand panel: space summary, details of the hovered or selected item, the
/// contents of the current folder and the colour legend.
struct InspectorView: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if session.isVolumeScan, let accounting = session.accounting,
                   let center = session.center, center.isScanRoot {
                    SpaceSummaryCard(session: session, accounting: accounting)
                }
                if let node = session.focusNode {
                    ItemInfoCard(session: session, node: node)
                }
                if let center = session.center {
                    ContentsList(session: session, folder: center)
                }
                LegendView()
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}

// MARK: Space summary

private struct SpaceSummaryCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession
    let accounting: SpaceAccounting

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SpaceBreakdownBar(accounting: accounting)
                    .frame(height: 10)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    line(Color.accentColor, "Files found by the scan", accounting.scanned)
                    line(Color(nsColor: Palette.hiddenSpace), "Hidden space", accounting.hidden)
                    line(Color(nsColor: Palette.purgeable), "Purgeable", accounting.purgeable)
                    line(Color(nsColor: Palette.freeSpace), "Free", accounting.free)
                    Divider().gridCellColumns(3)
                    line(.clear, "Capacity", accounting.capacity)
                }
                .font(.caption)
                if accounting.movedToTrash > 0 {
                    Text("\(ByteFormat.string(accounting.movedToTrash)) moved to the Trash this session. Empty the Trash to make it free space.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if accounting.overcount > 0 {
                    Text("The scan counts \(ByteFormat.string(accounting.overcount)) more than the volume reports as used. APFS clones share storage, so copies are counted at full size.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.unreadableFolders > 0 && !session.adminMode {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "lock")
                        Text("\(session.unreadableFolders.formatted()) folders could not be read and count as hidden space.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Rescan as Administrator") { model.rescan(session, asAdministrator: true) }
                        .controlSize(.small)
                }
                Button {
                    session.showHiddenSpaceTools = true
                } label: {
                    Label("Investigate Hidden Space…", systemImage: "eye.slash")
                }
                .controlSize(.small)
            }
        } label: {
            Text("Space on \(session.title)").font(.headline)
        }
    }

    @ViewBuilder
    private func line(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        GridRow {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title)
            Text(ByteFormat.string(bytes))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct SpaceBreakdownBar: View {
    let accounting: SpaceAccounting

    var body: some View {
        GeometryReader { proxy in
            let total = Double(max(1, accounting.capacity))
            let parts: [(Color, Int64)] = [
                (Color.accentColor, min(accounting.scanned, accounting.used)),
                (Color(nsColor: Palette.hiddenSpace), accounting.hidden),
                (Color(nsColor: Palette.purgeable), accounting.purgeable),
                (Color(nsColor: Palette.freeSpace), accounting.free)
            ]
            HStack(spacing: 1) {
                ForEach(0..<parts.count, id: \.self) { index in
                    Rectangle()
                        .fill(parts[index].0)
                        .frame(width: max(0, proxy.size.width * CGFloat(Double(parts[index].1) / total) - 1))
                }
            }
            .clipShape(Capsule())
        }
    }
}

// MARK: Item details

private struct ItemInfoCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession
    let node: FSNode

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    ItemIcon(node: node, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title)
                            .font(.headline)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text(kindDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("On disk").foregroundStyle(.secondary)
                        Text(ByteFormat.string(node.physicalSize)).fontWeight(.semibold).monospacedDigit()
                    }
                    if !node.isPseudo {
                        GridRow {
                            Text("Apparent size").foregroundStyle(.secondary)
                            Text(ByteFormat.string(node.logicalSize)).monospacedDigit()
                        }
                    }
                    if node.isDirectory {
                        GridRow {
                            Text("Files").foregroundStyle(.secondary)
                            Text(node.fileCount.formatted()).monospacedDigit()
                        }
                    }
                    if let parent = node.parent {
                        GridRow {
                            Text("Share").foregroundStyle(.secondary)
                            Text("\(ByteFormat.percent(node.physicalSize, of: parent.physicalSize)) of \(parent.title)")
                                .lineLimit(1)
                        }
                    }
                }
                .font(.caption)

                if !node.isPseudo {
                    Text(node.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(badges, id: \.self) { badge in
                    Label(badge, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if node.isPseudo {
                    Text(node.kind == .hiddenSpace
                         ? "Used space that no readable file accounts for: APFS snapshots, unmounted system volumes such as Recovery, folders the scan could not read, and file-system metadata."
                         : "Space macOS can reclaim automatically when it is needed: local snapshots, evictable iCloud copies and registered caches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Investigate…") { session.showHiddenSpaceTools = true }
                        .controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Button { model.quickLook(node) } label: { Label("Quick Look", systemImage: "eye") }
                            .help("Space bar")
                        Button { model.reveal(node) } label: { Label("Reveal", systemImage: "folder") }
                        Button { session.collector.add(node) } label: { Label("Collect", systemImage: "tray.and.arrow.down") }
                            .disabled(SafetyGuard.evaluate(node).isBlocked)
                    }
                    .controlSize(.small)
                    .labelStyle(.titleAndIcon)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindDescription: String {
        switch node.kind {
        case .directory: return node.flags.contains(.package) ? "Package" : (node.isScanRoot ? "Scanned location" : "Folder")
        case .file: return "File"
        case .symlink: return "Symbolic link"
        case .special: return "Special file"
        case .hiddenSpace: return "Hidden space"
        case .purgeable: return "Purgeable space"
        }
    }

    private var badges: [String] {
        var result: [String] = []
        if node.flags.contains(.inaccessible) { result.append("Could not be read; its contents are not included.") }
        else if node.flags.contains(.partial) { result.append("Some folders inside could not be read; the size is a minimum.") }
        if node.flags.contains(.restricted) { result.append("Protected by System Integrity Protection.") }
        if node.flags.contains(.hardLinkDuplicate) { result.append("Hard link to a file counted elsewhere; not counted again.") }
        if node.flags.contains(.dataless) { result.append("Stored in the cloud only; occupies almost no local space.") }
        if case .caution(let message) = SafetyGuard.evaluate(node) { result.append(message) }
        return result
    }
}

/// Finder icon for real items, a symbol for space summaries.
struct ItemIcon: View {
    let node: FSNode
    let size: CGFloat

    var body: some View {
        if node.isPseudo {
            Image(systemName: node.kind == .hiddenSpace ? "eye.slash.circle.fill" : "arrow.3.trianglepath")
                .font(.system(size: size * 0.8))
                .foregroundStyle(Color(nsColor: node.kind == .hiddenSpace ? Palette.hiddenSpace : Palette.purgeable))
                .frame(width: size, height: size)
        } else {
            Image(nsImage: IconCache.icon(for: node.path))
                .resizable()
                .frame(width: size, height: size)
        }
    }
}

enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

// MARK: Folder contents

private struct ContentsList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession
    let folder: FSNode

    private let limit = 250

    var body: some View {
        let children = Array(folder.children.prefix(limit))
        let colors = Palette.childColors(of: folder, limit: limit)
        let hidden = folder.children.count - children.count
        let hiddenBytes = folder.children.dropFirst(limit).reduce(Int64(0)) { $0 + $1.physicalSize }

        GroupBox {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(children) { child in
                    ContentsRow(session: session, node: child, parent: folder,
                                color: colors[child.id] ?? .gray)
                }
                if hidden > 0 {
                    Text("\(hidden.formatted()) smaller items · \(ByteFormat.string(hiddenBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                if children.isEmpty {
                    Text(folder.flags.contains(.inaccessible) ? "This folder could not be read." : "This folder is empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack {
                Text("Contents of \(folder.title)").font(.headline).lineLimit(1)
                Spacer()
                Text("\(folder.children.count.formatted()) items").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ContentsRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ScanSession
    let node: FSNode
    let parent: FSNode
    let color: Color

    var body: some View {
        let isHovered = session.hovered === node
        let isSelected = session.selected === node
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color)
                .frame(width: 10, height: 10)
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                GeometryReader { proxy in
                    Capsule()
                        .fill(color.opacity(0.75))
                        .frame(width: max(1, proxy.size.width * CGFloat(share)))
                }
                .frame(height: 3)
            }
            Text(ByteFormat.string(node.physicalSize))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 62, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.07) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { session.hover(node) } else if session.hovered === node { session.hover(nil) }
        }
        .onTapGesture {
            if node.isDirectory || node.isPseudo { session.drill(into: node) } else { session.select(node) }
        }
        .onDrag {
            session.beginDrag([node])
            return NSItemProvider(object: node.path as NSString)
        }
        .contextMenu {
            if node.isDirectory {
                Button("Open") { session.drill(into: node) }
            }
            if !node.isPseudo {
                Button("Quick Look") { model.quickLook(node) }
                Button("Reveal in Finder") { model.reveal(node) }
                Button("Copy Path") { model.copyPath(node) }
                Divider()
                Button("Add to Collector") { session.collector.add(node) }
            } else {
                Button("Investigate…") { session.showHiddenSpaceTools = true }
            }
        }
        .help(node.isPseudo ? node.title : node.path)
    }

    private var share: Double {
        guard parent.physicalSize > 0 else { return 0 }
        return min(1, Double(node.physicalSize) / Double(parent.physicalSize))
    }

    private var symbol: String {
        switch node.kind {
        case .directory: return node.flags.contains(.package) ? "shippingbox" : "folder.fill"
        case .file: return "doc"
        case .symlink: return "arrow.turn.up.right"
        case .special: return "gearshape"
        case .hiddenSpace: return "eye.slash"
        case .purgeable: return "arrow.3.trianglepath"
        }
    }
}

// MARK: Legend

struct LegendView: View {
    @StateObject private var expanded = ViewState(true)

    var body: some View {
        DisclosureGroup(isExpanded: $expanded.value) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { step in
                        Rectangle()
                            .fill(Color(nsColor: Palette.folder(fraction: CGFloat(step) / 8, ring: 0)))
                            .frame(width: 12, height: 10)
                    }
                }
                entry(nil, "Folders. Hue follows position around the map, so each branch keeps one colour family; outer rings are lighter.")
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { ring in
                        Rectangle()
                            .fill(Color(nsColor: Palette.folder(fraction: 0.1, ring: ring * 2)))
                            .frame(width: 12, height: 10)
                    }
                    Text("deeper levels").font(.caption2).foregroundStyle(.secondary)
                }
                entry(Color(nsColor: Palette.file(ring: 1)), "Files")
                entry(Color(nsColor: Palette.smallerItems), "Smaller items grouped together (too thin to draw)")
                entry(Color(nsColor: Palette.hiddenSpace), "Hidden space: used, but not in any readable file")
                entry(Color(nsColor: Palette.purgeable), "Purgeable space macOS can reclaim")
                entry(Color(nsColor: Palette.freeSpace), "Free space (summary bar)")
                Text("Arc size is the space actually allocated on disk, not the apparent file size. Hover for details, click a folder to open it, click the centre to go up, drag any arc to the Collector.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            Text("Legend").font(.headline)
        }
    }

    @ViewBuilder
    private func entry(_ color: Color?, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let color {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 10)
            }
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}
