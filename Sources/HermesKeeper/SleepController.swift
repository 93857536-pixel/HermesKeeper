import Foundation

/// Wraps the power-control primitives HermesKeeper needs:
///  - `pmset -a disablesleep 1/0`  (root, via NOPASSWD sudo) — hard-blocks sleep
///    including lid-close sleep on portables. This is the only mechanism that
///    survives a clamshell on battery+no-external-display.
///  - `pmset sleepnow`             (root) — explicitly trigger sleep.
///  - IOKit `AppleClamshellState` — detect lid open/closed without root.
///
/// All `pmset` writes go through `sudo -n` (non-interactive) so a missing
/// NOPASSWD entry fails fast instead of hanging on a password prompt.
final class SleepController {
    /// Dry-run: log what we would do, never touch the real power state.
    /// Enabled by HERMES_KEEPER_DRYRUN=1 (used by --selftest).
    let dryRun: Bool
    private var simulatedSleepDisabled = false

    init(dryRun: Bool = ProcessInfo.processInfo.environment["HERMES_KEEPER_DRYRUN"] == "1") {
        self.dryRun = dryRun
    }

    /// Current value of the `SleepDisabled` flag (0/1) from `pmset -g`.
    func sleepDisabled() -> Bool {
        if dryRun { return simulatedSleepDisabled }
        let out = run(user: "pmset -g")
        return sleepDisabledFlag(in: out)
    }

    private func sleepDisabledFlag(in text: String) -> Bool {
        // Line looks like: " SleepDisabled\t\t1"  (tab-separated, trailing value 0 or 1).
        for line in text.split(whereSeparator: \.isNewline) {
            guard let idx = line.range(of: "SleepDisabled") else { continue }
            let after = line[idx.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(after) { return n == 1 }
        }
        return false
    }

    /// Set or clear the hard sleep-disable. Returns true on success.
    @discardableResult
    func setSleepDisabled(_ on: Bool) -> Bool {
        if dryRun {
            simulatedSleepDisabled = on
            return true
        }
        let args = ["-n", "pmset", "-a", "disablesleep", on ? "1" : "0"]
        _ = runSudo(args)
        // pmset prints nothing on success; verify via re-read.
        Thread.sleep(forTimeInterval: 0.3)
        if on { return sleepDisabled() }
        else { return !sleepDisabled() }
    }

    /// Trigger an immediate sleep. Root needed on portables.
    @discardableResult
    func sleepNow() -> Bool {
        if dryRun {
            print("[dry-run] pmset sleepnow")
            return true
        }
        _ = runSudo(["-n", "pmset", "sleepnow"])
        return true
    }

    /// Lid closed? IOKit reports "AppleClamshellState" = Yes/No. No root needed.
    func lidClosed() -> Bool {
        let out = run(user: "ioreg -rc IOService | grep -m1 AppleClamshellState")
        return out.contains("\"AppleClamshellState\" = Yes")
    }

    /// Seconds since the last HID input (any key/trackpad/mouse event).
    /// HIDIdleTime is nanoseconds; no root needed.
    func hidIdleSeconds() -> Int {
        let out = run(user: "ioreg -c IOHIDSystem | grep -m1 HIDIdleTime")
        guard let r = out.range(of: "\"HIDIdleTime\" = ") else { return 0 }
        let rest = out[r.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard let nanos = UInt64(digits) else { return 0 }
        return Int(nanos / 1_000_000_000)
    }

    /// Whether the machine is on AC power (battery + no display = clamp case
    /// matters more on battery; but disablesleep works regardless).
    func onACPower() -> Bool {
        let out = run(user: "pmset -g batt")
        return out.contains("AC Power")
    }

    // MARK: - Process helpers

    private func run(user command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        // Drain BEFORE waitUntilExit: a child writing more than the pipe buffer
        // (~64KB) blocks on write while we block on exit -> deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runSudo(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe // merge stderr so a NOPASSWD failure is visible
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
