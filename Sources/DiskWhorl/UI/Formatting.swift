import Foundation

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = .useAll
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let lock = NSLock()

    static func string(_ bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func exact(_ bytes: Int64) -> String {
        "\(max(0, bytes).formatted()) bytes"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes) min \(rest) s"
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "–" }
        let value = Double(part) / Double(whole) * 100
        return value < 0.1 && part > 0 ? "<0.1%" : String(format: "%.1f%%", value)
    }
}
