import Foundation

/// Manages auto-start via a per-user LaunchAgent (more reliable than
/// SMAppService for an ad-hoc-signed bundle living outside /Applications).
enum LaunchAgentManager {
    static let label = "com.linminhao.hermeskeeper"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var executablePath: String {
        // Inside a bundle: <App>.app/Contents/MacOS/<App>
        if let exe = Bundle.main.executablePath { return exe }
        return CommandLine.arguments[0]
    }

    @discardableResult
    static func enable() -> Bool {
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key><false/>
            </dict>
            <key>ProcessType</key><string>Interactive</string>
            <key>StandardOutPath</key><string>\(NSHomeDirectory())/Library/Logs/HermesKeeper.stdout.log</string>
            <key>StandardErrorPath</key><string>\(NSHomeDirectory())/Library/Logs/HermesKeeper.stderr.log</string>
        </dict>
        </plist>
        """
        guard (try? plist.write(to: plistURL, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        // Best-effort (re)load; ignore errors when already loaded.
        shell("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        let ok = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        if !ok {
            _ = shell("/bin/launchctl", ["load", "-w", plistURL.path])
        }
        return true
    }

    @discardableResult
    static func disable() -> Bool {
        shell("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        _ = shell("/bin/launchctl", ["unload", "-w", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        return true
    }

    private static func shell(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
