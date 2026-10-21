import Foundation
import CryptoKit

enum GameRegion: String, CaseIterable {
    case cn, global

    var title: String { self == .cn ? "国服" : "Global · GRYPHLINK" }
    var appName: String { self == .cn ? "鹰角启动器" : "GRYPHLINK" }
    var legacyAppName: String { self == .cn ? "终末地" : "终末地 Global" }
    var installerURL: String {
        switch self {
        case .cn: return "https://launcher.hypergryph.com/launcher/get_latest_launcher?appcode=abYeZZ16BPluCFyT&ta=endfield&channel=1&sub_channel=1"
        case .global: return "https://launcher.gryphline.com/launcher/get_latest_launcher?appcode=TiaytKBUIEdoEwRT&ta=endfield&channel=6&sub_channel=6"
        }
    }
    static func parse(_ value: String) throws -> GameRegion {
        guard let region = GameRegion(rawValue: value) else { throw ZMDError("--region 仅支持 cn 或 global。") }
        return region
    }
}

struct ZMDError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Call only after the owning Wine session has fully exited.
/// Clear the game's known Vulkan cache, never whole AppData or driver caches.
func clearVulkanCache(_ app: URL) throws -> Int {
    let manager = FileManager.default
    let root = app.resolvingSymlinksInPath()
    let prefix = root.appendingPathComponent("Contents/SharedSupport/prefix")
    let users = prefix.appendingPathComponent("drive_c/users")
    try check(users.resolvingSymlinksInPath().path.hasPrefix(prefix.path + "/"),
              "缓存目录指向应用外部，未清理。")
    guard manager.fileExists(atPath: users.path) else { return 0 }
    let profiles = try manager.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)
    var caches: [URL] = []
    for profile in profiles {
        for vendor in ["Hypergryph", "Gryphline"] {
            let cache = profile.appendingPathComponent("AppData/LocalLow/\(vendor)/Endfield/vulkan_pso_cache.bin")
            // Ignore absent files, but reject links/directories instead of following them.
            let attributes: [FileAttributeKey: Any]
            do { attributes = try manager.attributesOfItem(atPath: cache.path) }
            catch let error as NSError {
                if error.domain == NSCocoaErrorDomain &&
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
                throw error
            }
            try check(attributes[.type] as? FileAttributeType == .typeRegular &&
                      cache.resolvingSymlinksInPath().path.hasPrefix(prefix.path + "/"),
                      "缓存路径异常，未清理。")
            caches.append(cache)
        }
    }
    // Validate every candidate before removing any file.
    for cache in caches { try manager.removeItem(at: cache) }
    return caches.count
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw ZMDError(message) }
}

func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
        hash.update(data: block)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func safeRelativePath(_ path: String) -> Bool {
    let normalized = path.replacingOccurrences(of: "\\", with: "/")
    return !normalized.isEmpty && !normalized.hasPrefix("/") &&
        !normalized.contains(":") && !normalized.contains("\0") &&
        !normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..")
}

func validateInstallerListing(_ listing: String) throws {
    var paths: [String] = []
    var total: UInt64 = 0
    for line in listing.components(separatedBy: .newlines) {
        if line.hasPrefix("Path = ") {
            let path = String(line.dropFirst(7))
            try check(safeRelativePath(path), "安装包包含不安全路径：\(path)")
            paths.append(path.replacingOccurrences(of: "\\", with: "/"))
        }
        if line.hasPrefix("Symbolic Link = ") || line.hasPrefix("Hard Link = ") {
            throw ZMDError("安装包不应包含链接。")
        }
        if line.hasPrefix("Size = "), let size = UInt64(line.dropFirst(7)) {
            try check(size <= 8 << 30 && total <= (8 << 30) - size, "安装包展开尺寸超过限制。")
            total += size
        }
    }
    try check(!paths.isEmpty && paths.count < 30_000, "无法识别安装包内容。")
    let games = paths.filter {
        let parts = $0.split(separator: "/")
        return parts.count == 3 && parts[0] == "$0" && parts[2] == "Games.exe"
    }
    try check(games.count == 1, "只接受终末地官方启动器安装 EXE，不支持直接导入游戏 Endfield.exe。")
    let root = String(games[0].dropLast("Games.exe".count))
    try check(paths.contains(root + "Launcher.exe"), "安装包缺少官方启动入口。")
}

struct PayloadManifest: Codable {
    let format: Int
    let files: [String: String]
    let links: [String: String]
}

