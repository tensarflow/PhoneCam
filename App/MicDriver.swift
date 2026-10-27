import Foundation

/// Installs the "PhoneCam Microphone" Core Audio driver bundled in the app.
/// Core Audio only loads drivers from /Library/Audio/Plug-Ins/HAL, which needs an admin password.
enum MicDriver {
    enum State { case notInstalled, outdated, installed }

    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/PhoneCamMic.driver")
    static var bundledURL: URL? { Bundle.main.url(forResource: "PhoneCamMic", withExtension: "driver") }

    static var state: State {
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return .notInstalled }
        return version(of: installedURL) == bundledURL.flatMap(version(of:)) ? .installed : .outdated
    }

    /// Copies the driver into place and restarts Core Audio (all Mac audio pauses for a moment).
    /// Shows macOS's password prompt and blocks until it's answered; returns an error message on failure.
    static func install() -> String? {
        guard let source = bundledURL else { return "The driver is missing from PhoneCam.app" }
        let folder = installedURL.deletingLastPathComponent().path
        let command = "mkdir -p '\(folder)' && rm -rf '\(installedURL.path)' && cp -R '\(source.path)' '\(folder)/'"
            + " && killall coreaudiod"
        let script = "do shell script \"\(command)\" with administrator privileges"
            + " with prompt \"PhoneCam wants to install its microphone driver.\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return output.contains("-128") ? "Installation was cancelled" : output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func version(of bundle: URL) -> String? {
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleVersion"] as? String
    }
}
