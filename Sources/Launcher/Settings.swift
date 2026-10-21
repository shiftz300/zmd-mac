import AppKit

enum LauncherStatus: Equatable {
    case starting, running, gameRunning, stopping, stopped, failed

    var title: String {
        switch self {
        case .starting: return "正在启动启动器…"
        case .running: return "启动器已运行"
        case .gameRunning: return "游戏运行中"
        case .stopping: return "正在退出…"
        case .stopped: return "启动器未运行"
        case .failed: return "启动器启动或运行失败"
        }
    }

    var busy: Bool { self == .starting || self == .stopping }
}

/// A modeless AppKit window. It edits the same files as `zmd configure` and
/// never launches, stops or reconfigures a running Wine process.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate, NSTextFieldDelegate {
    private let appURL: URL
    private let renderer = NSPopUpButton()
    private let windowMode = NSPopUpButton()
    private let resolution = NSComboBox()
    private let moltenvk = NSPopUpButton()
    private let vulkanQueue = NSPopUpButton()
    private let msync = NSButton(checkboxWithTitle: "启用 MSync", target: nil, action: nil)
    private let hud = NSButton(checkboxWithTitle: "显示 Metal 性能面板", target: nil, action: nil)
    private let startup = NSButton(checkboxWithTitle: "打开启动器时显示设置", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let launcherStatus = NSTextField(labelWithString: "")
    private let statusSpinner = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private var displayedStatus: LauncherStatus?
    private let dxmtLog = NSPopUpButton()
    private let wineLog = NSPopUpButton()
    private let shaderCache = NSButton(checkboxWithTitle: "启用 DXMT 着色器缓存", target: nil, action: nil)
    private let metalValidation = NSButton(checkboxWithTitle: "Metal API 校验", target: nil, action: nil)
    private let shaderValidation = NSButton(checkboxWithTitle: "Metal 着色器校验", target: nil, action: nil)
    private var loaded: [String: String] = [:]
    var didClose: (() -> Void)?
    var restartRequested: (() -> Void)?
    var clearCacheRequested: (() -> Void)?

    init(appURL: URL) {
        self.appURL = appURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "运行设置"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        buildContents()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.font = .systemFont(ofSize: secondary ? 12 : 13)
        result.textColor = secondary ? .secondaryLabelColor : .labelColor
        return result
    }

    private func populate(_ popup: NSPopUpButton, _ items: [(String, String)]) {
        for (title, value) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        popup.target = self
        popup.action = #selector(controlChanged)
        popup.widthAnchor.constraint(equalToConstant: 278).isActive = true
    }

    private func pane(_ rows: [[NSView]]) -> NSView {
        let view = NSView()
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 14
        grid.rowSpacing = 14
        grid.column(at: 0).width = 102
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),
        ])
        return view
    }

    private func buildContents() {
        guard let content = window?.contentView else { return }
        populate(renderer, [("Vulkan · MoltenVK", "vulkan"),
                            ("DirectX 11 · DXMT", "dxmt"),
                            ("DirectX 11 · DXMT + MetalFX", "dxmt-metalfx")])
        populate(windowMode, [("窗口化启动", "windowed"), ("无边框全屏启动", "fullscreen"), ("使用游戏设置", "game")])
        resolution.addItems(withObjectValues: ["使用游戏设置", "1920 × 1080", "2560 × 1440", "3840 × 2160",
                                              "1920 × 1200", "2560 × 1600", "3440 × 1440", "3840 × 1600", "5120 × 1440"])
        resolution.isEditable = true
        resolution.completes = false
        resolution.delegate = self
        resolution.widthAnchor.constraint(equalToConstant: 278).isActive = true
        resolution.setAccessibilityLabel("启动分辨率")
        resolution.toolTip = "可选择预设或输入宽 × 高（像素）。重启会话时同步游戏分辨率配置；使用游戏设置则停止覆盖。游戏下拉菜单可能不列出自定义尺寸。"
        populate(moltenvk, [("稳定版", "stable"), ("实验版", "experimental")])
        populate(vulkanQueue, [("默认（同步）", "default"), ("后台队列（实验）", "async")])
        moltenvk.setAccessibilityLabel("Vulkan 版本")
        vulkanQueue.setAccessibilityLabel("队列提交")
        vulkanQueue.toolTip = "后台队列改变命令提交方式，不是异步着色器编译；保存并重启整个会话后生效。"
        populate(dxmtLog, [("默认", "default"), ("仅错误", "error"), ("详细", "debug"), ("关闭", "none")])
        populate(wineLog, [("仅错误", "errors"), ("错误与警告", "warnings"), ("关闭", "off")])
        renderer.setAccessibilityLabel("图形后端")
        windowMode.setAccessibilityLabel("窗口模式")
        dxmtLog.setAccessibilityLabel("DXMT 日志")
        wineLog.setAccessibilityLabel("Wine 日志")
        renderer.toolTip = "MetalFX 通过游戏内的 DLSS 选项使用。"
        shaderCache.toolTip = "只控制是否使用缓存，不删除已有缓存。关闭可能增加首次编译卡顿。"
        metalValidation.toolTip = "检查 Metal API 使用错误；仅排查问题时开启，会增加运行开销。"
        shaderValidation.toolTip = "检查 Metal 着色器访问错误；仅排查问题时开启，会明显增加运行开销。"
        for control in [msync, hud, shaderCache, metalValidation, shaderValidation] {
            control.target = self
            control.action = #selector(controlChanged)
        }
        startup.target = self
        startup.action = #selector(startupChanged)
        let tabs = NSTabView()
        tabs.font = .systemFont(ofSize: 13)
        let runtimeTab = NSTabViewItem(identifier: "runtime")
        runtimeTab.label = "运行"
        runtimeTab.view = pane([
            [label("图形后端"), renderer], [label("Vulkan 版本"), moltenvk],
            [label("队列提交"), vulkanQueue],
            [label("同步"), msync], [label("性能监测"), hud],
        ])
        let displayTab = NSTabViewItem(identifier: "display")
        displayTab.label = "显示"
        let readScreen = NSButton(title: "读取当前屏幕", target: self, action: #selector(readCurrentScreen))
        readScreen.bezelStyle = .rounded
        readScreen.toolTip = "把设置窗口移到目标屏幕后点击。读取屏幕的原生像素分辨率，不受 macOS 桌面缩放影响。"
        displayTab.view = pane([
            [label("窗口模式"), windowMode], [label("启动分辨率"), resolution],
            [label("屏幕尺寸"), readScreen],
        ])
        let logs = NSButton(title: "打开日志", target: self, action: #selector(openLogs))
        logs.bezelStyle = .rounded
        let clearCache = NSButton(title: "清除 Vulkan 缓存…", target: self, action: #selector(confirmClearCache))
        clearCache.bezelStyle = .rounded
        clearCache.toolTip = "正常退出当前会话后清除游戏的 Vulkan 管线缓存，再打开启动器。"
        let tools = NSStackView(views: [logs, clearCache])
        tools.orientation = .horizontal
        tools.spacing = 8
        let debugTab = NSTabViewItem(identifier: "debug")
        debugTab.label = "调试"
        debugTab.view = pane([
            [label("DXMT 日志"), dxmtLog], [label("Wine 日志"), wineLog],
            [label("着色器缓存"), shaderCache], [label("校验"), metalValidation],
            [NSGridCell.emptyContentView, shaderValidation], [label("工具"), tools],
        ])
        tabs.addTabViewItem(runtimeTab)
        tabs.addTabViewItem(displayTab)
        tabs.addTabViewItem(debugTab)
        tabs.heightAnchor.constraint(equalToConstant: 268).isActive = true
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.setAccessibilityIdentifier("settings-result")
        message.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        launcherStatus.font = .systemFont(ofSize: 12)
        launcherStatus.setAccessibilityIdentifier("launcher-status")
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        for indicator in [statusSpinner as NSView, statusIcon] {
            indicator.widthAnchor.constraint(equalToConstant: 14).isActive = true
            indicator.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }
        let status = NSStackView(views: [statusSpinner, statusIcon, launcherStatus])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 6
        let buttons = NSStackView(views: [status, spacer, close, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        let stack = NSStackView(views: [tabs, startup, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window?.setContentSize(NSSize(width: 500, height: 420))
        setLauncherStatus(.stopped)
    }

    func setLauncherStatus(_ status: LauncherStatus) {
        guard displayedStatus != status else { return }
        displayedStatus = status
        launcherStatus.stringValue = status.title
        launcherStatus.textColor = status == .failed ? .systemRed : .secondaryLabelColor
        statusSpinner.isHidden = !status.busy
        statusIcon.isHidden = status.busy
        if status.busy { statusSpinner.startAnimation(nil) }
        else { statusSpinner.stopAnimation(nil) }
        let active = status == .running || status == .gameRunning
        let symbol = status == .failed ? "exclamationmark.circle.fill" : (active ? "checkmark.circle.fill" : "circle")
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = status == .failed ? .systemRed : (active ? .systemGreen : .secondaryLabelColor)
    }

    func present() {
        if window?.isVisible != true { reload() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func select(_ popup: NSPopUpButton, value: String) {
        // Preserve unrecognized values instead of silently choosing a backend.
        for item in popup.itemArray where item.tag == -1 { popup.menu?.removeItem(item) }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == value }) {
            popup.select(item)
        } else {
            popup.addItem(withTitle: "未知配置（\(value)）")
            popup.lastItem?.representedObject = value
            popup.lastItem?.tag = -1
            popup.select(popup.lastItem)
        }
    }

    private func reload() {
        do {
            loaded = try configurationValues(appURL)
            select(renderer, value: loaded["--renderer"]!)
            select(windowMode, value: loaded["--window"]!)
            let size = loaded["--resolution"] ?? "game"
            resolution.stringValue = size == "game" ? "使用游戏设置" : size.replacingOccurrences(of: "x", with: " × ")
            select(moltenvk, value: loaded["--moltenvk"]!)
            select(vulkanQueue, value: loaded["--vulkan-queue"]!)
            updateVulkanControls()
            msync.state = loaded["--msync"] == "on" ? .on : .off
            hud.state = loaded["--hud"] == "on" ? .on : .off
            startup.state = loaded["--settings-window"] == "off" ? .off : .on
            select(dxmtLog, value: loaded["--dxmt-log"]!)
            select(wineLog, value: loaded["--wine-log"]!)
            shaderCache.state = loaded["--shader-cache"] == "off" ? .off : .on
            metalValidation.state = loaded["--metal-validation"] == "on" ? .on : .off
            shaderValidation.state = loaded["--shader-validation"] == "on" ? .on : .off
            message.stringValue = ""
            message.textColor = .secondaryLabelColor
        } catch { showFailure(error) }
    }

    @objc private func controlChanged() {
        updateVulkanControls()
        message.textColor = .secondaryLabelColor
        message.stringValue = "更改尚未保存。"
    }

    func controlTextDidChange(_ notification: Notification) { controlChanged() }
    func comboBoxSelectionDidChange(_ notification: Notification) { controlChanged() }

    @objc private func readCurrentScreen() {
        guard let screen = window?.screen else { showFailure(ZMDError("无法读取当前屏幕。")); return }
        do {
            let size = try DisplayResolution.read(screen)
            resolution.stringValue = "\(size.width) × \(size.height)"
            controlChanged()
            message.stringValue = "已读取\(screen.localizedName)的原生分辨率，尚未保存。"
        } catch { showFailure(error) }
    }

    private func updateVulkanControls() {
        let enabled = renderer.selectedItem?.representedObject as? String == "vulkan"
        moltenvk.isEnabled = enabled
        vulkanQueue.isEnabled = enabled
    }

    @objc private func startupChanged() {
        do {
            let value = startup.state == .on ? "on" : "off"
            try configure(appURL, ["--settings-window": value])
            loaded["--settings-window"] = value
            message.textColor = .secondaryLabelColor
            message.stringValue = "已保存显示偏好。"
        } catch {
            startup.state = loaded["--settings-window"] == "off" ? .off : .on
            showFailure(error)
        }
    }

    @objc private func saveSettings() {
        window?.makeFirstResponder(nil)
        let size = resolution.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = size.replacingOccurrences(of: "×", with: "x").lowercased().filter { !$0.isWhitespace }
        let values = ["--renderer": renderer.selectedItem?.representedObject as? String ?? "",
                      "--resolution": size == "使用游戏设置" ? "game" : normalized,
                      "--moltenvk": moltenvk.selectedItem?.representedObject as? String ?? "",
                      "--vulkan-queue": vulkanQueue.selectedItem?.representedObject as? String ?? "",
                      "--window": windowMode.selectedItem?.representedObject as? String ?? "",
                      "--msync": msync.state == .on ? "on" : "off",
                      "--hud": hud.state == .on ? "on" : "off",
                      "--dxmt-log": dxmtLog.selectedItem?.representedObject as? String ?? "",
                      "--wine-log": wineLog.selectedItem?.representedObject as? String ?? "",
                      "--shader-cache": shaderCache.state == .on ? "on" : "off",
                      "--metal-validation": metalValidation.state == .on ? "on" : "off",
                      "--shader-validation": shaderValidation.state == .on ? "on" : "off"]
        do {
            let changes = values.filter { loaded[$0.key] != $0.value }
            if !changes.isEmpty { try configure(appURL, changes) }
            loaded.merge(values) { _, new in new }
            message.textColor = .secondaryLabelColor
            message.stringValue = changes.isEmpty ? "配置没有变化。" : "已保存，重启游戏会话后生效。"
            if !changes.isEmpty, restartRequested != nil, let window {
                let alert = NSAlert()
                alert.messageText = "设置已保存，立即重启？"
                alert.informativeText = "将正常退出游戏并重开官方启动器，随后可点击「开始游戏」。取消会保留设置，下次启动生效。"
                alert.addButton(withTitle: "重启启动器")
                alert.addButton(withTitle: "取消")
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.restartRequested?() }
                }
            }
        } catch { showFailure(error) }
    }

    private func showFailure(_ error: Error) {
        message.textColor = .systemRed
        message.stringValue = error.localizedDescription
    }

    func showCacheResult(_ text: String, failed: Bool = false) {
        message.textColor = failed ? .systemRed : .secondaryLabelColor
        message.stringValue = text
    }

    @objc private func confirmClearCache() {
        guard let window, clearCacheRequested != nil else { return }
        let alert = NSAlert()
        alert.messageText = "清除 Vulkan 缓存？"
        alert.informativeText = "将正常退出游戏和启动器，清除缓存后重开启动器。游戏文件和设置会保留，下次进入游戏可能因重新编译着色器而暂时卡顿。未保存的运行设置不会应用。"
        alert.addButton(withTitle: "清除并重开")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.clearCacheRequested?() }
        }
    }

    @objc private func openLogs() {
        let logs = appURL.appendingPathComponent("Contents/SharedSupport/logs")
        if !NSWorkspace.shared.open(logs) { showFailure(ZMDError("无法打开日志目录。")) }
    }

    @objc private func closeWindow() { window?.performClose(nil) }
    func windowWillClose(_ notification: Notification) { didClose?() }
}
