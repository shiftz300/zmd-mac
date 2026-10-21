import Darwin
import Foundation

/// Shared by installation and the background session. No shell expansion.
struct WineRuntime {
  let support: URL
  var inherited = ProcessInfo.processInfo.environment
  var prefix: URL {
    URL(fileURLWithPath: inherited["ZMD_PREFIX"] ?? support.appendingPathComponent("prefix").path)
  }
  var runtime: URL { support.appendingPathComponent("runtime") }
  func setting(_ name: String, _ fallback: String) throws -> String {
    let file = support.appendingPathComponent(name + ".conf")
    guard FileManager.default.fileExists(atPath: file.path) else { return fallback }
    return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines)
  }
  func environment() throws -> [String: String] {
    var env = inherited
    env["WINEPREFIX"] = prefix.path
    env["WINEDEBUG"] = env["WINEDEBUG"] ?? "-all,err+all"
    if FileManager.default.fileExists(atPath: support.appendingPathComponent("wine-log.conf").path)
    {
      let value = try setting("wine-log", "errors")
      let levels = ["errors": "-all,err+all", "warnings": "-all,err+all,warn+all", "off": "-all"]
      try check(levels[value] != nil, "Unknown Wine log level: \(value)")
      env["WINEDEBUG"] = levels[value]
    }
    if FileManager.default.fileExists(atPath: support.appendingPathComponent("dxmt-log.conf").path)
    {
      let value = try setting("dxmt-log", "default")
      try check(["default", "error", "debug", "none"].contains(value), "Unknown DXMT log level")
      env["DXMT_LOG_LEVEL"] = value == "default" ? nil : value
    }
    for (file, variable) in [
      ("shader-cache", "DXMT_SHADER_CACHE"), ("metal-validation", "MTL_DEBUG_LAYER"),
      ("shader-validation", "MTL_SHADER_VALIDATION"), ("metal-hud", "MTL_HUD_ENABLED"),
    ] {
      if FileManager.default.fileExists(atPath: support.appendingPathComponent(file + ".conf").path)
      {
        let value = try setting(file, "off")
        try check(["on", "off"].contains(value), "Unknown \(file) value")
        env[variable] = value == "on" ? "1" : "0"
      }
    }
    let sync = try env["ZMD_MSYNC"].flatMap { $0.isEmpty ? nil : $0 } ?? setting("msync", "on")
    try check(["on", "off", "1", "0"].contains(sync), "Unknown MSync selection")
    env["WINEMSYNC"] = ["on", "1"].contains(sync) ? "1" : "0"
    env["ROSETTA_ADVERTISE_AVX"] = "1"
    env["WINEDLLPATH"] = runtime.appendingPathComponent("wine/lib/wine").path
    env["WINEDLLPATH_DXMT"] = runtime.appendingPathComponent("renderers/dxmt").path
    env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] = "1"
    for name in [
      "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "DXMT_ENABLE_NVEXT", "CX_LIBVULKAN",
      "CX_ACTIVE_GRAPHICS_BACKEND",
    ] { env[name] = nil }
    var overrides = env["WINEDLLOVERRIDES"] ?? "winemenubuilder.exe=d;mscoree,mshtml="
    let selected =
      try env["ZMD_RENDERER"].flatMap { $0.isEmpty ? nil : $0 } ?? setting("renderer", "dxmt")
    switch selected {
    case "dxmt": break
    case "dxmt-metalfx":
      let backend = runtime.appendingPathComponent("renderers/dxmt-metalfx")
      for file in ["provenance.json", "x86_64-windows/nvapi64.dll", "x86_64-windows/nvngx.dll"] {
        try check(
          FileManager.default.fileExists(atPath: backend.appendingPathComponent(file).path),
          "Patched DXMT MetalFX is not installed")
      }
      env["WINEDLLPATH_DXMT"] = backend.path
      env["DXMT_ENABLE_NVEXT"] = "1"
      overrides += ";nvngx=b;sl.dlss_g,sl.dlss_d,sl.deepdvc=d"
    case "vulkan":
      let channel = try setting("moltenvk", "stable")
      let queue = try setting("vulkan-queue", "default")
      try check(["stable", "experimental"].contains(channel), "Unknown MoltenVK version")
      try check(["default", "async"].contains(queue), "Unknown Vulkan queue mode")
      let library = runtime.appendingPathComponent(
        "renderers/\(channel == "stable" ? "moltenvk" : "moltenvk-experimental")/libMoltenVK.dylib")
      try check(FileManager.default.fileExists(atPath: library.path), "MoltenVK is not installed")
      env["CX_LIBVULKAN"] = library.path
      env["CX_ACTIVE_GRAPHICS_BACKEND"] = "wined3d"
      env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] = queue == "default" ? "1" : "0"
    default: throw ZMDError("Unknown renderer: \(selected)")
    }
    env["WINEDLLPATH_PREPEND"] = env["WINEDLLPATH_DXMT"]
    env["WINEDLLOVERRIDES"] = overrides
    env["DYLD_FALLBACK_LIBRARY_PATH"] =
      "\(runtime.path)/wine/lib:\(runtime.path)/wine/lib/wine/x86_64-unix:/usr/lib"
    env["SSL_CERT_FILE"] = runtime.appendingPathComponent("ca-bundle.crt").path
    return env
  }
  func gameArguments() throws -> String {
    let renderer = try setting("renderer", "dxmt")
    let window = try setting("window-mode", "game")
    let resolution = try setting("resolution", "game")
    try validateConfiguration([
      "--renderer": renderer, "--window": window, "--resolution": resolution,
    ])
    var flags = renderer == "vulkan" ? "-force-vulkan" : "-force-d3d11"
    if window == "windowed" { flags += " -screen-fullscreen 0" }
    if window == "fullscreen" { flags += " -screen-fullscreen 1 -window-mode borderless" }
    if resolution != "game" {
      let parts = resolution.split(separator: "x")
      flags += " -screen-width \(parts[0]) -screen-height \(parts[1])"
    }
    return flags
  }
  @discardableResult
  func execute(
    _ arguments: [String], server: Bool = false, log: FileHandle? = nil,
    prepared: [String: String]? = nil
  ) throws -> Int32 {
    let p = Process()
    p.executableURL = runtime.appendingPathComponent("wine/bin/" + (server ? "wineserver" : "wine"))
    p.arguments = arguments
    if server {
      var serverEnvironment = inherited
      serverEnvironment["WINEPREFIX"] = prefix.path
      p.environment = serverEnvironment
    } else {
      p.environment = try prepared ?? environment()
    }
    p.currentDirectoryURL = support
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = log ?? FileHandle.standardOutput
    p.standardError = log ?? FileHandle.standardError
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }
  func session(attach: Bool) throws -> Int32 {
    if attach { return try execute(["-w"], server: true) }
    let flags = try gameArguments()
    let mode = try setting("renderer", "dxmt")
    var selected = self
    selected.inherited["ZMD_RENDERER"] = mode
    let prepared = try selected.environment()
    try prepareNGX(prefix: prefix, mode: mode)
    print("Renderer: \(mode); game arguments: \(flags)")
    let status = try execute(
      [
        "reg", "add", "HKCU\\Software\\Wine\\AppDefaults\\Endfield.exe", "/v", "CommandLineAppend",
        "/t", "REG_SZ", "/d", flags, "/f",
      ], prepared: prepared)
    try check(status == 0, "Failed to configure game arguments: \(status)")
    let result = try execute(["C:\\EndfieldLauncher\\Launcher.exe"], prepared: prepared)
    let waited = try execute(["-w"], server: true)
    return result == 0 ? waited : result
  }
}

