import Foundation

func testLifecycle() throws {
  let build = work.at("build/native-lifecycle")
  try mkdir(build)
  try compile(
    launcherSources + ["Tests/Fixtures/SessionWorker.swift"], build.at("Endfield"),
    defines: ["LIFECYCLE_TEST"])
  try compile(["Tests/Fixtures/Lifecycle.swift"], build.at("Fixture"))
  try compile(["Tests/CheckLifecycle.swift"], build.at("check"))
  let stage = try temp(build, "session-")
  defer { try? fm.removeItem(at: stage) }
  let app = stage.at("LifecycleTest.app")
  let contents = app.at("Contents")
  let support = contents.at("SharedSupport")
  for path in ["logs", "prefix", "other-prefix"] { try mkdir(support.at(path)) }
  try copy(build.at("Endfield"), contents.at("MacOS/Endfield"))
  try write("off\n", support.at("settings-window.conf"))
  try savePlist(
    [
      "CFBundleExecutable": "Endfield",
      "CFBundleIdentifier": "local.zmdmac.endfield.lifecycle-test", "CFBundlePackageType": "APPL",
      "CFBundleName": "ZMD lifecycle test", "LSUIElement": false,
    ], contents.at("Info.plist"))
  let fixture = support.at("runtime/Fixture.app")
  try copy(build.at("Fixture"), fixture.at("Contents/MacOS/Fixture"))
  try savePlist(
    [
      "CFBundleExecutable": "Fixture",
      "CFBundleIdentifier": "local.zmdmac.endfield.lifecycle-fixture",
      "CFBundlePackageType": "APPL", "CFBundleName": "ZMD session fixture", "LSUIElement": true,
    ], fixture.at("Contents/Info.plist"))
  defer {
    _ = try? command([build.at("check").path, app.path, "--cleanup"], timeout: 10)
    for registered in [fixture, app] {
      _ = try? command([registerTool, "-u", registered.path], allowFailure: true)
    }
  }
  do { try command([build.at("check").path, app.path], timeout: 180) } catch {
    try? clone(support, build.at("failure-" + stage.lastPathComponent))
    throw error
  }
}
func testGraphics(vulkan: Bool, runtime: URL, kosmickrisp: Bool = false) throws {
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
  try compile(coreSources + ["Tests/Fixtures/WineRunner.swift"], runner)
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
func testWineSession(_ runtime: URL) throws {
  let build = work.at("build/wine-session-tests")
  try mkdir(build)
  let compiler = work.at("tools/native/opt/mingw-w64/bin/x86_64-w64-mingw32-gcc").path
  try command([
    compiler, "-O2", "-static", "-mwindows", project.at("Tests/wine-session-fixture.c").path,
    "-luser32", "-o", build.at("fixture.exe").path,
  ])
  try command([
    compiler, "-O2", "-static", "-shared", project.at("Tests/qt-exit-fixture.c").path,
    project.at("Tests/qt-exit-fixture.def").path, "-luser32", "-o", build.at("Qt5Core.dll").path,
  ])
  try compile(
    launcherSources + ["Tests/Fixtures/SessionWorker.swift"], build.at("Endfield"),
    defines: ["LIFECYCLE_TEST", "WINE_SESSION_TEST"])
  try compile(["Tests/check-wine-session.swift"], build.at("check"))
  for selected in ["game", "game-retry", "launcher", "launcher-retry"] {
    let stage = try temp(build, selected + "-")
    defer { try? fm.removeItem(at: stage) }
    let app = stage.at("SessionTest.app")
    let contents = app.at("Contents")
    let support = contents.at("SharedSupport")
    try mkdir(support.at("markers"))
    try clone(runtime, support.at("runtime"))
    try copy(build.at("Endfield"), contents.at("MacOS/Endfield"))
    try write("off\n", support.at("settings-window.conf"))
    for name in ["Endfield.exe", "Games.exe", "QtWebEngineProcess.exe"] {
      try copy(build.at("fixture.exe"), support.at(name))
    }
    try copy(build.at("Qt5Core.dll"), support.at("Qt5Core.dll"))
    try savePlist(
      [
        "CFBundleExecutable": "Endfield", "CFBundlePackageType": "APPL",
        "CFBundleIdentifier": "local.zmdmac.wine-session-test", "LSUIElement": true,
      ], contents.at("Info.plist"))
    var e = env
    e["WINEPREFIX"] = support.at("prefix").path
    defer {
      _ = try? command(
        [support.at("runtime/wine/bin/wineserver").path, "-k"], environment: e, allowFailure: true)
      _ = try? command(
        [support.at("runtime/wine/bin/wineserver").path, "-w"], environment: e, timeout: 30)
      _ = try? command(
        [build.at("check").path, app.path, "--cleanup"], allowFailure: true, timeout: 10)
      _ = try? command([registerTool, "-u", app.path], allowFailure: true)
    }
    do { try command([build.at("check").path, app.path, selected], timeout: 90) } catch {
      try? clone(support.at("logs"), build.at("failure-" + stage.lastPathComponent))
      throw error
    }
  }
}
func testInstall(_ distribution: URL, cn: URL, global: URL) throws {
  let template = try plist(distribution.at("payload/AppTemplate.app/Contents/Info.plist"))
  try require(template["LSUIElement"] as? Bool == true, "Template visible")
  let stage = try temp(fm.temporaryDirectory, "zmd-install-check.noindex-")
  defer { try? fm.removeItem(at: stage) }
  for (region, name, exe) in [("cn", "鹰角启动器", cn), ("global", "GRYPHLINK", global)] {
    let app = stage.at(name + ".app")
    defer {
      if app.exists { _ = try? command([registerTool, "-u", app.path], allowFailure: true) }
    }
    try command(
      [
        distribution.at("zmd").path, "install", "--region", region, "--exe", exe.path, "--output",
        app.path,
      ], timeout: 300)
    let meta = try plist(app.at("Contents/Info.plist"))
    try require(try app.at("Contents/SharedSupport/renderer.conf").text
      .trimmingCharacters(in: .whitespacesAndNewlines) == "kosmickrisp",
      "New installation must default to KosmicKrisp")
    try require(
      !app.link && meta["CFBundleName"] as? String == name
        && meta["CFBundleDisplayName"] as? String == name && meta["LSUIElement"] as? Bool == false,
      "App discovery metadata")
    try require(
      meta["CFBundleShortVersionString"] as? String == template["CFBundleShortVersionString"]
        as? String, "App version")
    let icon = app.at("Contents/Resources/" + (meta["CFBundleIconFile"] as! String))
    try require(try Data(contentsOf: icon).starts(with: Data("icns".utf8)), "Official icon missing")
    try command(["sips", "-s", "format", "png", icon.path, "--out", stage.at(region + ".png").path])
    let records = try command([registerTool, "-dump"], capture: true).output.components(
      separatedBy:
        "--------------------------------------------------------------------------------")
    try require(
      records.contains {
        $0.contains(app.path) && $0.contains(meta["CFBundleIdentifier"] as! String)
      }, "App not registered")
    print("PASS: \(region) installation, official icon and registration")
  }
}