func verifyPayload(_ input: URL) throws {
    // Directory enumeration resolves /var -> /private/var on macOS.
    let payload = input.resolvingSymlinksInPath()
    let data = try Data(contentsOf: payload.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(PayloadManifest.self, from: data)
    try check(manifest.format == 1, "不支持此运行包格式。")
    let manager = FileManager.default
    for (name, expected) in manifest.files {
        try check(safeRelativePath(name), "运行包清单路径异常。")
        let file = payload.appendingPathComponent(name)
        let attributes = try manager.attributesOfItem(atPath: file.path)
        try check(attributes[.type] as? FileAttributeType == .typeRegular, "运行包文件类型异常：\(name)")
        try check(try sha256(file) == expected, "运行包文件校验失败：\(name)")
    }
    for (name, target) in manifest.links {
        try check(safeRelativePath(name) && !target.hasPrefix("/"), "运行包链接异常。")
        let link = payload.appendingPathComponent(name)
        try check(try manager.destinationOfSymbolicLink(atPath: link.path) == target, "运行包链接已改变。")
        let resolved = link.resolvingSymlinksInPath().path
        try check(resolved.hasPrefix(payload.resolvingSymlinksInPath().path + "/"), "运行包链接越界。")
    }
    // Do not let unlisted executables or links enter an installed app.
    let enumerator = manager.enumerator(atPath: payload.path)!
    for case let name as String in enumerator {
        if name == "manifest.json" { continue }
        let file = payload.appendingPathComponent(name)
        let type = try manager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        if type == .typeDirectory { continue }
        try check(manifest.files[name] != nil || manifest.links[name] != nil, "运行包包含清单之外的文件：\(name)")
    }
}

@discardableResult
func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
         log: FileHandle? = nil, capture: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment = environment { process.environment = environment }
    let pipe = capture ? Pipe() : nil
    process.standardOutput = pipe?.fileHandleForWriting ?? log ?? FileHandle.standardOutput
    process.standardError = log ?? FileHandle.standardError
    try process.run()
    // Process inherits a duplicate; keeping our writer open prevents EOF.
    try pipe?.fileHandleForWriting.close()
    let data = pipe?.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try check(process.terminationStatus == 0, "\(URL(fileURLWithPath: executable).lastPathComponent) 失败（\(process.terminationStatus)），请查看安装日志。")
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

func optionPath(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func writeText(_ text: String, _ url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func copyDirectory(_ source: URL, _ destination: URL, log: FileHandle?) throws {
    // APFS clones avoid storing multiple full copies where supported.
    do { try run("/bin/cp", ["-cR", source.path, destination.path], log: log) }
    catch {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

func validateConfiguration(_ args: [String: String]) throws {
    if let resolution = args["--resolution"], resolution != "game" {
        let parts = resolution.split(separator: "x", omittingEmptySubsequences: false)
        try check(parts.count == 2 && parts.allSatisfy {
            guard let value = Int($0), String(value) == $0 else { return false }
            return (320...16384).contains(value)
        }, "分辨率请填写 宽x高，每边为 320–16384 像素，或选择使用游戏设置。")
    }
    for (key, values) in [
        "--renderer": ["vulkan", "dxmt", "dxmt-metalfx"], "--window": ["windowed", "fullscreen", "game"],
        "--moltenvk": ["stable", "experimental"], "--vulkan-queue": ["default", "async"],
        "--hud": ["on", "off"], "--msync": ["on", "off"], "--settings-window": ["on", "off"],
        "--dxmt-log": ["default", "error", "debug", "none"], "--wine-log": ["errors", "warnings", "off"],
        "--shader-cache": ["on", "off"], "--metal-validation": ["on", "off"],
        "--shader-validation": ["on", "off"],
    ] {
        if let value = args[key] { try check(values.contains(value), "\(key) 不支持 \(value)。") }
    }
}

func supportDirectory(_ app: URL) throws -> URL {
    let manager = FileManager.default
    let contents = app.appendingPathComponent("Contents")
    let data = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
    let metadata = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    try check((metadata?["CFBundleIdentifier"] as? String)?.hasPrefix("local.zmdmac.endfield") == true,
              "这不是 zmd-mac 创建的应用。")
    let support = contents.appendingPathComponent("SharedSupport")
    try check(manager.fileExists(atPath: contents.appendingPathComponent("MacOS/Endfield").path) ||
              manager.fileExists(atPath: support.appendingPathComponent("scripts/wine.sh").path), "应用结构不完整。")
    return support
}

func configure(_ app: URL, _ args: [String: String]) throws {
    let manager = FileManager.default
    try validateConfiguration(args)
    let support = try supportDirectory(app)
    let native = (try? String(contentsOf: support.appendingPathComponent("runtime-interface"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "1"
    let wrapper = native ? "" : try String(contentsOf: support.appendingPathComponent("scripts/wine.sh"), encoding: .utf8)
    if !native && (args["--resolution"] != nil || args["--window"] == "fullscreen") {
        let launch = try String(contentsOf: app.appendingPathComponent("Contents/MacOS/launch.sh"), encoding: .utf8)
        try check(launch.contains("resolution.conf") && launch.contains("-window-mode borderless"),
                  "请先更新应用包装层以支持显示设置；配置未写入。")
    }
    for (option, marker) in ["--hud": "metal-hud.conf", "--msync": "msync.conf",
                             "--moltenvk": "moltenvk.conf", "--vulkan-queue": "vulkan-queue.conf",
                             "--dxmt-log": "dxmt-log.conf", "--wine-log": "wine-log.conf",
                             "--shader-cache": "shader-cache.conf", "--metal-validation": "metal-validation.conf",
                             "--shader-validation": "shader-validation.conf"] {
        if args[option] != nil {
            try check(native || wrapper.contains(marker), "此应用的旧包装层不支持 \(option)，请先更新包装层；配置未写入。")
        }
    }
    if args["--renderer"] == "vulkan" {
        try check(manager.fileExists(atPath: support.appendingPathComponent("runtime/renderers/moltenvk/libMoltenVK.dylib").path), "此应用未安装 MoltenVK。")
    }
    if args["--moltenvk"] != nil || args["--renderer"] == "vulkan" {
        let selected = try args["--moltenvk"] ?? configurationValues(app)["--moltenvk"]!
        try check(["stable", "experimental"].contains(selected), "未知 MoltenVK 配置。")
        if selected == "experimental" {
            try check(native || wrapper.contains("moltenvk-experimental"), "请先更新应用包装层。")
            for file in ["libMoltenVK.dylib", "provenance.json"] {
                try check(manager.fileExists(atPath: support.appendingPathComponent("runtime/renderers/moltenvk-experimental/" + file).path),
                          "此应用未安装实验版 MoltenVK；配置未写入。")
            }
        }
    }
    if args["--renderer"] == "dxmt-metalfx" {
        let launch = native ? "" : try String(contentsOf: app.appendingPathComponent("Contents/MacOS/launch.sh"), encoding: .utf8)
        try check(native || (wrapper.contains("nvngx=b;sl.dlss_g,sl.dlss_d,sl.deepdvc=d") &&
                  launch.contains("prepare-metalfx.sh") &&
                  manager.fileExists(atPath: support.appendingPathComponent("scripts/prepare-metalfx.sh").path)),
                  "此应用的旧包装层不支持 MetalFX；配置未写入。")
        for file in ["provenance.json", "x86_64-windows/nvngx.dll", "x86_64-windows/nvapi64.dll"] {
            try check(manager.fileExists(atPath: support.appendingPathComponent("runtime/renderers/dxmt-metalfx/" + file).path),
                      "此应用未安装带 NGX 修复的 DXMT；配置未写入。")
        }
    }
    // Validate every destination before writing; roll back a partial save.
    let changes = configurationFields.compactMap { key, file, fallback -> (URL, String)? in
        args[key].map { (support.appendingPathComponent(file), $0 + "\n") }
    }
    var previous: [URL: Data] = [:]
    for (url, _) in changes {
        if let attrs = try? manager.attributesOfItem(atPath: url.path) {
            try check(attrs[.type] as? FileAttributeType == .typeRegular, "配置路径不是普通文件：\(url.lastPathComponent)")
            previous[url] = try Data(contentsOf: url)
        }
    }
    var written: [URL] = []
    do {
        for (url, value) in changes {
            try writeText(value, url)
            written.append(url)
        }
    } catch {
        var rollbackFailed = false
        for url in written.reversed() {
            do {
                if let data = previous[url] { try data.write(to: url, options: .atomic) }
                else { try manager.removeItem(at: url) }
            } catch { rollbackFailed = true }
        }
        if rollbackFailed { throw ZMDError("配置保存失败，部分旧配置无法恢复，请检查应用目录权限。") }
        throw error
    }
    print("配置已保存，下次启动生效。")
}

let configurationFields = [
    ("--renderer", "renderer.conf", "dxmt"), ("--window", "window-mode.conf", "game"),
    ("--resolution", "resolution.conf", "game"),
    ("--moltenvk", "moltenvk.conf", "stable"), ("--vulkan-queue", "vulkan-queue.conf", "default"),
    ("--hud", "metal-hud.conf", "off"), ("--msync", "msync.conf", "on"),
    ("--settings-window", "settings-window.conf", "on"),
    ("--dxmt-log", "dxmt-log.conf", "default"), ("--wine-log", "wine-log.conf", "errors"),
    ("--shader-cache", "shader-cache.conf", "on"), ("--metal-validation", "metal-validation.conf", "off"),
    ("--shader-validation", "shader-validation.conf", "off"),
]

func configurationValues(_ app: URL) throws -> [String: String] {
    let support = try supportDirectory(app)
    return try Dictionary(uniqueKeysWithValues: configurationFields.map { key, file, fallback in
        let url = support.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: url.path) { return (key, fallback) }
        return (key, try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    })
}
