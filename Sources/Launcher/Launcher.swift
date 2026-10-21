import AppKit
import Darwin
import Foundation

// Read only enough process metadata to identify our own Wine prefix. Never log
// arguments or the environment: the official launcher can pass login tokens.
private struct WineApplication {
    let app: NSRunningApplication
    let isGame: Bool
    let isLauncher: Bool
    let isBootstrap: Bool
    let sessionID: String?
}

private func wineIdentity(_ pid: pid_t) -> (prefix: String, isGame: Bool, isLauncher: Bool, isBootstrap: Bool, sessionID: String?)? {
    var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0,
          size > MemoryLayout<Int32>.size, size <= 4 * 1024 * 1024 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&query, u_int(query.count), &bytes, &size, nil, 0) == 0 else { return nil }
    let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0 && argc <= 65536 else { return nil }
    var cursor = MemoryLayout<Int32>.size
    func nextString() -> String? {
        guard cursor < size else { return nil }
        let start = cursor
        while cursor < size && bytes[cursor] != 0 { cursor += 1 }
        guard cursor < size else { return nil }
        let value = String(decoding: bytes[start..<cursor], as: UTF8.self)
        cursor += 1
        return value
    }
    guard nextString() != nil else { return nil } // Executable path, then padding.
    while cursor < size && bytes[cursor] == 0 { cursor += 1 }
    var isGame = false
    var isLauncher = false
    var isBootstrap = false
    for _ in 0..<argc {
        guard let argument = nextString() else { return nil }
        let basename = argument.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last
        if basename?.lowercased() == "endfield.exe" { isGame = true }
        if basename?.lowercased() == "games.exe" { isLauncher = true }
        if basename?.lowercased() == "launcher.exe" { isBootstrap = true }
    }
    // Wine shortens argv in place (ntdll's rebuild_argv), leaving NUL padding
    // before the environment while the kernel still reports the original argc.
    while cursor < size && bytes[cursor] == 0 { cursor += 1 }
    var prefix: String?
    var sessionID: String?
    while let entry = nextString(), !entry.isEmpty {
        if entry.hasPrefix("WINEPREFIX=") {
            prefix = String(entry.dropFirst("WINEPREFIX=".count))
        } else if entry.hasPrefix("ZMD_SESSION_ID=") {
            sessionID = String(entry.dropFirst("ZMD_SESSION_ID=".count))
        }
    }
    return prefix.map { ($0, isGame, isLauncher, isBootstrap, sessionID) }
}

private func sameFile(_ left: String, _ right: String) -> Bool {
    guard let a = try? FileManager.default.attributesOfItem(atPath: left),
          let b = try? FileManager.default.attributesOfItem(atPath: right),
          let aInode = a[.systemFileNumber] as? NSNumber,
          let bInode = b[.systemFileNumber] as? NSNumber,
          let aDevice = a[.systemNumber] as? NSNumber,
          let bDevice = b[.systemNumber] as? NSNumber else { return false }
    return aInode == bInode && aDevice == bDevice
}

