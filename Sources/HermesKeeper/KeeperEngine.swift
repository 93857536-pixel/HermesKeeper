import Foundation
import AppKit
import CoreGraphics

/// Configuration for HermesKeeper, persisted to
/// `~/Library/Application Support/HermesKeeper/config.json`.
struct KeeperConfig: Codable {
    var hermesHome: String?          // nil = ~/.hermes
    var graceSeconds: Int            // default 300 (5 min)
    var pollInterval: TimeInterval   // default 10
    var userPresenceWindow: TimeInterval // seconds of no-input that counts as "user present"
    var autoSleepOnGraceExpiry: Bool   // default true
    var forceSleepWhenIdle: Bool       // default false — override system idle-sleep when hermes idle

    static let `default` = KeeperConfig(
        hermesHome: nil,
        graceSeconds: 300,
        pollInterval: 10,
        userPresenceWindow: 60,
        autoSleepOnGraceExpiry: true,
        forceSleepWhenIdle: false
    )

    var hermesHomeResolved: String {
        hermesHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".hermes")
    }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HermesKeeper", isDirectory: true)
    }
    static var configURL: URL { supportDir.appendingPathComponent("config.json") }

    static func load() -> KeeperConfig {
        var c: KeeperConfig = .default
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(KeeperConfig.self, from: data) {
            c = decoded
        }
        // Env overrides (used by --selftest and for quick debugging; never
        // written back to disk).
        let env = ProcessInfo.processInfo.environment
        if let h = env["HERMES_KEEPER_HOME"], !h.isEmpty { c.hermesHome = h }
        if let g = env["HERMES_KEEPER_GRACE"], let n = Int(g) { c.graceSeconds = n }
        if let p = env["HERMES_KEEPER_POLL"], let d = Double(p) { c.pollInterval = d }
        if let w = env["HERMES_KEEPER_PRESENCE"], let d = Double(w) { c.userPresenceWindow = d }
        return c
    }

    func save() {
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Self.configURL)
        }
    }
}

/// The three phases HermesKeeper can be in.
enum Phase: String {
    case idle          // hermes not busy, grace not active, no sleep block
    case keepingAwake  // hermes busy -> hard-block sleep (even lid-closed)
    case grace         // hermes just finished, 5-min window still blocked
}

/// A snapshot of everything the UI wants to display.
struct EngineSnapshot {
    var phase: Phase = .idle
    var hermesBusy: Bool = false
    var activeAgents: Int = 0
    var lastBusyAt: Date? = nil
    var graceRemaining: TimeInterval = 0
    var userPresent: Bool = false
    var sleepBlocked: Bool = false
    var lidClosed: Bool = false
    var idleSeconds: Int = 0
    var message: String = ""
}

/// The heart of HermesKeeper: polls hermes, runs the state machine, and
/// controls the sleep flag. All mutations happen on the timer's queue and
/// are handed to the UI via `onTick`.
final class KeeperEngine {
    private let controller = SleepController()
    private var reader = HermesStateReader()
    private var timer: Timer?
    private var config: KeeperConfig

    private(set) var snapshot = EngineSnapshot()
    /// True once auto-sleep fired for the current idle stretch; reset when busy.
    private var autoSleepFired = false

    var onTick: ((EngineSnapshot) -> Void)?

    init(config: KeeperConfig = .load()) {
        self.config = config
        self.reader = HermesStateReader(hermesHome: config.hermesHomeResolved)
    }

    // MARK: - Lifecycle

    private let workQueue = DispatchQueue(label: "HermesKeeper.engine", qos: .utility)

    func start() {
        // Crash-recovery: if a previous run left SleepDisabled=1 and hermes is
        // not busy, release it so the Mac can sleep normally.
        reconcileSleepFlag()
        log("HermesKeeper engine started (grace=\(config.graceSeconds)s poll=\(config.pollInterval)s)")
        timer?.invalidate()
        let t = Timer(timeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            self?.tickAsync()
        }
        t.tolerance = config.pollInterval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // First evaluation immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tickAsync() }
    }

