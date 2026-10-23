import AppKit
import CoreServices
import Foundation

let manager = FileManager.default
let distribution = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
let payload = distribution.appendingPathComponent("payload")

func help() {
    print("""
    zmd-mac — 终末地 macOS 安装器

    zmd install [--exe 官方安装包.exe] [--output ~/Applications/鹰角启动器.app]
                [--renderer vulkan|kosmickrisp|dxmt|dxmt-metalfx] [--window windowed|fullscreen|game]
                [--region cn|global] [--sha256 校验值] [--desktop]
    zmd configure --app 应用.app [--renderer vulkan|kosmickrisp|dxmt|dxmt-metalfx]
                  [--moltenvk stable|experimental] [--vulkan-queue default|async]
                  [--window windowed|fullscreen|game] [--hud on|off] [--msync on|off]
                  [--settings-window on|off] [--resolution game|宽x高] [--retina auto|on|off]
                  [--dxmt-log default|error|debug|none] [--wine-log errors|warnings|off]
                  [--shader-cache on|off] [--metal-validation on|off] [--shader-validation on|off]
    zmd inspect --app 应用.app
    zmd doctor
    zmd verify
    zmd setup

    install 未指定 --exe 时从官方 HTTPS 接口下载启动器。
    安装器内置 Wine 和图形后端，不需要 Python、Homebrew 或 Xcode。
    需要 Apple Silicon、macOS 27 和 Rosetta 2。不会覆盖现有应用。
    游戏资源和登录由官方启动器完成，不自动安装系统组件。
    """)
}

func setup() throws {
    print("1. 国服\n2. Global（GRYPHLINK）\n请选择服务器（默认 1）：", terminator: " ")
    let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    try check(["", "1", "2"].contains(choice), "请输入 1 或 2。")
    let region: GameRegion = choice == "2" ? .global : .cn
    print("1. 下载官方启动器\n2. 选择已下载的官方安装 EXE\n请输入 1 或 2（默认 1）：", terminator: " ")
    let selection = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var args = ["--desktop": "true", "--region": region.rawValue]
    switch selection {
    case "", "1": break
    case "2":
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择\(region.title)官方启动器安装 EXE"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            print("已取消。")
            return
        }
        args["--exe"] = url.path
    default: throw ZMDError("请输入 1 或 2。")
    }
    try install(args)
}

func options(_ arguments: ArraySlice<String>, allowed: Set<String>) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = arguments.startIndex
    while index < arguments.endIndex {
        let key = arguments[index]
        try check(allowed.contains(key) && result[key] == nil, "未知或重复参数：\(key)")
        if key == "--desktop" { result[key] = "true"; index += 1; continue }
        try check(index + 1 < arguments.endIndex && !arguments[index + 1].hasPrefix("--"), "\(key) 缺少值。")
        result[key] = arguments[index + 1]
        index += 2
    }
    return result
}

func doctor() throws {
    #if !arch(arm64)
    throw ZMDError("本安装包面向 Apple Silicon Mac。")
    #endif
    let os = ProcessInfo.processInfo.operatingSystemVersion
    try check(os.majorVersion >= 27, "当前发布包的编译依赖要求 macOS 27 或更新版本。")
    do { try run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], capture: true) }
    catch { throw ZMDError("需要 Rosetta 2。请先运行 softwareupdate --install-rosetta，并按系统提示操作。") }
    print("系统检查通过：Apple Silicon / macOS \(os.majorVersion).\(os.minorVersion) / Rosetta 2")
}