final class EndfieldApplication: NSObject, NSApplicationDelegate {
    private let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
    private var support: URL { contents.appendingPathComponent("SharedSupport") }
    private var launcher: Process?
    private var log: FileHandle?
    private var quitting = false
    private var finished = false
    private var quitTimer: Timer?
    private var quitDeadline = Date.distantPast
    private var requested: [NSRunningApplication] = []
    private var sessionID = UUID().uuidString
    private var settings: SettingsWindowController?
    private var statusTimer: Timer?
    private var launcherSeen = false
    private var terminalStatus: LauncherStatus?
    private var restartPending = false
    private var cacheClearPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--attach") {
            let existing = Set(sessionApplications().compactMap(\.sessionID))
            if existing.count == 1, let identity = existing.first { sessionID = identity }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sessionQuitRequested(_:)),
            name: NSNotification.Name("local.zmdmac.SessionQuit"), object: sessionID,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sessionSettingsRequested(_:)),
            name: NSNotification.Name("local.zmdmac.SessionSettings"), object: sessionID,
            suspensionBehavior: .deliverImmediately)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "鹰角启动器"
        let applicationMenu = NSMenu(title: appName)
        let settingsItem = applicationMenu.addItem(withTitle: "运行设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出\(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
        #if LIFECYCLE_TEST
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(requestRestart), name: NSNotification.Name("local.zmdmac.TestRestart"),
            object: Bundle.main.bundleURL.path, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(requestCacheClear), name: NSNotification.Name("local.zmdmac.TestClearCache"),
            object: Bundle.main.bundleURL.path, suspensionBehavior: .deliverImmediately)
        #endif
        startSession(attach: CommandLine.arguments.contains("--attach"))
    }

    private func startSession(attach: Bool = false) {
        finished = false
        quitting = false
        restartPending = false
        cacheClearPending = false
        launcherSeen = false
        terminalStatus = nil
        requested.removeAll()
        try? log?.close()
        do {
            let logs = support.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let file = logs.appendingPathComponent("native-launcher-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            log = try FileHandle(forWritingTo: file)
            var arguments = ["--session"]
            if attach { arguments.append("--attach") }
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = arguments
            process.currentDirectoryURL = support
            process.standardOutput = log ?? FileHandle.nullDevice
            process.standardError = log ?? FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = support.appendingPathComponent("prefix").path
            environment["ZMD_PREFIX"] = support.appendingPathComponent("prefix").path
            environment["ZMD_SESSION_ID"] = sessionID
            process.environment = environment
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async { self?.launcherFinished(status: process.terminationStatus) }
            }
            launcher = process
            settings?.setLauncherStatus(.starting)
            try process.run()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.settings?.window?.isVisible == true else { return }
                self.refreshLauncherStatus()
            }
            statusTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            let preference = try? String(contentsOf: support.appendingPathComponent("settings-window.conf"), encoding: .utf8)
            if preference?.trimmingCharacters(in: .whitespacesAndNewlines) != "off" { showSettings() }
        } catch {
            finished = true
            terminalStatus = .failed
            refreshLauncherStatus()
            showError("无法打开官方启动器", detail: error.localizedDescription)
            NSApp.terminate(nil)
        }
    }

    @objc private func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(appURL: Bundle.main.bundleURL)
            settings?.restartRequested = { [weak self] in self?.requestRestart() }
            settings?.clearCacheRequested = { [weak self] in self?.requestCacheClear() }
        }
        refreshLauncherStatus()
        settings?.present()
    }

    @objc private func requestRestart() {
        guard !quitting && !finished else { return }
        restartPending = true
        beginQuit()
    }

    @objc private func requestCacheClear() {
        guard !quitting && !finished else { return }
        cacheClearPending = true
        settings?.showCacheResult("正在退出会话，随后清除缓存…")
        requestRestart()
    }

    private func refreshLauncherStatus() {
        guard let settings else { return }
        if let terminalStatus { settings.setLauncherStatus(terminalStatus); return }
        if quitting { settings.setLauncherStatus(.stopping); return }
        let apps = sessionApplications().filter { $0.sessionID == nil || $0.sessionID == sessionID }
        let hasLauncher = apps.contains(where: \.isLauncher)
        launcherSeen = launcherSeen || hasLauncher
        if apps.contains(where: \.isGame) { settings.setLauncherStatus(.gameRunning) }
        else if hasLauncher { settings.setLauncherStatus(.running) }
        else if launcher?.isRunning == true && !launcherSeen { settings.setLauncherStatus(.starting) }
        else { settings.setLauncherStatus(.stopped) }
    }

    @objc private func sessionSettingsRequested(_ notification: Notification) {
        guard let pid = notification.userInfo?["pid"] as? NSNumber,
              sessionApplications().contains(where: {
                  $0.app.processIdentifier == pid.int32Value && $0.sessionID == sessionID
              }) else { return }
        showSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func record(_ message: String) {
        try? log?.write(contentsOf: Data((message + "\n").utf8))
    }

    private func sessionApplications() -> [WineApplication] {
        let runtime = support.appendingPathComponent("runtime").resolvingSymlinksInPath().path + "/"
        let prefix = support.appendingPathComponent("prefix").resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.processIdentifier != getpid(),
                  let path = app.executableURL?.resolvingSymlinksInPath().path,
                  (path.hasPrefix(runtime) ||
                   sameFile(path, runtime + "wine/lib/wine/x86_64-unix/wine")),
                  let identity = wineIdentity(app.processIdentifier),
                  identity.prefix.hasPrefix("/"),
                  URL(fileURLWithPath: identity.prefix).resolvingSymlinksInPath().path == prefix else { return nil }
            return WineApplication(app: app, isGame: identity.isGame,
                                   isLauncher: identity.isLauncher, isBootstrap: identity.isBootstrap,
                                   sessionID: identity.sessionID)
        }
    }

    @objc private func sessionQuitRequested(_ notification: Notification) {
        guard let pid = notification.userInfo?["pid"] as? NSNumber,
              sessionApplications().contains(where: {
                  $0.app.processIdentifier == pid.int32Value && $0.sessionID == sessionID
              }) else { return }
        record("Dock quit received: pid=\(pid)")
        restartPending = false
        cacheClearPending = false
        beginQuit()
    }

    private func launcherFinished(status: Int32) {
        finished = true
        quitTimer?.invalidate()
        statusTimer?.invalidate()
        if restartPending {
            // The native session worker waits for this prefix's Wine server, so the previous
            // game and launcher are gone before starting a new official session.
            var result: String?
            var failed = false
            if cacheClearPending {
                cacheClearPending = false
                do {
                    try check(status == 0, "会话异常结束，缓存已保留。")
                    let count = try clearVulkanCache(Bundle.main.bundleURL)
                    result = count == 0 ? "没有找到 Vulkan 缓存。" : "已清除 Vulkan 缓存，下次进入游戏会重新生成。"
                } catch {
                    result = "缓存清理失败：\(error.localizedDescription)"
                    failed = true
                }
            }
            startSession()
            if let result {
                showSettings()
                settings?.showCacheResult(result, failed: failed)
            }
            return
        }
        terminalStatus = status != 0 && !quitting ? .failed : .stopped
        refreshLauncherStatus()
        if status != 0 && !quitting {
            showError("启动器已结束", detail: "退出代码：\(status)。日志保存在应用内的 Contents/SharedSupport/logs。")
        }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        restartPending = false
        cacheClearPending = false
        if finished || launcher?.isRunning != true { return .terminateNow }
        beginQuit()
        // The hidden coordinator remains alive until its child session exits.
        // Avoid AppKit's deferred-termination run loop, which can prevent the
        // next coordination tick when Quit originated in a Wine notification.
        return .terminateCancel
    }

    private func beginQuit() {
        guard !quitting && !finished else { return }
        quitting = true
        refreshLauncherStatus()
        record("Session quit started")
        requested.removeAll()
        quitDeadline = Date().addingTimeInterval(15)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.advanceQuit()
        }
        quitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        advanceQuit()
    }

    private func advanceQuit() {
        guard quitting && !finished else { return }
        // End the game before its official launcher. Refresh the list to include
        // a process started while the initial launch was still in flight.
        let apps = sessionApplications().filter { $0.sessionID == nil || $0.sessionID == sessionID }
        let games = apps.filter(\.isGame)
        let launchers = apps.filter(\.isLauncher)
        let bootstraps = apps.filter(\.isBootstrap)
        // Qt/Chromium owns its helper processes. Sending them independent quit
        // requests during launcher shutdown causes crash recovery/respawning
        // and can strand the launcher after its main window has disappeared.
        let targets = !games.isEmpty ? games : (!launchers.isEmpty ? launchers : bootstraps)
        for candidate in targets {
            let app = candidate.app
            if requested.contains(where: { $0 == app }) { continue }
            requested.append(app)
            record("Native quit requested: pid=\(app.processIdentifier), game=\(candidate.isGame)")
            if candidate.sessionID == sessionID {
                // Wine routes Endfield through its normal WM_CLOSE handler;
                // Games.exe queues its own tray Exit action in Qt.
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("local.zmdmac.NativeQuit"), object: sessionID,
                    userInfo: ["pid": NSNumber(value: app.processIdentifier)],
                    deliverImmediately: true)
            } else if !app.terminate() && !app.isTerminated {
                cancelQuit("程序未接受退出请求；可稍后重试")
                return
            }
        }
        if Date() >= quitDeadline {
            // Native terminate() may be accepted, delayed or cancelled. A timeout
            // is never permission to kill a game: quietly return control instead.
            cancelQuit("退出尚未完成；请检查游戏内的确认，或稍后重试")
        }
    }

    private func cancelQuit(_ message: String) {
        quitTimer?.invalidate()
        quitting = false
        restartPending = false
        if cacheClearPending { settings?.showCacheResult("退出未完成，已取消缓存清理。", failed: true) }
        cacheClearPending = false
        refreshLauncherStatus()
        requested.removeAll()
        record(message)
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@main
enum EndfieldMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--session" {
            do {
                #if LIFECYCLE_TEST
                if try fixtureSession() { return }
                #endif
                let support = Bundle.main.bundleURL.appendingPathComponent("Contents/SharedSupport")
                exit(try WineRuntime(support: support).session(attach: CommandLine.arguments.contains("--attach")))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(2)
            }
        }
        let application = NSApplication.shared
        let delegate = EndfieldApplication()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
