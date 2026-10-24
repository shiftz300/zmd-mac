import Foundation

@main enum RuntimeTests {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "zmd-runtime-tests-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func at(_ path: String) -> URL { root.appendingPathComponent(path) }
    func put(_ path: String, _ value: String) throws {
      let url = at(path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try writeText(value, url)
    }
    func expectFailure(_ body: () throws -> Void) throws {
      do { try body() } catch { return }
      throw ZMDError("Expected failure")
    }
    var runtime = WineRuntime(support: root, inherited: [:])
    runtime.appleSilicon = true
    try put("runtime/renderers/moltenvk/libMoltenVK.dylib", "fixture")
    for major in [14, 15, 26, 27] {
      runtime.systemMajor = major
      let expected = major >= 26 ? "kosmickrisp" : "vulkan"
      try check(try runtime.selectedRenderer() == expected, "OS-specific default renderer")
    }
    for (major, saved) in [(14, "dxmt"), (14, "dxmt-metalfx"), (14, "kosmickrisp"), (15, "kosmickrisp")] {
      runtime.systemMajor = major
      try put("renderer.conf", saved)
      try check(try runtime.selectedRenderer() == "vulkan", "Unsupported stored renderer fallback")
      try check(try runtime.gameArguments().contains("-force-vulkan"), "Fallback game arguments")
      let fallback = try runtime.environment()
      try check(fallback["CX_LIBVULKAN"] == at("runtime/renderers/moltenvk/libMoltenVK.dylib").path
                && fallback["VK_INSTANCE_LAYERS"] == nil, "Fallback renderer environment")
      if major == 14 {
        try check(fallback["WINEDLLPATH_PREPEND"] == nil && fallback["WINEDLLPATH_DXMT"] == nil,
                  "macOS 14 must not load DXMT")
      }
      try expectFailure { try RendererSupport.require(saved, on: major) }
      runtime.inherited["ZMD_RENDERER"] = saved
      try expectFailure { _ = try runtime.environment() }
      runtime.inherited = [:]
    }
    runtime.systemMajor = 26
    runtime.appleSilicon = false
    try put("renderer.conf", "kosmickrisp")
    try check(RendererSupport.defaultRenderer(on: 26, apple: false) == "vulkan", "Intel default")
    try check(try runtime.selectedRenderer() == "vulkan", "Intel saved KosmicKrisp fallback")
    try check(try runtime.environment()["ROSETTA_ADVERTISE_AVX"] == nil, "Intel must not set Rosetta flags")
    try expectFailure { try RendererSupport.require("kosmickrisp", on: 26, apple: false) }
    runtime.appleSilicon = RendererSupport.appleSilicon
    runtime.systemMajor = RendererSupport.systemMajor
    try put("renderer.conf", "dxmt")
    print("PASS: macOS 14/15/26/27 defaults, renderer fallback and explicit selection guards")
    try put("msync.conf", "off")
    try put("metal-hud.conf", "on")
    var env = try runtime.environment()
    try check(
      env["WINEMSYNC"] == "0" && env["MTL_HUD_ENABLED"] == "1"
        && env["WINEPREFIX"] == at("prefix").path, "MSync/HUD/prefix")
    for file in ["provenance.json", "x86_64-windows/nvngx.dll", "x86_64-windows/nvapi64.dll"] {
      try put("runtime/renderers/dxmt-metalfx/" + file, "test")
    }
    try put("renderer.conf", "dxmt-metalfx")
    env = try runtime.environment()
    try check(
      env["DXMT_ENABLE_NVEXT"] == "1"
        && env["WINEDLLOVERRIDES"]!.hasSuffix("nvngx=b;sl.dlss_g,sl.dlss_d,sl.deepdvc=d"),
      "MetalFX flags")
    runtime.inherited = [
      "DXMT_ENABLE_NVEXT": "1", "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS": "garbage",
      "CX_LIBVULKAN": "stale",
      "VK_ICD_FILENAMES": "stale", "VK_DRIVER_FILES": "stale", "VK_ADD_DRIVER_FILES": "stale",
      "VK_LOADER_DRIVERS_SELECT": "stale", "VK_LOADER_DRIVERS_DISABLE": "stale",
      "VK_LOADER_SEARCH_ONLY_IN_BUNDLE": "TRUE",
      "VK_LAYER_PATH": "stale", "VK_ADD_LAYER_PATH": "stale", "VK_INSTANCE_LAYERS": "stale",
    ]
    try put("renderer.conf", "vulkan")
    for channel in ["stable", "experimental"] {
      let directory = channel == "stable" ? "moltenvk" : "moltenvk-experimental"
      try put("runtime/renderers/" + directory + "/libMoltenVK.dylib", "fixture")
      try put("moltenvk.conf", channel)
      for queue in ["default", "async"] {
        try put("vulkan-queue.conf", queue)
        env = try runtime.environment()
        try check(
          env["CX_LIBVULKAN"] == at("runtime/renderers/" + directory + "/libMoltenVK.dylib").path
            && env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] == (queue == "default" ? "1" : "0")
            && env["DXMT_ENABLE_NVEXT"] == nil, "Vulkan selection")
      }
    }
    try put("renderer.conf", "kosmickrisp")
    try expectFailure { _ = try runtime.environment() }
    for file in ["libvulkan.1.dylib", "libvulkan_kosmickrisp.dylib", "kosmickrisp_icd.json", "provenance.json",
                 "cache/libzmd_cache.dylib", "cache/cache_layer.json", "cache/provenance.json"] {
      try put("runtime/renderers/kosmickrisp/" + file, "fixture")
    }
    env = try runtime.environment()
    try check(env["CX_LIBVULKAN"] == at("runtime/renderers/kosmickrisp/libvulkan.1.dylib").path
      && env["VK_DRIVER_FILES"] == at("runtime/renderers/kosmickrisp/kosmickrisp_icd.json").path
      && env["CX_ACTIVE_GRAPHICS_BACKEND"] == "wined3d"
      && env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] == nil
      && env["DXMT_ENABLE_NVEXT"] == nil, "KosmicKrisp loader and driver isolation")
    try check(env["VK_LAYER_PATH"] == at("runtime/renderers/kosmickrisp/cache").path
      && env["VK_INSTANCE_LAYERS"] == "VK_LAYER_ZMD_pipeline_cache"
      && env["VK_ADD_LAYER_PATH"] == nil, "KosmicKrisp cache layer isolation")
    try check(try runtime.gameArguments() == "-force-vulkan", "KosmicKrisp uses game Vulkan")
    for key in ["VK_ICD_FILENAMES", "VK_ADD_DRIVER_FILES", "VK_LOADER_DRIVERS_SELECT",
                "VK_LOADER_DRIVERS_DISABLE", "VK_LOADER_SEARCH_ONLY_IN_BUNDLE"] {
      try check(env[key] == nil, "Inherited Vulkan driver selection leaked")
    }
    try put("renderer.conf", "vulkan")
    env = try runtime.environment()
    try check(env["VK_DRIVER_FILES"] == nil && env["CX_LIBVULKAN"]!.contains("libMoltenVK")
              && env["VK_LAYER_PATH"] == nil && env["VK_INSTANCE_LAYERS"] == nil,
              "Switch back to MoltenVK")
    try put("renderer.conf", "dxmt")
    env = try runtime.environment()
    try check(
      env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] == nil && env["CX_LIBVULKAN"] == nil
        && env["DXMT_ENABLE_NVEXT"] == nil && env["VK_DRIVER_FILES"] == nil, "Stale renderer variables")
    for (name, value) in [
      ("dxmt-log", "debug"), ("wine-log", "warnings"), ("shader-cache", "off"),
      ("metal-validation", "on"), ("shader-validation", "on"),
    ] { try put(name + ".conf", value) }
    env = try runtime.environment()
    try check(
      env["WINEDEBUG"] == "-all,err+all,warn+all" && env["DXMT_LOG_LEVEL"] == "debug"
        && env["DXMT_SHADER_CACHE"] == "0" && env["MTL_DEBUG_LAYER"] == "1"
        && env["MTL_SHADER_VALIDATION"] == "1", "Debug choices")
    try put("dxmt-log.conf", "default")
    runtime.inherited["DXMT_LOG_LEVEL"] = "debug"
    try check(
      try runtime.environment()["DXMT_LOG_LEVEL"] == nil, "Default log removes inherited value")
    try put("shader-cache.conf", "invalid")
    try expectFailure { _ = try runtime.environment() }
    try put("shader-cache.conf", "on")
    // Exercise the real Process path using a native recording executable.
    let probe = URL(fileURLWithPath: CommandLine.arguments[1])
    let bin = at("runtime/wine/bin")
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["wine", "wineserver"] {
      try fm.copyItem(at: probe, to: bin.appendingPathComponent(name))
    }
    runtime.inherited["ZMD_PROBE_MODE"] = "reg"
    try put("renderer.conf", "vulkan")
    try put("moltenvk.conf", "stable")
    try put("vulkan-queue.conf", "default")
    for (mode, suffix) in [
      ("game", ""), ("windowed", " -screen-fullscreen 0"),
      ("fullscreen", " -screen-fullscreen 1 -window-mode borderless"),
    ] {
      try put("window-mode.conf", mode)
      for size in ["game", "3840x2160"] {
        try put("resolution.conf", size)
        try check(try runtime.session(attach: false) == 0, "Native session failed")
        let args =
          try JSONSerialization.jsonObject(with: Data(contentsOf: at("captured-args"))) as! [String]
        let expected =
          "-force-vulkan" + suffix
          + (size == "game" ? "" : " -screen-width 3840 -screen-height 2160")
        try check(args[args.firstIndex(of: "/d")! + 1] == expected, "Wrong registered arguments")
      }
    }
    try put("resolution.conf", "1920x1080;touch injected")
    try fm.removeItem(at: at("captured-args"))
    try expectFailure { _ = try runtime.session(attach: false) }
    try check(!fm.fileExists(atPath: at("captured-args").path), "Invalid display changed registry")
    try put("resolution.conf", "game")
    runtime.inherited["ZMD_PROBE_EXIT"] = "7"
    try check(try runtime.session(attach: false) == 7, "Launcher failure lost")
    // NGX preparation, update, rollback, external modifications and symlinks.
    let prefix = at("ngx")
    let target = prefix.appendingPathComponent("drive_c/windows/system32/nvngx.dll")
    let state = prefix.appendingPathComponent(".zmd-metalfx-ngx")
    let game = prefix.appendingPathComponent(
      "drive_c/EndfieldLauncher/games/Arknights Endfield/nvngx_dlss.dll")
    func data(_ file: URL, _ value: String) throws {
      try fm.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(value.utf8).write(to: file)
    }
    func contents(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }
    try data(target, "original")
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try check(
      try contents(target) == "original" && !fm.fileExists(atPath: state.path),
      "Missing game should preserve entry")
    try data(game, "signed fixture")
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try check(
      try contents(target) == "signed fixture"
        && contents(state.appendingPathComponent("original.dll")) == "original", "Prepare NGX")
    try data(game, "updated")
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try prepareNGX(prefix: prefix, mode: "vulkan")
    try check(try contents(target) == "original", "Rollback NGX")
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try data(target, "external")
    try expectFailure { try prepareNGX(prefix: prefix, mode: "vulkan") }
    try check(try contents(target) == "external", "External edit overwritten")
    try data(target, "updated")
    let backup = state.appendingPathComponent("original.dll")
    let held = state.appendingPathComponent("held")
    try fm.moveItem(at: backup, to: held)
    try expectFailure { try prepareNGX(prefix: prefix, mode: "dxmt") }
    try fm.moveItem(at: held, to: backup)
    try prepareNGX(prefix: prefix, mode: "dxmt")
    let original = prefix.appendingPathComponent("runtime-original.dll")
    try data(original, "runtime")
    try fm.removeItem(at: target)
    try fm.createSymbolicLink(at: target, withDestinationURL: original)
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try check(
      try contents(original) == "runtime" && contents(target) == "updated",
      "NGX symlink changed shared runtime")
    try prepareNGX(prefix: prefix, mode: "vulkan")
    try check(try contents(target) == "runtime", "Restore symlink content")
    try fm.removeItem(at: target)
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try fm.removeItem(at: game)
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try check(!fm.fileExists(atPath: target.path), "Game removal rollback")
    let global = prefix.appendingPathComponent(
      "drive_c/EndfieldLauncher/games/EndField Game/nvngx_dlss.dll")
    try data(global, "global")
    try prepareNGX(prefix: prefix, mode: "dxmt-metalfx")
    try check(try contents(target) == "global", "Global discovery")
    try prepareNGX(prefix: prefix, mode: "vulkan")
    try check(!fm.fileExists(atPath: target.path), "Absent entry rollback")
    print(
      "PASS: native Wine environment, all display modes, process exit status, NGX update/rollback and preservation"
    )
  }
}
