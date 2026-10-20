import AppKit

/// A modeless AppKit window. It edits the same files as `zmd configure` and
/// never launches, stops or reconfigures a running Wine process.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let appURL: URL
    private let renderer = NSPopUpButton()
    private let windowMode = NSPopUpButton()
    private let msync = NSButton(checkboxWithTitle: "启用 MSync", target: nil, action: nil)
    private let hud = NSButton(checkboxWithTitle: "显示 Metal 性能面板", target: nil, action: nil)
    private let startup = NSButton(checkboxWithTitle: "打开启动器时显示设置", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let dxmtLog = NSPopUpButton()
    private let wineLog = NSPopUpButton()
    private let shaderCache = NSButton(checkboxWithTitle: "启用 DXMT 着色器缓存", target: nil, action: nil)
    private let metalValidation = NSButton(checkboxWithTitle: "Metal API 校验", target: nil, action: nil)
    private let shaderValidation = NSButton(checkboxWithTitle: "Metal 着色器校验", target: nil, action: nil)
    private var loaded: [String: String] = [:]
    var didClose: (() -> Void)?

    init(appURL: URL) {
        self.appURL = appURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
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
        grid.rowSpacing = 16
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
        let title = label("运行设置")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        populate(renderer, [("Vulkan · MoltenVK", "vulkan"),
                            ("DirectX 11 · DXMT", "dxmt"),
                            ("DirectX 11 · DXMT + MetalFX", "dxmt-metalfx")])
        populate(windowMode, [("窗口化启动", "windowed"), ("使用游戏设置", "game")])
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
            [label("图形后端"), renderer], [label("窗口模式"), windowMode],
            [label("同步"), msync], [label("性能监测"), hud],
        ])
        let logs = NSButton(title: "打开日志文件夹", target: self, action: #selector(openLogs))
        logs.bezelStyle = .rounded
        let debugTab = NSTabViewItem(identifier: "debug")
        debugTab.label = "调试"
        debugTab.view = pane([
            [label("DXMT 日志"), dxmtLog], [label("Wine 日志"), wineLog],
            [label("着色器缓存"), shaderCache], [label("校验"), metalValidation],
            [NSGridCell.emptyContentView, shaderValidation], [label("日志文件"), logs],
        ])
        tabs.addTabViewItem(runtimeTab)
        tabs.addTabViewItem(debugTab)
        tabs.heightAnchor.constraint(equalToConstant: 260).isActive = true
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
        let buttons = NSStackView(views: [spacer, close, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [title, tabs, startup, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window?.setContentSize(NSSize(width: 500, height: 460))
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
        message.textColor = .secondaryLabelColor
        message.stringValue = "更改尚未保存。"
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
        let values = ["--renderer": renderer.selectedItem?.representedObject as? String ?? "",
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
        } catch { showFailure(error) }
    }

    private func showFailure(_ error: Error) {
        message.textColor = .systemRed
        message.stringValue = error.localizedDescription
    }

    @objc private func openLogs() {
        let logs = appURL.appendingPathComponent("Contents/SharedSupport/logs")
        if !NSWorkspace.shared.open(logs) { showFailure(ZMDError("无法打开日志目录。")) }
    }

    @objc private func closeWindow() { window?.performClose(nil) }
    func windowWillClose(_ notification: Notification) { didClose?() }
}
