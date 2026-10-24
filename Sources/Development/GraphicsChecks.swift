import Foundation

// MARK: - Displays and Vulkan presentation

enum GraphicsProbe {
  case displays, moltenVK, kosmicKrisp
}

func testGraphics(_ probe: GraphicsProbe, runtime: URL) throws {
  let vulkan = probe != .displays
  let kosmickrisp = probe == .kosmicKrisp
  let build = work.at(kosmickrisp ? "build/kosmickrisp-tests" : vulkan ? "build/vulkan-tests" : "build/display-tests")
  try mkdir(build)
  let compiler = work.at("tools/native/opt/mingw-w64/bin/x86_64-w64-mingw32-gcc")
  let fixture = build.at("probe.exe")
  try command([
    compiler.path, "-O2", "-static", "-I" + work.at("build/wine-src/include/wine").path,
    project.at(vulkan ? "Tests/vulkan-check.c" : "Tests/display-monitor.c").path, "-luser32", "-o",
    fixture.path,
  ])
  let runner = build.at("wine-runner")
  try compile(runtimeSources + ["Tests/Fixtures/WineRunner.swift"], runner)
  let support = try temp(build, "prefix-")
  defer { try? fm.removeItem(at: support) }
  try fm.createSymbolicLink(at: support.at("runtime"), withDestinationURL: runtime)
  var environment = env
  environment["ZMD_PREFIX"] = support.at("prefix").path
  environment["WINEPREFIX"] = environment["ZMD_PREFIX"]
  environment["ZMD_RENDERER"] = kosmickrisp ? "kosmickrisp" : vulkan ? "vulkan" : "dxmt"
  for key in ["MTL_HUD_ENABLED", "MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION"] {
    environment[key] = "0"
  }
  environment["ZMD_SESSION_ID"] = nil
  let server = runtime.at("wine/bin/wineserver").path
  defer {
    _ = try? command([server, "-k"], environment: environment, allowFailure: true)
    _ = try? command([server, "-w"], environment: environment, timeout: 30)
  }
  var results: [[String: Any]] = []
  for channel in kosmickrisp ? ["kosmickrisp"] : vulkan ? ["stable", "experimental"] : ["stable"] {
    for queue in vulkan && !kosmickrisp ? ["default", "async"] : ["default"] {
      try write(channel + "\n", support.at("moltenvk.conf"))
      try write(queue + "\n", support.at("vulkan-queue.conf"))
      let log = build.at(channel + "-" + queue + ".log")
      try command(
        [runner.path, support.path, fixture.path], environment: environment, timeout: 120, log: log)
      if vulkan {
        try require(
          try log.text.contains("Windowed surface, GPU clear and present: PASS"),
          "GPU probe failed; see \(log.path)")
        if kosmickrisp {
          try require(try log.text.contains("KosmicKrisp"), "Expected KosmicKrisp driver identity")
        }
      } else {
        print(try log.text)
      }
      try command([server, "-w"], environment: environment, timeout: 30)
      results.append(["channel": channel, "queue": queue, "result": "passed"])
      print("PASS: \(channel)/\(queue)")
    }
  }
  try saveJSON(results, build.at("results.json"))
  print("These checks do not verify gameplay, fullscreen, FSR or performance.")
}

// MARK: - Pipeline cache persistence

func testCacheCodec(large: Bool = false) throws {
  let test = work.at("build/tests/cache-codec")
  try mkdir(test.deletingLastPathComponent())
  try command(["xcrun", "clang", "-arch", "x86_64", "-O2", "-Wall", "-Wextra", "-Werror",
               "-Wno-deprecated-declarations", project.at("Tests/cache-codec.c").path,
               "-I" + work.at("tools/x86_64/include").path,
               "-L" + work.at("tools/x86_64/lib").path, "-lzstd",
               "-Wl,-rpath," + work.at("tools/x86_64/lib").path, "-o", test.path])
  try command([test.path] + (large ? ["--large"] : []), timeout: large ? 600 : 30)
}