    /// Timer fires on main; the real work (spawning pmset/ioreg/sudo) happens
    /// off-main so the UI never stalls. All engine state is mutated on workQueue
    /// only; publishing hops back to main.
    private func tickAsync() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.doTick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Always release on shutdown: this process is going away and can no
        // longer manage the flag. Leaving SleepDisabled=1 would make the Mac
        // unable to sleep ever. The next launch re-asserts it if needed.
        if controller.sleepDisabled() {
            controller.setSleepDisabled(false)
        }
        log("HermesKeeper engine stopped (sleep block released)")
    }

    // MARK: - The state machine

    private func doTick() {
        let h = reader.read()
        let lidClosed = controller.lidClosed()
        let idleSeconds = controller.hidIdleSeconds()
        let grace = Double(config.graceSeconds)

        // "User present" = recent HID input (works in clamshell with an
        // external keyboard) OR the lid is open (screen opened -> user is at
        // the desk; leave it to the system's own idle-sleep).
        let userPresent = (Double(idleSeconds) < config.userPresenceWindow) || (!lidClosed)

        let busyNow = h.busy
        let sinceActivity = h.sinceActivity

        var phase: Phase
        var sleepBlocked: Bool
        var message: String

        if busyNow {
            // hermes is working -> hard-block sleep (survives lid close).
            phase = .keepingAwake
            sleepBlocked = true
            message = h.activeAgents > 0
                ? "hermes 正在运行（\(h.activeAgents) 个进行中任务），保持唤醒"
                : "hermes 正在工作（检测到持续写入），保持唤醒"
        } else if sinceActivity < grace {
            // Work stopped less than <grace> ago -> keep awake for the window.
            let left = grace - sinceActivity
            snapshot.graceRemaining = left
            if userPresent {
                phase = .idle
                sleepBlocked = false
                message = "任务结束，检测到你仍在操作，交回系统睡眠策略"
            } else {
                phase = .grace
                sleepBlocked = true
                message = "任务结束 \(Int(sinceActivity))s，宽限 \(Int(left))s 内无操作将自动熄屏"
            }
        } else {
            // Grace fully elapsed.
            phase = .idle
            sleepBlocked = false
            if userPresent {
                message = "hermes 空闲，检测到你在使用电脑"
            } else if config.autoSleepOnGraceExpiry && !autoSleepFired {
                message = "宽限已过且无人操作，自动熄屏"
                triggerAutoSleep()
                autoSleepFired = true
            } else {
                message = "hermes 空闲"
            }
        }

        setSleepBlock(sleepBlocked)
        if busyNow { autoSleepFired = false }

        snapshot = EngineSnapshot(
            phase: phase,
            hermesBusy: busyNow,
            activeAgents: h.activeAgents,
            lastBusyAt: h.lastActivityAt,
            graceRemaining: snapshot.graceRemaining,
            userPresent: userPresent,
            sleepBlocked: sleepBlocked,
            lidClosed: lidClosed,
            idleSeconds: idleSeconds,
            message: message
        )
        if let cb = onTick { cb(snapshot) }
    }

    private func triggerAutoSleep() {
        log("Auto-sleep firing (grace expired, user absent)")
        // Release the block first so sleepnow isn't vetoed by SleepDisabled.
        controller.setSleepDisabled(false)
        // Small delay so the UI shows "sleeping" before the machine goes dark.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
            controller.sleepNow()
        }
    }

    // MARK: - Explicit user actions (menu)
    // These hop onto workQueue so they never race doTick() over shared state.

    func keepAwakeNow() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.log("User: keep screen awake now")
            self.setSleepBlock(true)
        }
    }

    func releaseSleepBlock() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.log("User: release sleep block")
            self.setSleepBlock(false)
            self.autoSleepFired = true
        }
    }

    func sleepNow() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.log("User: sleep now")
            self.controller.setSleepDisabled(false)
            self.controller.sleepNow()
        }
    }

    /// Re-read current SleepDisabled and only call sudo when it actually differs.
    private func setSleepBlock(_ on: Bool) {
        let current = controller.sleepDisabled()
        if current == on { return }
        controller.setSleepDisabled(on)
        log("Sleep block -> \(on ? "ON" : "OFF")")
    }

    /// Safety: on launch/crash-recovery, make the flag match hermes's real state.
    private func reconcileSleepFlag() {
        let h = reader.read()
        if !h.busy && controller.sleepDisabled() {
            log("Recovery: releasing stale SleepDisabled (hermes not busy)")
            controller.setSleepDisabled(false)
        } else if h.busy && !controller.sleepDisabled() {
            log("Recovery: re-asserting SleepDisabled (hermes busy)")
            controller.setSleepDisabled(true)
        }
    }

    // MARK: - Logging

    func logLine(_ msg: String) {
        log(msg)
    }

    private func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) [HermesKeeper] \(msg)\n"
        let url: URL
        if let override = ProcessInfo.processInfo.environment["HERMES_KEEPER_LOGFILE"],
           !override.isEmpty {
            url = URL(fileURLWithPath: override)
        } else {
            url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Logs/HermesKeeper.log")
        }
        // best-effort append (create parent dir if missing)
        try? FileManager.default.createDirectory(
            atPath: url.deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        // keep the log bounded (~200KB)
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            if size > 200_000 {
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let tail = content.split(separator: "\n", omittingEmptySubsequences: true).suffix(400).joined(separator: "\n")
                try? tail.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
