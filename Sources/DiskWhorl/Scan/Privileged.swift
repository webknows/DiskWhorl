import Foundation

/// Runs commands as root after the standard macOS administrator authentication dialog.
///
/// Implemented through `osascript … with administrator privileges`, which needs no
/// installed helper daemon and no code-signing identity, so the app works when built
/// locally. Every privileged action is a single, explicit command the user just requested.
enum Privileged {

    enum PrivilegeError: LocalizedError {
        case cancelled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Administrator authentication was cancelled."
            case .failed(let message): return message
            }
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Blocking. Call from a background thread. Returns the command's standard output.
    @discardableResult
    static func run(_ shellCommand: String, prompt: String) throws -> String {
        let script = "do shell script \(appleScriptLiteral(shellCommand)) with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled") {
                throw PrivilegeError.cancelled
            }
            throw PrivilegeError.failed(message.isEmpty ? "The administrator command failed." : message)
        }
        return output
    }

    /// Runs a command as the current user and returns (status, stdout, stderr).
    static func runUnprivileged(_ executable: String, _ arguments: [String]) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }
}

/// The administrator scan runs this same executable as root with `--helper-scan`.
/// It writes progress to a small text file and the finished tree to a binary file,
/// both pre-created by the app in the user's temporary folder.
enum HelperMain {

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--helper-scan") else { return false }

        func value(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard let root = value("--root"), let out = value("--out") else {
            FileHandle.standardError.write(Data("missing --root or --out\n".utf8))
            exit(2)
        }
        let name = value("--name") ?? root
        let mode = ScanMode(rawValue: value("--mode") ?? "plain") ?? .plain
        let threads = Int(value("--threads") ?? "") ?? ScanEngine.recommendedThreads(forPath: root)
        let progressPath = value("--progress")
        let cancelPath = value("--cancel")

        let progress = ScanProgress()
        let reporter = Thread {
            while true {
                if let cancelPath, FileManager.default.fileExists(atPath: cancelPath) {
                    progress.cancel()
                }
                if let progressPath {
                    let s = progress.snapshot()
                    let text = "\(s.files)\t\(s.folders)\t\(s.bytes)\t\(s.unreadable)\n\(s.currentPath)"
                    try? text.write(toFile: progressPath, atomically: false, encoding: .utf8)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        reporter.start()

        let request = ScanRequest(rootPath: root, rootName: name, mode: mode, threads: threads)
        guard let tree = ScanEngine.run(request, progress: progress) else {
            FileHandle.standardError.write(Data("could not open \(root)\n".utf8))
            exit(3)
        }
        if progress.isCancelled { exit(4) }
        do {
            try TreeCodec.write(tree, to: URL(fileURLWithPath: out))
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error.localizedDescription)\n".utf8))
            exit(5)
        }
        exit(0)
    }

    /// Parses the helper's progress file.
    static func readProgress(at path: String) -> ScanProgress.Snapshot? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let numbers = first.split(separator: "\t")
        guard numbers.count >= 4 else { return nil }
        var snapshot = ScanProgress.Snapshot()
        snapshot.files = Int(numbers[0]) ?? 0
        snapshot.folders = Int(numbers[1]) ?? 0
        snapshot.bytes = Int64(numbers[2]) ?? 0
        snapshot.unreadable = Int(numbers[3]) ?? 0
        snapshot.currentPath = lines.count > 1 ? String(lines[1]) : ""
        return snapshot
    }
}
