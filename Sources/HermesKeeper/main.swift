import AppKit
import Foundation

// HermesKeeper — menu-bar app that keeps the Mac awake while hermes agent is
// busy, gives a grace window after work ends, then auto-sleeps if the user
// hasn't come back.
//
// Headless state-machine test:
//   HermesKeeper --selftest [seconds]
// Honors env overrides: HERMES_KEEPER_HOME / _GRACE / _POLL / _PRESENCE /
// _DRYRUN=1 / _LOGFILE.

let args = CommandLine.arguments

if args.contains("--selftest") {
    var seconds: Double = 60
    if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count,
       let s = Double(args[i + 1]) {
        seconds = s
    }
    let engine = KeeperEngine()
    let started = Date()
    engine.onTick = { snap in
        let t = String(format: "%.0f", Date().timeIntervalSince(started))
        let grace = Int(snap.graceRemaining)
        print("t=\(t)s phase=\(snap.phase.rawValue) busy=\(snap.hermesBusy) agents=\(snap.activeAgents) blocked=\(snap.sleepBlocked) present=\(snap.userPresent) lidClosed=\(snap.lidClosed) idle=\(snap.idleSeconds)s graceLeft=\(grace)s | \(snap.message)")
        fflush(stdout)
    }
    engine.start()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    engine.stop()
    print("[selftest] finished after \(Int(seconds))s")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only (no Dock icon); LSUIElement in Info.plist mirrors this.
app.setActivationPolicy(.accessory)
app.run()