/// Fresh Wine processes sharing only the test's explicit pipeline cache. No
/// game files are written and no shared Metal/Mesa caches are cleared.
func testKosmicCache(runtime: URL, app: URL?) throws {
  try testCacheCodec()
  if let app {
    try require(app.at("Contents/SharedSupport/prefix/drive_c/users").exists,
                "Expected an installed application with a Wine prefix")
  }
  let build = try temp(work.at("build/kosmickrisp-cache"), "run-")
  let fixture = build.at("probe.exe")
  try command([
    work.at("tools/native/opt/mingw-w64/bin/x86_64-w64-mingw32-gcc").path,
    "-O2", "-static", "-I" + work.at("build/wine-src/include/wine").path,
    project.at("Tests/vulkan-cache-check.c").path, "-o", fixture.path,
  ])
  let runner = build.at("wine-runner")
  try compile(runtimeSources + ["Tests/Fixtures/WineRunner.swift"], runner)
  let support = try temp(build, "prefix-")
  defer { try? fm.removeItem(at: support) }
  try fm.createSymbolicLink(at: support.at("runtime"), withDestinationURL: runtime)
  var e = env
  e["ZMD_PREFIX"] = support.at("prefix").path
  e["WINEPREFIX"] = e["ZMD_PREFIX"]
  e["ZMD_RENDERER"] = "kosmickrisp"
  e["ZMD_SESSION_ID"] = nil
  for key in ["MTL_HUD_ENABLED", "MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION"] { e[key] = "0" }
  // Observe driver-managed disk cache without changing the user's cache.
  for key in Array(e.keys) where key.hasPrefix("MESA_") { e[key] = nil }
  e["MESA_SHADER_CACHE_DIR"] = build.at("mesa-cache").path
  e["MESA_SHADER_CACHE_SHOW_STATS"] = "true"
  let server = runtime.at("wine/bin/wineserver").path
  defer {
    _ = try? command([server, "-k"], environment: e, allowFailure: true)
    _ = try? command([server, "-w"], environment: e, timeout: 30)
  }
  var runs: [[String: Any]] = []
  for mode in ["cold", "warm", "warm-repeat", "cold-repeat"] {
    let log = build.at(mode + ".log")
    try command([runner.path, support.path, fixture.path, mode,
                 "Z:" + build.at("pipeline.bin").path.replacingOccurrences(of: "/", with: "\\")],
                environment: e, timeout: 120, log: log)
    try command([server, "-w"], environment: e, timeout: 30)
    let lines = try log.text.components(separatedBy: .newlines)
    guard let line = lines.first(where: { $0.hasPrefix("CACHE_RESULT ") }),
          let result = try JSONSerialization.jsonObject(with: Data(line.dropFirst(13).utf8)) as? [String: Any]
    else { throw Failure("Missing cache result; see \(log.path)") }
    try require((result["raw_bytes"] as? Int ?? 0) > 4096, "Cache did not cross a 4 KB write boundary")
    if mode.hasPrefix("warm") {
      try require((result["input_bytes"] as? Int ?? 0) > 32, "No complete cache loaded by new process")
      if result["feedback_supported"] as? Bool == true {
        try require(result["feedback_valid"] as? Bool == true && result["cache_hit"] as? Bool == true,
                    "Reloaded cache did not report a valid hit")
      }
    }
    runs.append(result)
    print(line)
  }
  var report: [String: Any] = [
    "recorded_at": ISO8601DateFormatter().string(from: Date()),
    "scope": "64 no-op compute pipelines, header-only query and file round-trip in four independent Wine sessions; not game performance. Timing covers the first pipeline only. Cold means an empty application pipeline cache, not a cleared system Metal cache. The final cold-repeat controls for system cache warmup.",
    "driver": try json(runtime.at("renderers/kosmickrisp/provenance.json")),
    "runs": runs,
    "mesa_disk_files": files(build.at("mesa-cache")).filter { regular($0) }.count,
  ]
  if let app { report["game_snapshot"] = try gameCacheSnapshot(app, expected: runs[0]) }
  try saveJSON(report, build.at("report.json"))
  print("Cache report: \(build.at("report.json").path)")
}

/// Read only known Endfield files. The game wrapper preceding a Vulkan cache
/// header is not a public format; report a candidate, never rewrite it.
private func gameCacheSnapshot(_ app: URL, expected: [String: Any]) throws -> [[String: Any]] {
  let prefix = app.at("Contents/SharedSupport/prefix").resolvingSymlinksInPath()
  let users = prefix.at("drive_c/users")
  guard users.exists else { return [] }
  var results: [[String: Any]] = []
  for profile in try children(users) {
    for vendor in ["Hypergryph", "Gryphline"] {
      let directory = profile.at("AppData/LocalLow/\(vendor)/Endfield")
      let cache = directory.at("vulkan_pso_cache.bin")
      guard regular(cache), !cache.link,
            cache.resolvingSymlinksInPath().path.hasPrefix(prefix.path + "/") else { continue }
      let attrs = try fm.attributesOfItem(atPath: cache.path)
      let file = try FileHandle(forReadingFrom: cache)
      let data = try file.read(upToCount: 64) ?? Data()
      try file.close()
      var result: [String: Any] = ["vendor": vendor, "bytes": attrs[.size] ?? 0,
        "sha256": try digest(cache), "modified": (attrs[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"]
      func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
      }
      if data.count == 64, u32(32) == 32, u32(36) == 1 {
        let uuid = data[48..<64].map { String(format: "%02x", $0) }.joined()
        result["header_candidate_offset"] = 32
        result["payload_bytes_candidate"] = u32(24)
        result["shorter_than_declared_candidate"] = ((attrs[.size] as? NSNumber)?.uint64Value ?? 0) < UInt64(u32(24)) + 32
        result["device"] = u32(44)
        result["uuid"] = uuid
        result["matches_probe"] = Int(u32(40)) == expected["vendor"] as? Int
          && Int(u32(44)) == expected["device"] as? Int && uuid == expected["uuid"] as? String
      }
      for name in ["Player.log", "Player-prev.log"] {
        let log = directory.at(name)
        guard regular(log), !log.link,
              log.resolvingSymlinksInPath().path.hasPrefix(prefix.path + "/") else { continue }
        let handle = try FileHandle(forReadingFrom: log)
        let text = String(decoding: try handle.read(upToCount: 1_048_576) ?? Data(), as: UTF8.self)
        try handle.close()
        result[name] = ["incompatible_header": text.contains("Vulkan PSO: Incompatible header"),
                       "read_failed": text.contains("Vulkan PSO: Failed to read cache data"),
                       "cache_missing": text.contains("Vulkan PSO: cache data not found")]
      }
      results.append(result)
    }
  }
  return results
}