func inspect(_ app: URL) throws {
    let support = try supportDirectory(app)
    var report: [String: Any] = ["format": 1, "macOS": ProcessInfo.processInfo.operatingSystemVersionString]
    report["region"] = (try? String(contentsOf: support.appendingPathComponent("region.conf"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "cn"
    for (key, file, fallback) in [
        ("renderer", "renderer.conf", "dxmt"), ("window", "window-mode.conf", "game"),
        ("resolution", "resolution.conf", "game"),
        ("retina", "retina.conf", "auto"),
        ("moltenvk_channel", "moltenvk.conf", "stable"), ("vulkan_queue", "vulkan-queue.conf", "default"),
        ("metal_hud", "metal-hud.conf", "off"), ("msync", "msync.conf", "on"),
        ("settings_window", "settings-window.conf", "on"),
        ("dxmt_log", "dxmt-log.conf", "default"), ("wine_log", "wine-log.conf", "errors"),
        ("shader_cache", "shader-cache.conf", "on"), ("metal_validation", "metal-validation.conf", "off"),
        ("shader_validation", "shader-validation.conf", "off"),
    ] {
        report[key] = (try? String(contentsOf: support.appendingPathComponent(file), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }
    for (key, file) in [
        ("runtime", "runtime/provenance.json"),
        ("moltenvk", "runtime/renderers/moltenvk/provenance.json"),
        ("moltenvk_experimental", "runtime/renderers/moltenvk-experimental/provenance.json"),
        ("kosmickrisp", "runtime/renderers/kosmickrisp/provenance.json"),
        ("dxmt_metalfx", "runtime/renderers/dxmt-metalfx/provenance.json"),
    ] {
        if let data = try? Data(contentsOf: support.appendingPathComponent(file)) {
            report[key] = try JSONSerialization.jsonObject(with: data)
        }
    }
    // Never include registry, launcher logs, account identifiers or login tokens.
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func installIcon(_ app: URL, _ version: URL, log: FileHandle) throws {
    let icon = version.appendingPathComponent("res/icons/app.ico")
    try check(manager.fileExists(atPath: icon.path), "官方安装包缺少启动器图标，请更新安装器后重试。")
    let temporary = manager.temporaryDirectory.appendingPathComponent("zmd-icon-" + UUID().uuidString)
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporary) }
    let original = temporary.appendingPathComponent("original.png")
    try run("/usr/bin/sips", ["-s", "format", "png", icon.path, "--out", original.path], log: log)
    let iconset = temporary.appendingPathComponent("Endfield.iconset")
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (name, size) in [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
        ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ] {
        try run("/usr/bin/sips", ["-z", "\(size)", "\(size)", original.path, "--out", iconset.appendingPathComponent(name + ".png").path], log: log)
    }
    let resources = app.appendingPathComponent("Contents/Resources")
    try manager.createDirectory(at: resources, withIntermediateDirectories: true)
    try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Endfield.icns").path], log: log)
}

func install(_ args: [String: String]) throws {
    try check(getuid() != 0, "请以当前用户运行安装器；不要使用 sudo 初始化 Wine 或游戏目录。")
    let region = try GameRegion.parse(args["--region"] ?? "cn")
    let officialURL = region.installerURL
    try validateConfiguration(args)
    let selectedRenderer = args["--renderer"] ?? "kosmickrisp"
    let output = optionPath(args["--output"] ?? "~/Applications/\(region.appName).app")
    if args["--output"] == nil {
        let legacy = optionPath("~/Applications/\(region.legacyAppName).app")
        try check(!manager.fileExists(atPath: legacy.path),
                  "发现旧版应用，已保留：\(legacy.path)。可继续使用；如需另装一份，请指定 --output。")
    }
    try check(output.pathExtension == "app", "输出路径必须以 .app 结尾。")
    try check(!manager.fileExists(atPath: output.path) &&
              (try? manager.destinationOfSymbolicLink(atPath: output.path)) == nil,
              "目标已存在，已保留：\(output.path)。请选择另一个 --output。")
    if let exe = args["--exe"] {
        try check(manager.fileExists(atPath: optionPath(exe).path), "找不到安装包：\(exe)")
    }
    if let expected = args["--sha256"] {
        try check(expected.count == 64 && expected.allSatisfy { $0.isHexDigit }, "--sha256 必须是 64 位十六进制值。")
    }
    try doctor()
    print("[1/5] 核验内置运行环境")
    try verifyPayload(payload)
    let logDirectory = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/zmd-mac")
    try manager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let logURL = logDirectory.appendingPathComponent("install-" + UUID().uuidString + ".log")
    manager.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }
    print("安装日志：\(logURL.path)")
    let temporary = manager.temporaryDirectory.appendingPathComponent("zmd-install-" + UUID().uuidString)
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporary) }
    print("[2/5] 获取并检查官方启动器")
    let installer: URL
    if let local = args["--exe"] {
        installer = optionPath(local)
    } else {
        installer = temporary.appendingPathComponent("HypergryphLauncher.exe")
        try run("/usr/bin/curl", ["--fail", "--location", "--show-error", "--proto", "=https",
                "--proto-redir", "=https", "--retry", "3", "--connect-timeout", "30",
                "--output", installer.path, officialURL], log: log)
    }
    let handle = try FileHandle(forReadingFrom: installer)
    let magic = try handle.read(upToCount: 2)
    try handle.close()
    try check(magic == Data([0x4d, 0x5a]), "输入文件不是 Windows EXE。")
    let digest = try sha256(installer)
    if let expected = args["--sha256"] { try check(digest == expected.lowercased(), "安装包 SHA-256 不匹配。") }
    print("安装包 SHA-256：\(digest)")
    let sevenzip = payload.appendingPathComponent("sevenzip/bin/7zz")
    let listing = try run(sevenzip.path, ["l", "-slt", "-ba", installer.path], log: log, capture: true)
    try validateInstallerListing(listing)
    let unpacked = temporary.appendingPathComponent("unpacked")
    try run(sevenzip.path, ["x", "-y", "-o" + unpacked.path, installer.path], log: log)
    let extracted = unpacked.appendingPathComponent("$0")
    let enumerator = manager.enumerator(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey])!
    for case let file as URL in enumerator {
        try check(!(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false), "安装包包含链接。")
    }
    let versions = try manager.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
        .filter { manager.fileExists(atPath: $0.appendingPathComponent("Games.exe").path) }
    try check(versions.count == 1, "安装包版本目录不明确。")
    let version = versions[0]
    try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staging = output.deletingLastPathComponent().appendingPathComponent(".zmd-install-" + UUID().uuidString)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: staging) }
    let app = staging.appendingPathComponent(output.lastPathComponent)
    try copyDirectory(payload.appendingPathComponent("AppTemplate.app"), app, log: log)
    let support = app.appendingPathComponent("Contents/SharedSupport")
    try writeText(region.rawValue + "\n", support.appendingPathComponent("region.conf"))
    print("[3/5] 安装独立 Wine 环境")
    try copyDirectory(payload.appendingPathComponent("runtime"), support.appendingPathComponent("runtime"), log: log)
    let prefix = support.appendingPathComponent("prefix")
    var environment = ProcessInfo.processInfo.environment
    environment["ZMD_PREFIX"] = prefix.path
    environment["WINEPREFIX"] = prefix.path
    environment["ZMD_RENDERER"] = selectedRenderer
    let wine = WineRuntime(support: support, inherited: environment)
    let server = support.appendingPathComponent("runtime/wine/bin/wineserver").path
    // The prefix is newly created and never contains a user's existing game.
    var prefixStarted = false
    defer {
        if prefixStarted {
            // Only this installer's temporary prefix can be cleaned up here.
            _ = try? run(server, ["-k"], environment: environment, log: log)
            _ = try? run(server, ["-w"], environment: environment, log: log)
        }
    }
    prefixStarted = true
    try check(try wine.execute(["wineboot", "-u"], log: log) == 0, "Wine 初始化失败")
    try check(try wine.execute(["regedit", "/S", support.appendingPathComponent("prefix-settings.reg").path], log: log) == 0, "Wine 注册表初始化失败")
    print("[4/5] 安装官方启动器并包装 macOS 应用")
    let destination = prefix.appendingPathComponent("drive_c/EndfieldLauncher")
    try manager.copyItem(at: extracted, to: destination)
    try manager.copyItem(at: version.appendingPathComponent("Launcher.exe"), to: destination.appendingPathComponent("Launcher.exe"))
    let origin: [String: Any] = ["source": args["--exe"] == nil ? officialURL : "user-supplied-exe", "region": region.rawValue,
        "sha256": digest, "version": version.lastPathComponent,
        "retrieved": ISO8601DateFormatter().string(from: Date())]
    try JSONSerialization.data(withJSONObject: origin, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("download-origin.json"))
    try configure(app, ["--renderer": selectedRenderer, "--window": args["--window"] ?? "windowed"])
    try installIcon(app, version, log: log)
    let plistURL = app.appendingPathComponent("Contents/Info.plist")
    var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
    plist["CFBundleIdentifier"] = "local.zmdmac.endfield." + UUID().uuidString.lowercased()
    plist["CFBundleName"] = output.deletingPathExtension().lastPathComponent
    plist["CFBundleDisplayName"] = output.deletingPathExtension().lastPathComponent
    plist["LSUIElement"] = false
    if manager.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Endfield.icns").path) {
        plist["CFBundleIconFile"] = "Endfield.icns"
    }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
    // No game or launcher has been executed. Stop only Wine's setup services
    // before moving the fresh prefix; never move a prefix while its server lives.
    try check(try wine.execute(["wineboot", "--end-session", "--shutdown"], log: log) == 0, "Wine 结束安装失败")
    try run(server, ["-k"], environment: environment, log: log)
    try run(server, ["-w"], environment: environment, log: log)
    prefixStarted = false
    try check(!manager.fileExists(atPath: output.path), "安装期间目标路径被占用，未覆盖。")
    try manager.moveItem(at: app, to: output)
    let registration = LSRegisterURL(output as CFURL, true)
    if registration != noErr {
        print("应用已安装；系统应用列表注册失败（\(registration)），可在 Finder 中打开应用后重试。")
    }
    print("[5/5] 完成：\(output.path)")
    if args["--desktop"] != nil {
        let alias = manager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").appendingPathComponent(output.lastPathComponent)
        if manager.fileExists(atPath: alias.path) {
            print("桌面已有同名项目，已保留。")
        } else {
            do {
                let data = try output.bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: alias)
            } catch { print("应用安装成功；桌面入口未创建：\(error.localizedDescription)") }
        }
    }
    print("双击应用，在官方启动器下载游戏并点击「开始游戏」。建议先用 TAAU，当前 Vulkan + FSR 存在局部黑纹报告。")
}