/// Keep the signed NGX discovery entry in the prefix, never in the game directory.
func prepareNGX(prefix: URL, mode: String) throws {
  let fm = FileManager.default
  try check(["dxmt", "dxmt-metalfx", "vulkan"].contains(mode), "Unknown renderer")
  let state = prefix.appendingPathComponent(".zmd-metalfx-ngx")
  let target = prefix.appendingPathComponent("drive_c/windows/system32/nvngx.dll")
  var source = prefix.appendingPathComponent(
    "drive_c/EndfieldLauncher/games/Arknights Endfield/nvngx_dlss.dll")
  if !fm.fileExists(atPath: source.path) {
    source = prefix.appendingPathComponent(
      "drive_c/EndfieldLauncher/games/EndField Game/nvngx_dlss.dll")
  }
  func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
  func record(_ name: String) -> URL { state.appendingPathComponent(name) }
  func hash(_ url: URL) -> String? { try? sha256(url) }
  func text(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func atomicCopy(_ from: URL) throws {
    let temp = target.deletingLastPathComponent().appendingPathComponent(
      ".ngx-" + UUID().uuidString)
    defer { try? fm.removeItem(at: temp) }
    // Data.write replaces a symlink itself, without mutating its destination.
    try Data(contentsOf: from).write(to: temp)
    try check(rename(temp.path, target.path) == 0, "Cannot replace NGX entry")
  }
  if exists(state) {
    let matched = ["installed.sha256", "pending.sha256", "original.sha256"].contains { name in
      if let stored = text(record(name)), let current = hash(target) { return stored == current }
      return false
    }
    let attrs = try? fm.attributesOfItem(atPath: target.path)
    try check(
      matched || (exists(record("original.absent")) && attrs == nil),
      "NGX entry changed externally; backup retained")
    if exists(record("original.dll")) {
      guard let expected = text(record("original.sha256")),
        let actual = hash(record("original.dll")), actual == expected
      else {
        throw ZMDError("NGX original backup checksum mismatch")
      }
    } else {
      try check(exists(record("original.absent")), "NGX original backup missing")
    }
  }
  if mode != "dxmt-metalfx" || !exists(source) {
    if exists(state) {
      if exists(record("original.dll")) {
        try atomicCopy(record("original.dll"))
      } else if (try? fm.attributesOfItem(atPath: target.path)) != nil {
        try fm.removeItem(at: target)
      }
      for name in [
        "original.dll", "original.sha256", "original.absent", "installed.sha256", "pending.sha256",
      ] {
        if exists(record(name)) { try fm.removeItem(at: record(name)) }
      }
      // Refuse to remove unexpected files in the backup directory.
      try check(rmdir(state.path) == 0, "Unexpected NGX backup files retained")
    }
    return
  }
  try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
  if !exists(state) {
    let temp = prefix.appendingPathComponent(".ngx-backup-" + UUID().uuidString)
    try fm.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: temp) }
    if exists(target), let bytes = try? Data(contentsOf: target) {
      try bytes.write(to: temp.appendingPathComponent("original.dll"))
      try writeText(
        try sha256(temp.appendingPathComponent("original.dll")) + "\n",
        temp.appendingPathComponent("original.sha256"))
    } else {
      try check((try? fm.attributesOfItem(atPath: target.path)) == nil, "Unexpected NGX entry type")
      try Data().write(to: temp.appendingPathComponent("original.absent"))
    }
    try fm.moveItem(at: temp, to: state)
  }
  let digest = try sha256(source)
  if hash(target) != digest {
    try writeText(digest + "\n", record("pending.sha256"))
    try atomicCopy(source)
  }
  try writeText(digest + "\n", record("installed.sha256"))
  if exists(record("pending.sha256")) { try fm.removeItem(at: record("pending.sha256")) }
}
