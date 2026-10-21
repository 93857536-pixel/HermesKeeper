import Foundation

/// Reads hermes agent activity.
///
/// Signals, in order of reliability (verified on this machine):
///  * `~/.hermes/state.db` mtime — hermes persists every turn/tool call, so the
///    mtime is refreshed continuously while work is happening. This is the
///    primary "is it working right now" signal.
///  * `~/.hermes/gateway_state.json` `active_agents` — the in-flight turn count.
///    Only persisted at turn boundaries (can be stale for a long-running turn),
///    so it is an *additional* signal, not the only one.
///  * gateway pid liveness (`kill(pid,0)`) + `gateway_state == "running"`.
struct HermesState {
    var gatewayAlive = false
    var activeAgents = 0
    var lastActivityAt: Date? = nil     // state.db mtime
    var sinceActivity: TimeInterval = .infinity
    var dbActiveRecently = false

    /// Actively working: a turn is in flight, or hermes persisted activity
    /// within the activity window.
    var busy: Bool { gatewayAlive && (activeAgents > 0 || dbActiveRecently) }
}

final class HermesStateReader {
    var hermesHome: String?
    var activityWindow: TimeInterval

    init(hermesHome: String? = nil, activityWindow: TimeInterval? = nil) {
        self.hermesHome = hermesHome
        if let w = activityWindow {
            self.activityWindow = w
        } else if let raw = ProcessInfo.processInfo.environment["HERMES_KEEPER_ACTIVITY"],
                  let w = TimeInterval(raw) {
            self.activityWindow = w
        } else {
            self.activityWindow = 90
        }
    }

    func read() -> HermesState {
        var s = HermesState()
        let home = hermesHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".hermes")

        // 1) gateway liveness + in-flight turns
        let statePath = (home as NSString).appendingPathComponent("gateway_state.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let n = obj["active_agents"] as? Int {
                s.activeAgents = max(0, n)
            } else if let d = obj["active_agents"] as? Double {
                s.activeAgents = max(0, Int(d))
            }
            let running = (obj["gateway_state"] as? String) == "running"
            if let pid = obj["pid"] as? Int, pid > 0 {
                s.gatewayAlive = running && (kill(pid_t(pid), 0) == 0)
            }
        }

        // 2) last activity = state.db mtime
        let dbPath = (home as NSString).appendingPathComponent("state.db")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let mtime = attrs[.modificationDate] as? Date {
            s.lastActivityAt = mtime
            let age = -mtime.timeIntervalSinceNow
            s.sinceActivity = age
            s.dbActiveRecently = age < activityWindow
        }
        return s
    }
}
