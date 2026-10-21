import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = KeeperEngine()
    private var config: KeeperConfig
    private var menu: NSMenu!

    private var autoSleepMenuItem: NSMenuItem!
    private var forceSleepMenuItem: NSMenuItem!
    private var launchMenuItem: NSMenuItem!

    override init() {
        self.config = KeeperConfig.load()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildMenu()
        engine.onTick = { [weak self] snap in
            guard let self = self else { return }
            self.updateUI(with: snap)
        }

        engine.start()

        // Open window for debugging/GUI automation.
        if ProcessInfo.processInfo.environment["HERMES_KEEPER_OPEN_ON_LAUNCH"] == "1" {
            showSettings()
        }
    }

    // MARK: - Status item + icon

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "HermesKeeper")
            button.toolTip = "HermesKeeper"
        }
        statusItem.menu = menu
    }

    private func buildMenu() {
        menu = NSMenu()

        let header = NSMenuItem(title: "HermesKeeper · hermes 空闲", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        self.headerItem = header
        menu.addItem(.separator())

        let awake = NSMenuItem(title: "立即保持唤醒", action: #selector(keepAwakeNow), keyEquivalent: "a")
        awake.target = self
        menu.addItem(awake)

        let release = NSMenuItem(title: "解除睡眠阻止", action: #selector(releaseSleepBlock), keyEquivalent: "")
        release.target = self
        menu.addItem(release)

        let sleepNow = NSMenuItem(title: "立即睡眠", action: #selector(sleepNowAction), keyEquivalent: "")
        sleepNow.target = self
        menu.addItem(sleepNow)

        menu.addItem(.separator())

        autoSleepMenuItem = NSMenuItem(title: "任务结束后 5 分钟无操作自动熄屏", action: #selector(toggleAutoSleep), keyEquivalent: "")
        autoSleepMenuItem.target = self
        menu.addItem(autoSleepMenuItem)

        forceSleepMenuItem = NSMenuItem(title: "hermes 空闲时也强制睡眠(覆盖系统设置)", action: #selector(toggleForceSleep), keyEquivalent: "")
        forceSleepMenuItem.target = self
        menu.addItem(forceSleepMenuItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let launchAtLogin = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.target = self
        launchMenuItem = launchAtLogin
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 HermesKeeper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        refreshToggleStates()
    }

    private var headerItem: NSMenuItem!

    private func updateUI(with snap: EngineSnapshot) {
        let header: String
        switch snap.phase {
        case .keepingAwake:
            header = "HermesKeeper · hermes 运行中(\(snap.activeAgents) 任务)，保持唤醒"
        case .grace:
            let m = Int(snap.graceRemaining / 60)
            let s = Int(snap.graceRemaining) % 60
            header = "HermesKeeper · 宽限 \(m)m\(s)s 后自动熄屏"
        case .idle:
            header = snap.sleepBlocked ? "HermesKeeper · hermes 空闲，防止睡眠" : "HermesKeeper · hermes 空闲"
        }
        headerItem.title = header

        let symbol: String
        switch snap.phase {
        case .keepingAwake: symbol = "bolt.fill"
        case .grace: symbol = "timer"
        case .idle: symbol = snap.sleepBlocked ? "pause.circle" : "moon.zzz.fill"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HermesKeeper")

        // Keep menu items in sync with config.
        autoSleepMenuItem.state = (config.autoSleepOnGraceExpiry) ? .on : .off
        forceSleepMenuItem.state = (config.forceSleepWhenIdle) ? .on : .off
    }

    // MARK: - Actions

    @objc func keepAwakeNow() {
        engine.keepAwakeNow()
    }

    @objc func releaseSleepBlock() {
        engine.releaseSleepBlock()
    }

    @objc func sleepNowAction() {
        // Sleep the machine but keep the app alive (it resumes on wake and
        // keeps guarding). Releasing the block first is done inside sleepNow().
        engine.sleepNow()
    }

    @objc func toggleAutoSleep() {
        config.autoSleepOnGraceExpiry.toggle()
        config.save()
        engine.logLine("autoSleepOnGraceExpiry -> \(config.autoSleepOnGraceExpiry)")
        refreshToggleStates()
    }

    @objc func toggleForceSleep() {
        config.forceSleepWhenIdle.toggle()
        config.save()
        engine.logLine("forceSleepWhenIdle -> \(config.forceSleepWhenIdle)")
        refreshToggleStates()
    }

    @objc func toggleLaunchAtLogin() {
        if LaunchAgentManager.isEnabled {
            LaunchAgentManager.disable()
            engine.logLine("login item disabled")
        } else {
            LaunchAgentManager.enable()
            engine.logLine("login item enabled -> \(LaunchAgentManager.executablePath)")
        }
        refreshToggleStates()
    }

    private func refreshToggleStates() {
        autoSleepMenuItem.state = config.autoSleepOnGraceExpiry ? .on : .off
        forceSleepMenuItem.state = config.forceSleepWhenIdle ? .on : .off
        launchMenuItem.state = LaunchAgentManager.isEnabled ? .on : .off
    }

    @objc func quit() {
        engine.stop()
        NSApplication.shared.terminate(nil)
    }

    /// Always release the sleep block when the app goes away (Cmd-Q, SIGTERM,
    /// logout) so the Mac can never be left unable to sleep.
    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    @objc func showSettings() {
        // Lightweight settings readout; the real knobs live in config.json.
        let alert = NSAlert()
        alert.messageText = "HermesKeeper 设置"
        alert.informativeText = """
        宽限期: \(config.graceSeconds)s（任务结束后无操作多久自动熄屏）
        轮询间隔: \(Int(config.pollInterval))s
        "人在电脑前"判定窗口: \(Int(config.userPresenceWindow))s
        自动熄屏: \(config.autoSleepOnGraceExpiry ? "开" : "关")
        空闲强制睡眠: \(config.forceSleepWhenIdle ? "开" : "关")

        完整参数编辑: ~/Library/Application Support/HermesKeeper/config.json
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
