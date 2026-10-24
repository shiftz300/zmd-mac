import Foundation

func expectFailure(_ body: () throws -> Void) throws {
  do { try body() } catch { return }
  throw Failure("Expected operation to fail")
}
func testCLI(_ executable: URL) throws {
  let root = try temp(fm.temporaryDirectory, "zmd cli ")
  defer { try? fm.removeItem(at: root) }
  let app = root.at("Example.app")
  let support = app.at("Contents/SharedSupport")
  try write("fixture", app.at("Contents/MacOS/Endfield"))
  try write("1\n", support.at("runtime-interface"))
  try savePlist(["CFBundleIdentifier": "local.zmdmac.endfield.test"], app.at("Contents/Info.plist"))
  try write("keep", app.at("do-not-overwrite"))
  func cli(_ args: [String], fails: Bool = false) throws -> String {
    let result = try command([executable.path] + args, capture: true, allowFailure: true)
    try require((result.status != 0) == fails, "Unexpected CLI result: \(args)")
    return result.output
  }
  func configure(_ args: [String], fails: Bool = false) throws {
    _ = try cli(["configure", "--app", app.path] + args, fails: fails)
  }
  func inspect() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(cli(["inspect", "--app", app.path]).utf8))
      as! [String: Any]
  }
  for region in ["cn", "global", "invalid"] {
    _ = try cli(["install", "--region", region, "--output", app.path], fails: true)
  }
  try require(try app.at("do-not-overwrite").text == "keep", "Existing app overwritten")
  try configure(["--renderer", "dxmt", "--hud", "on", "--msync", "off", "--window", "windowed"])
  var report = try inspect()
  try require(
    report["renderer"] as? String == "dxmt" && report["metal_hud"] as? String == "on"
      && report["msync"] as? String == "off", "CLI configuration")
  try configure(["--settings-window", "off"])
  report = try inspect()
  try require(report["settings_window"] as? String == "off", "Startup preference")
  try configure(["--settings-window", "invalid", "--renderer", "vulkan"], fails: true)
  try configure(["--retina", "on"], fails: true)
  try write("2\n", support.at("runtime-interface"))
  for mode in ["auto", "on", "off"] {
    try configure(["--retina", mode])
    try require(try inspect()["retina"] as? String == mode, "Retina readback")
  }
  try configure(["--retina", "invalid"], fails: true)
  try require(try support.at("retina.conf").text == "off\n", "Invalid Retina mutated config")
  try fm.removeItem(at: support.at("metal-hud.conf"))
  try mkdir(support.at("metal-hud.conf"))
  try configure(["--renderer", "dxmt", "--msync", "on", "--hud", "off"], fails: true)
  try require(try support.at("msync.conf").text == "off\n", "Partial config save")
  try fm.removeItem(at: support.at("metal-hud.conf"))
  try write("on\n", support.at("metal-hud.conf"))
  for size in ["1920x1080", "3840x2160", "3440x1440", "game"] {
    try configure(["--resolution", size, "--window", "fullscreen"])
    try require(try inspect()["resolution"] as? String == size, "Resolution readback")
  }
  for size in [
    "0x0", "03120x1440", "99999x1080", "1920x1080 -bad", "1920x1080;touch nope", "hello", "-1x1080",
  ] {
    try configure(["--resolution", size, "--hud", "off"], fails: true)
    try require(
      try support.at("metal-hud.conf").text == "on\n", "Invalid resolution mutated config")
  }
  // Old wrappers can still be inspected/configured, but unsupported new settings fail before writes.
  try fm.removeItem(at: support.at("runtime-interface"))
  try write("legacy", support.at("scripts/wine.sh"))
  try write("legacy", app.at("Contents/MacOS/launch.sh"))
  try configure(["--hud", "off"], fails: true)
  try configure(["--resolution", "1920x1080"], fails: true)
  try write("1\n", support.at("runtime-interface"))
  for args in [
    ["--renderer", "dxmt-metalfx"], ["--renderer", "vulkan"],
    ["--moltenvk", "experimental", "--vulkan-queue", "async"],
  ] { try configure(args + ["--hud", "off"], fails: true) }
  try require(
    try support.at("metal-hud.conf").text == "on\n", "Unavailable backend mutated settings")
  for file in [
    "moltenvk/libMoltenVK.dylib", "moltenvk-experimental/libMoltenVK.dylib",
    "moltenvk-experimental/provenance.json", "dxmt-metalfx/provenance.json",
    "dxmt-metalfx/x86_64-windows/nvngx.dll", "dxmt-metalfx/x86_64-windows/nvapi64.dll",
  ] { try write("{}", support.at("runtime/renderers/" + file)) }
  try configure(["--renderer", "dxmt-metalfx"])
  for channel in ["stable", "experimental"] {
    for queue in ["default", "async"] {
      try configure(["--renderer", "vulkan", "--moltenvk", channel, "--vulkan-queue", queue])
      report = try inspect()
      try require(
        report["moltenvk_channel"] as? String == channel
          && report["vulkan_queue"] as? String == queue, "Renderer settings")
    }
  }
  // A new renderer cannot be selected by an old application or with partial components.
  for interface in ["1", "2", "3"] {
    try write(interface + "\n", support.at("runtime-interface"))
    try configure(["--renderer", "kosmickrisp", "--hud", "off"], fails: true)
    try require(try support.at("metal-hud.conf").text == "on\n", "Unavailable renderer mutated HUD")
  }
  for file in ["libvulkan.1.dylib", "libvulkan_kosmickrisp.dylib", "kosmickrisp_icd.json", "provenance.json",
               "cache/libzmd_cache.dylib", "cache/cache_layer.json", "cache/provenance.json"] {
    try write("{}", support.at("runtime/renderers/kosmickrisp/" + file))
  }
  try write("2\n", support.at("runtime-interface"))
  try configure(["--renderer", "kosmickrisp"], fails: true)
  try write("3\n", support.at("runtime-interface"))
  try configure(["--renderer", "kosmickrisp", "--retina", "auto"])
  try require(try inspect()["renderer"] as? String == "kosmickrisp", "KosmicKrisp CLI readback")
  try configure(["--renderer", "vulkan", "--moltenvk", "stable"])
  try require(try inspect()["renderer"] as? String == "vulkan", "MoltenVK rollback")
  print(
    "PASS: CLI preservation, atomic configuration, legacy wrapper rejection and backend availability"
  )
}
func testPatches() throws {
  let root = try temp()
  defer { try? fm.removeItem(at: root) }
  let source = root.at(".work/build/wine-src")
  let file = source.at("sample")
  let patch = root.at("sample.patch")
  try write("before\n", file)
  try command(["git", "init", "-q", root.path])
  try write(
    "diff --git a/sample b/sample\n--- a/sample\n+++ b/sample\n@@ -1 +1 @@\n-before\n+after\n",
    patch)
  try ensurePatch(patch, source, idempotent: false)
  try require(try file.text == "after\n", "Patch skipped")
  try write("before\n", file)
  try ensurePatch(patch, source)
  try ensurePatch(patch, source)
  try require(try file.text == "after\n", "Patch idempotence reversed patch")
  print("PASS: nested checkout patch application and idempotence")
}
func testRelease() throws {
  let directory = try temp()
  defer { try? fm.removeItem(at: directory) }
  for name in releaseAssets { try write("fixture", directory.at(name)) }
  let source = directory.at("zmd-mac")
  let archive = directory.at("zmd-mac-macos-arm64.zip")
  try savePlist(
    ["CFBundleShortVersionString": "0.5.0"],
    source.at("payload/AppTemplate.app/Contents/Info.plist"))
  try fm.removeItem(at: archive)
  try command(["ditto", "-c", "-k", "--keepParent", source.path, archive.path])
  for name in releaseAssets { try checksumFile(directory.at(name)) }
  try require(
    try !verifyRelease("v0.5.0", directory) && verifyRelease("v0.5.0-rc.1", directory),
    "Release tag classification")
  for tag in ["main", "v0.6.0", "v0.5.0;echo"] {
    try expectFailure { _ = try verifyRelease(tag, directory) }
  }
  for scenario in ["new", "resume", "published", "other-commit", "upload-failed", "incomplete"] {
    var commands: [[String]] = []
    let runner: ReleaseRunner = { args, _ in
      commands.append(args)
      if args[2] == "view", args.last == "isDraft,targetCommitish" {
        if scenario == "new" || scenario == "upload-failed" || scenario == "incomplete" {
          return CommandResult(status: 1, output: "")
        }
        let existing: [String: Any] = [
          "isDraft": scenario != "published",
          "targetCommitish": scenario == "other-commit" ? "other" : "abc123",
        ]
        return CommandResult(
          status: 0,
          output: String(
            decoding: try JSONSerialization.data(withJSONObject: existing), as: UTF8.self))
      }
      if args[2] == "upload", scenario == "upload-failed" {
        throw Failure("Simulated upload failure")
      }
      if args.last == "assets" {
        let names = scenario == "incomplete" ? Array(releaseAssets.dropLast()) : releaseAssets
        let assets: [[String: Any]] = try names.map {
          ["name": $0, "size": try fm.attributesOfItem(atPath: directory.at($0).path)[.size]!]
        }
        return CommandResult(
          status: 0,
          output: String(
            decoding: try JSONSerialization.data(withJSONObject: ["assets": assets]), as: UTF8.self)
        )
      }
      return CommandResult(status: 0, output: "")
    }
    let good = ["new", "resume"].contains(scenario)
    let action = {
      try publishRelease(
        "v0.5.0-rc.1", directory, checkOnly: false, repository: "owner/repo", commit: "abc123",
        runner: runner)
    }
    if good { try action() } else { try expectFailure(action) }
    try require(commands.contains { $0[2] == "edit" } == good, "Bad release published")
    if good {
      try require(
        commands.last!.contains("--latest=false") && commands.last!.contains("--prerelease=true"),
        "Prerelease classification lost")
    }
    try require(
      !commands.flatMap { $0 }.contains {
        $0.hasSuffix(".sha256") || $0.hasSuffix("zmd-mac-source.zip")
      }, "Unexpected release asset")
  }
  try write("corrupt", directory.at(releaseAssets[0]))
  try expectFailure { _ = try verifyRelease("v0.5.0", directory) }
  try fm.removeItem(at: directory.at(releaseAssets[0]))
  try expectFailure { _ = try verifyRelease("v0.5.0", directory) }
  print("PASS: release checksums, versions, draft resume and failure boundaries")
}
func testQuick() throws {
  let build = work.at("build/tests")
  for file in files(project.at("Resources")) where ["sh", "command"].contains(file.pathExtension) {
    try command(["bash", "-n", file.path])
  }
  try compile(runtimeSources + ["Tests/main.swift"], build.at("core"))
  try command([build.at("core").path])
  try compile(cliSources, build.at("zmd"))
  try command([build.at("zmd").path, "--help"])
  try testCLI(build.at("zmd"))
  try compile(["Tests/Fixtures/RuntimeProbe.swift"], build.at("probe"))
  try compile(runtimeSources + ["Tests/RuntimeTests.swift"], build.at("runtime-tests"))
  try command([build.at("runtime-tests").path, build.at("probe").path])
  try compile(settingsSources + ["Tests/DisplayResolutionTests.swift"], build.at("display-resolution-tests"))
  try command([build.at("display-resolution-tests").path])
  try compile(runtimeSources + ["Tests/GameResolutionTests.swift"], build.at("game-resolution-tests"))
  try command([build.at("game-resolution-tests").path])
  try compile(launcherSources, build.at("Endfield"))
  try testPatches()
  try testRelease()
  print("PASS: all quick checks")
}
func testPKG(_ package: URL, staticOnly: Bool) throws {
  let stage = try temp()
  defer { try? fm.removeItem(at: stage) }
  let expanded = stage.at("expanded")
  try command(["pkgutil", "--expand-full", package.path, expanded.path])
  let distribution = try XMLDocument(contentsOf: expanded.at("Distribution"))
  let payload = expanded.at("runtime.pkg/Payload/payload")
  func nodes(_ path: String, _ doc: XMLDocument) throws -> [XMLNode] {
    try doc.nodes(forXPath: path)
  }
  try require(
    try nodes("/installer-gui-script/options[@customize='always']", distribution).count == 1,
    "Missing custom installer choices")
  let choices = try nodes("/installer-gui-script/choice", distribution) as! [XMLElement]
  try require(
    Set(choices.compactMap { $0.attribute(forName: "id")?.stringValue }) == [
      "runtime", "cn", "global",
    ], "Wrong region choices")
  let meta = try plist(payload.at("AppTemplate.app/Contents/Info.plist"))
  let v = meta["CFBundleShortVersionString"] as! String
  try require(meta["LSUIElement"] as? Bool == true, "Template visible")
  try require(
    try children(payload).filter { $0.pathExtension == "app" }.count == 1,
    "Unexpected extra application")
  for region in ["runtime", "cn", "global"] {
    let component = expanded.at(region + ".pkg")
    let info = try XMLDocument(contentsOf: component.at("PackageInfo"))
    try require(
      info.rootElement()?.attribute(forName: "version")?.stringValue == v,
      "Component version differs")
    try require(
      try nodes(
        "/installer-gui-script/pkg-ref[@id='local.zmdmac.installer.\(region)'][@version='\(v)']",
        distribution
      ).count == 1, "Distribution version differs")
    let choice = choices.first { $0.attribute(forName: "id")?.stringValue == region }!
    try require(
      choice.attribute(forName: "start_selected")?.stringValue
        == (region == "global" ? "false" : "true"), "Wrong default choice")
    if region == "runtime" {
      try require(
        choice.attribute(forName: "selected")?.stringValue == "true", "Runtime not mandatory")
      continue
    }
    let name = region == "cn" ? "鹰角启动器" : "GRYPHLINK"
    try require(
      choice.attribute(forName: "description")!.stringValue!.contains(
        "~/Applications/" + name + ".app"), "Wrong application path")
    let post = try nodes("/pkg-info/scripts/postinstall", info).first as! XMLElement
    try require(
      post.attribute(forName: "timeout")?.stringValue == "1800", "Missing install timeout")
    let hook = component.at("Scripts/" + post.attribute(forName: "file")!.stringValue!)
    try command(["bash", "-n", hook.path])
    try require(
      try hook.text.contains("zmd_as_user")
        && component.at("Scripts/region").text.trimmingCharacters(in: .whitespacesAndNewlines)
          == region,
      "Wrong region hook")
    let helper = try component.at("Scripts/pkg-user.sh").text
    try require(
      helper.contains("launchctl asuser") && helper.contains("sudo -H -u")
        && helper.contains("env -i"), "Missing user isolation")
  }
  let manifest = try json(payload.at("manifest.json"))
  for (name, hash) in manifest["files"] as! [String: String] {
    try require(
      !name.hasSuffix(".py") && !name.hasSuffix(".sh")
        && !name.split(separator: "/").contains("prefix"), "Unexpected runtime script or prefix")
    try require(try digest(payload.at(name)) == hash, "Payload checksum mismatch")
  }
  if !staticOnly {
    for (cn, global) in [(1, 0), (0, 1), (1, 1)] {
      let changes = stage.at("choices.plist")
      try savePlist(
        [
          ["choiceIdentifier": "cn", "choiceAttribute": "selected", "attributeSetting": cn],
          [
            "choiceIdentifier": "global", "choiceAttribute": "selected", "attributeSetting": global,
          ],
        ], changes)
      let result = try command(
        [
          "/usr/sbin/installer", "-pkg", package.path, "-target", "/",
          "-showChoicesAfterApplyingChangesXML", changes.path,
        ], capture: true
      ).output
      let values =
        try PropertyListSerialization.propertyList(from: Data(result.utf8), format: nil)
        as! [[String: Any]]
      for (key, expected) in [("cn", cn), ("global", global), ("runtime", 1)] {
        try require(
          values.first {
            $0["choiceIdentifier"] as? String == key
              && $0["choiceAttribute"] as? String == "selected"
          }?["attributeSetting"] as? Int == expected, "Installer evaluated wrong choice")
      }
    }
  }
  print(
    "PASS: PKG choices, hooks, timeout, versions and payload hashes (no installation performed)")
}
