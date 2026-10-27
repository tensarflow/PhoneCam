import Foundation

enum PhoneState: Equatable {
    case none
    case unauthorized
    case ready(serial: String, model: String)
}

struct ADBError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin wrapper around the `adb` command-line tool.
enum ADB {
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = ProcessInfo.processInfo.environment[variable] {
                candidates.insert("\(root)/platform-tools/adb", at: 0)
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    @discardableResult
    static func run(_ adb: URL, _ arguments: [String], timeout: TimeInterval = 20) throws -> String {
        let process = Process()
        process.executableURL = adb
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0 else {
            throw ADBError(message: "adb \(arguments.first ?? "") failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    /// Picks the first USB-connected phone, preferring one that has authorized this Mac.
    static func deviceState(adb: URL) -> PhoneState {
        guard let output = try? run(adb, ["devices", "-l"], timeout: 10) else { return .none }
        var sawUnauthorized = false
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            switch fields[1] {
            case "device":
                let model = fields.first { $0.hasPrefix("model:") }
                    .map { $0.dropFirst("model:".count).replacingOccurrences(of: "_", with: " ") } ?? String(fields[0])
                return .ready(serial: String(fields[0]), model: model)
            case "unauthorized":
                sawUnauthorized = true
            default:
                continue
            }
        }
        return sawUnauthorized ? .unauthorized : .none
    }
}