do {
    // Progress is consumed by the native installer as well as Terminal.
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "help"
    switch command {
    case "help", "--help", "-h": help()
    case "setup":
        try check(arguments.count == 1, "setup 不接受参数；自定义路径请使用 install。")
        try setup()
    case "verify":
        try check(arguments.count == 1, "verify 不接受参数。")
        try verifyPayload(payload)
        print("内置运行环境文件校验通过。")
    case "doctor":
        try check(arguments.count == 1, "doctor 不接受参数。")
        try doctor()
    case "install":
        try install(options(arguments.dropFirst(), allowed: ["--exe", "--output", "--renderer", "--window", "--region", "--sha256", "--desktop"]))
    case "configure":
        let args = try options(arguments.dropFirst(), allowed: ["--app", "--renderer", "--window", "--resolution", "--retina", "--hud", "--msync", "--settings-window",
                                                              "--moltenvk", "--vulkan-queue",
                                                              "--dxmt-log", "--wine-log", "--shader-cache", "--metal-validation", "--shader-validation"])
        try check(args["--app"] != nil && args.count > 1, "请指定 --app 和至少一项配置。")
        try configure(optionPath(args["--app"]!), args)
    case "inspect":
        let args = try options(arguments.dropFirst(), allowed: ["--app"])
        try check(args["--app"] != nil, "请指定 --app。")
        try inspect(optionPath(args["--app"]!))
    default: throw ZMDError("未知命令：\(command)。运行 zmd --help 查看帮助。")
    }
} catch {
    FileHandle.standardError.write(Data(("错误：\(error.localizedDescription)\n").utf8))
    exit(1)
}
