import Foundation

/// Compact binary serialisation of a scanned tree. Used to hand the result of a
/// privileged (administrator) scan from the root helper process back to the app.
enum TreeCodec {
    enum CodecError: LocalizedError {
        case badMagic, truncated
        var errorDescription: String? {
            switch self {
            case .badMagic: return "The scan result file is not in the expected format."
            case .truncated: return "The scan result file is incomplete."
            }
        }
    }

    private static let magic: [UInt8] = Array("DBT1".utf8)

    // MARK: Writing

    static func write(_ root: FSNode, to url: URL) throws {
        var out = Data()
        out.reserveCapacity(1 << 20)
        out.append(contentsOf: magic)
        var stack: [FSNode] = [root]
        while let node = stack.popLast() {
            append(node, to: &out)
            for child in node.children.reversed() { stack.append(child) }
        }
        try out.write(to: url)
    }

    private static func append(_ node: FSNode, to out: inout Data) {
        out.append(node.kind.rawValue)
        out.append(node.flags.rawValue)
        appendString(node.name, to: &out)
        appendString(node.pathOverride ?? "", to: &out)
        appendString(node.displayName ?? "", to: &out)
        appendInteger(node.physicalSize, to: &out)
        appendInteger(node.logicalSize, to: &out)
        appendInteger(Int64(node.fileCount), to: &out)
        appendInteger(node.fileID, to: &out)
        appendInteger(UInt32(node.children.count), to: &out)
    }

    private static func appendString(_ string: String, to out: inout Data) {
        let bytes = Array(string.utf8)
        appendInteger(UInt16(min(bytes.count, Int(UInt16.max))), to: &out)
        out.append(contentsOf: bytes.prefix(Int(UInt16.max)))
    }

    private static func appendInteger<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { out.append(contentsOf: $0) }
    }

    // MARK: Reading

    static func read(from url: URL) throws -> FSNode {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> FSNode in
            var reader = Reader(raw: raw)
            guard raw.count >= 4, Array(raw.prefix(4)) == magic else { throw CodecError.badMagic }
            reader.offset = 4

            let (root, rootChildCount) = try reader.node()
            var stack: [(node: FSNode, remaining: Int)] = []
            if rootChildCount > 0 {
                root.children.reserveCapacity(rootChildCount)
                stack.append((root, rootChildCount))
            }
            while !stack.isEmpty {
                if stack[stack.count - 1].remaining == 0 {
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].remaining -= 1
                let parent = stack[stack.count - 1].node
                let (child, childCount) = try reader.node()
                child.parent = parent
                parent.children.append(child)
                if childCount > 0 {
                    child.children.reserveCapacity(childCount)
                    stack.append((child, childCount))
                }
            }
            return root
        }
    }

    private struct Reader {
        let raw: UnsafeRawBufferPointer
        var offset = 0

        mutating func byte() throws -> UInt8 {
            guard offset + 1 <= raw.count else { throw CodecError.truncated }
            defer { offset += 1 }
            return raw[offset]
        }

        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= raw.count else { throw CodecError.truncated }
            let value = raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            offset += size
            return T(littleEndian: value)
        }

        mutating func string() throws -> String {
            let length = Int(try integer(UInt16.self))
            guard offset + length <= raw.count else { throw CodecError.truncated }
            let slice = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + length)])
            offset += length
            return String(decoding: slice, as: UTF8.self)
        }

        mutating func node() throws -> (FSNode, Int) {
            let kind = FSNode.Kind(rawValue: try byte()) ?? .file
            let flags = FSNode.Flags(rawValue: try byte())
            let name = try string()
            let override = try string()
            let display = try string()
            let node = FSNode(name: name, kind: kind)
            node.flags = flags
            node.pathOverride = override.isEmpty ? nil : override
            node.displayName = display.isEmpty ? nil : display
            node.physicalSize = try integer(Int64.self)
            node.logicalSize = try integer(Int64.self)
            node.fileCount = Int(try integer(Int64.self))
            node.fileID = try integer(UInt64.self)
            let childCount = Int(try integer(UInt32.self))
            return (node, childCount)
        }
    }
}
