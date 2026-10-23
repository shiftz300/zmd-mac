import Foundation

func validateRuntime(_ runtime: URL) throws {
  for name in [
    "wine/bin/wine", "wine/bin/wineserver", "provenance.json",
    "renderers/moltenvk/libMoltenVK.dylib", "renderers/dxmt/x86_64-windows/d3d11.dll",
    "renderers/dxmt-metalfx/x86_64-windows/nvngx.dll",
    "renderers/dxmt-metalfx/x86_64-windows/nvapi64.dll", "renderers/dxmt-metalfx/provenance.json",
  ] {
    try require(regular(runtime.at(name)), "Missing runtime component: \(name)")
  }
  try require(!runtime.at("prefix").exists, "Runtime must not contain a user prefix")
  let provenance = try json(runtime.at("provenance.json"))
  let wine = provenance["wine"] as! [String: Any]
  let patches = wine["local_patches"] as? [[String: String]] ?? []
  for (name, expected) in localPatches {
    try require(
      try digest(project.at("Patches/" + name)) == expected
        && patches.contains(where: { $0["sha256"] == expected }),
      "Runtime requires matching patch: \(name)")
  }
  let modules = provenance["session_modules"] as? [String: String] ?? [:]
  try require(
    modules.count == 5 && modules["wine/lib/wine/x86_64-unix/win32u.so"] != nil,
    "Missing Wine module provenance")
  for (name, expected) in modules {
    try require(try digest(runtime.at(name)) == expected, "Wine module checksum mismatch: \(name)")
  }
}
func appMetadata(template: Bool) -> [String: Any] {
  [
    "CFBundleDevelopmentRegion": "zh_CN", "CFBundleDisplayName": "鹰角启动器", "CFBundleName": "鹰角启动器",
    "CFBundleIdentifier": "local.zmdmac.endfield.template", "CFBundleExecutable": "Endfield",
    "CFBundlePackageType": "APPL", "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleShortVersionString": version, "CFBundleVersion": "8", "LSMinimumSystemVersion": "27.0",
    "LSMultipleInstancesProhibited": true, "NSHighResolutionCapable": true, "LSUIElement": template,
  ]
}
func packageDistribution(runtime: URL, sevenzip: URL, output: URL) throws {
  let archive = output.deletingLastPathComponent().at(output.lastPathComponent + "-macos-arm64.zip")
  for path in [output, archive, archive.appendingPathExtension("sha256")] {
    try require(!path.exists && !path.link, "Refusing to overwrite \(path.path)")
  }
  try validateRuntime(runtime)
  try require(runtime.at("renderers/kosmickrisp/provenance.json").exists,
              "Install the experimental backend first: zmd-dev kosmickrisp --runtime DIR")
  try installKosmicKrisp(runtime) // Verify the pinned component and hashes before packaging.
  let stage = try temp(output.deletingLastPathComponent(), ".zmd-release-")
  defer { try? fm.removeItem(at: stage) }
  let distribution = stage.at(output.lastPathComponent)
  let payload = distribution.at("payload")
  let contents = payload.at("AppTemplate.app/Contents")
  let support = contents.at("SharedSupport")
  try mkdir(contents.at("MacOS"))
  try mkdir(support.at("logs"))
  try copy(project.at("Resources/prefix-settings.reg"), support.at("prefix-settings.reg"))
  try write("3\n", support.at("runtime-interface"))
  try compile(coreSources + ["Sources/zmd/main.swift"], distribution.at("zmd"))
  try sign(distribution.at("zmd"))
  try compile(launcherSources, contents.at("MacOS/Endfield"))
  try sign(contents.at("MacOS/Endfield"))
  try savePlist(appMetadata(template: true), contents.at("Info.plist"))
  try clone(runtime, payload.at("runtime"))
  for name in ["bin/7zz", "lib/7z.so"] {
    let target = payload.at("sevenzip/" + name)
    try copy(sevenzip.at(name), target)
    let lines = try command(["otool", "-l", target.path], capture: true).output.components(
      separatedBy: "\n")
    for i in lines.indices where lines[i].trimmingCharacters(in: .whitespaces) == "cmd LC_RPATH" {
      let line = lines[i + 2].trimmingCharacters(in: .whitespaces)
      let path = String(line.dropFirst(5)).components(separatedBy: " (offset")[0]
      try command(["install_name_tool", "-delete_rpath", path, target.path])
    }
    if name.hasSuffix(".so") {
      try command(["install_name_tool", "-id", "@loader_path/7z.so", target.path])
    }
    try sign(target)
  }
  for name in [
    "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "docs", "licenses", "dependencies.lock.json",
    "macports.lock.json", "kosmickrisp.lock.json",
  ] {
    try copy(project.at(name), distribution.at(name))
    try copy(project.at(name), support.at(name))
  }
  let shortcut = distribution.at("安装终末地.command")
  try copy(project.at("Resources/install.command"), shortcut)
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shortcut.path)
  var hashes: [String: String] = [:]
  var links: [String: String] = [:]
  for file in files(payload) {
    let name = relative(file, payload)
    if file.link {
      try require(
        file.resolvingSymlinksInPath().path.hasPrefix(payload.resolvingSymlinksInPath().path + "/"),
        "Non-relocatable link: \(name)")
      links[name] = try fm.destinationOfSymbolicLink(atPath: file.path)
    } else if regular(file) {
      hashes[name] = try digest(file)
    }
  }
  try saveJSON(["format": 1, "files": hashes, "links": links], payload.at("manifest.json"))
  try fm.moveItem(at: distribution, to: output)
  try command(["ditto", "-c", "-k", "--keepParent", "--norsrc", output.path, archive.path])
  try checksumFile(archive)
  print("Distribution: \(output.path)")
}
let installRoot = "/Library/Application Support/zmd-mac"
func packagePKG(distribution: URL, output: URL) throws {
  try require(
    !output.exists && !output.appendingPathExtension("sha256").exists, "Refusing to overwrite PKG")
  try command([distribution.at("zmd").path, "verify"])
  let packagedVersion =
    try plist(distribution.at("payload/AppTemplate.app/Contents/Info.plist"))[
      "CFBundleShortVersionString"] as! String
  try require(packagedVersion == version, "Distribution version differs from build tool")
  let stage = try temp(output.deletingLastPathComponent(), "zmd-pkg-")
  defer { try? fm.removeItem(at: stage) }
  let root = stage.at("root")
  try mkdir(root)
  for name in [
    "zmd", "payload", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "docs", "licenses",
  ] { try clone(distribution.at(name), root.at(name)) }
  let components = stage.at("components.plist")
  try savePlist([], components)
  let common = stage.at("common-scripts")
  try copy(project.at("Resources/pkg-user.sh"), common.at("pkg-user.sh"))
  try copy(project.at("Resources/pkg-preinstall.sh"), common.at("preinstall"))
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: common.at("preinstall").path)
  try command([
    "pkgbuild", "--root", root.path, "--component-plist", components.path, "--scripts", common.path,
    "--install-location", installRoot, "--identifier", "local.zmdmac.installer.runtime",
    "--version", version, stage.at("runtime.pkg").path,
  ])
  for region in ["cn", "global"] {
    let hooks = stage.at(region + "-scripts")
    let regionRoot = stage.at(region + "-root")
    let bundlePath = "Regions/" + region + ".bundle"
    try copy(project.at("Resources/pkg-user.sh"), hooks.at("pkg-user.sh"))
    try copy(project.at("Resources/pkg-postinstall.sh"), hooks.at("install-region"))
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.at("install-region").path)
    try write(region + "\n", hooks.at("region"))
    try savePlist(
      [
        "CFBundleIdentifier": "local.zmdmac.installer.receipt." + region,
        "CFBundleVersion": version, "CFBundlePackageType": "BNDL",
      ], regionRoot.at(bundlePath + "/Contents/Info.plist"))
    let component = stage.at(region + "-components.plist")
    try savePlist(
      [
        [
          "RootRelativeBundlePath": bundlePath, "BundleIsRelocatable": false,
          "BundleIsVersionChecked": false, "BundleHasStrictIdentifier": true,
          "BundleOverwriteAction": "upgrade", "BundlePostInstallScriptPath": "install-region",
          "BundleInstallScriptTimeout": 1800,
        ]
      ], component)
    try command([
      "pkgbuild", "--root", regionRoot.path, "--component-plist", component.path, "--scripts",
      hooks.path, "--install-location", installRoot, "--identifier",
      "local.zmdmac.installer." + region, "--version", version, stage.at(region + ".pkg").path,
    ])
  }
  let resources = stage.at("resources")
  try write(
    "<!doctype html><meta charset=\"utf-8\"><h2>终末地 · macOS</h2><p>在「安装类型 → 自定」选择国服或 Global，也可同时安装。</p><p>为当前登录用户安装官方启动器并创建桌面入口；已有同名应用不会覆盖。</p><p>需要 Apple Silicon、macOS 27、Rosetta 2 和网络。Global 完整游玩尚未验证。</p>",
    resources.at("welcome.html"))
  try write(
    "<!doctype html><meta charset=\"utf-8\"><h2>安装完成</h2><p>从桌面或个人「应用程序」打开「鹰角启动器」／「GRYPHLINK」，下载并开始游戏。运行设置可从左上角应用菜单打开。</p>",
    resources.at("conclusion.html"))
  var xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <installer-gui-script minSpecVersion="2"><title>终末地</title>
    <welcome file="welcome.html" mime-type="text/html"/><conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="always" require-scripts="true" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check><allowed-os-versions><os-version min="27.0"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="runtime"/><line choice="cn"/><line choice="global"/></choices-outline>
    """
  for region in ["runtime", "cn", "global"] {
    let name = region == "cn" ? "鹰角启动器" : "GRYPHLINK"
    let attrs =
      region == "runtime"
      ? "visible=\"false\" enabled=\"false\" selected=\"true\""
      : "description=\"安装到当前用户的 ~/Applications/\(name).app；已有应用不会覆盖。\""
    xml +=
      "<choice id=\"\(region)\" title=\"\(region == "runtime" ? "运行环境" : region == "cn" ? "国服" : "Global · GRYPHLINK")\" start_selected=\"\(region == "global" ? "false" : "true")\" \(attrs)><pkg-ref id=\"local.zmdmac.installer.\(region)\"/></choice>"
    xml +=
      "<pkg-ref id=\"local.zmdmac.installer.\(region)\" version=\"\(version)\" onConclusion=\"none\">\(region).pkg</pkg-ref>"
  }
  xml += "</installer-gui-script>"
  try write(xml, stage.at("Distribution.xml"))
  try command([
    "productbuild", "--distribution", stage.at("Distribution.xml").path, "--package-path",
    stage.path, "--resources", resources.path, output.path,
  ])
  try checksumFile(output)
}
func updateApp(_ app: URL) throws {
  let contents = app.at("Contents")
  let entry = contents.at("MacOS/Endfield")
  let support = contents.at("SharedSupport")
  try require(entry.exists, "An existing application is required")
  try validateRuntime(support.at("runtime"))
  let build = work.at("build/native-launcher")
  try mkdir(build)
  let fresh = build.at("Endfield")
  try compile(launcherSources, fresh)
  try sign(fresh)
  try command(["codesign", "--verify", fresh.path])
  let backup = try temp(build, "backup-")
  let obsolete = [
    "MacOS/launch.sh", "SharedSupport/scripts/wine.sh", "SharedSupport/scripts/set-renderer.sh",
    "SharedSupport/scripts/prepare-metalfx.sh", "SharedSupport/scripts/app-quit.sh",
  ]
  for name in ["MacOS/Endfield", "Info.plist", "SharedSupport/runtime-interface"] + obsolete
  where contents.at(name).exists { try copy(contents.at(name), backup.at(name)) }
  let temporary = contents.at("MacOS/Endfield.new")
  try copy(fresh, temporary)
  try require(rename(temporary.path, entry.path) == 0, "Failed to replace entry")
  try write("3\n", support.at("runtime-interface"))
  try copy(project.at("Resources/prefix-settings.reg"), support.at("prefix-settings.reg"))
  var metadata = try plist(contents.at("Info.plist"))
  metadata["CFBundleShortVersionString"] = version
  metadata["CFBundleVersion"] = "8"
  metadata["CFBundleName"] = app.deletingPathExtension().lastPathComponent
  metadata["CFBundleDisplayName"] = metadata["CFBundleName"]
  metadata["LSMultipleInstancesProhibited"] = true
  metadata["LSUIElement"] = false
  try savePlist(metadata, contents.at("Info.plist"))
  for name in obsolete where contents.at(name).exists { try fm.removeItem(at: contents.at(name)) }
  try command(["codesign", "--verify", "--ignore-resources", entry.path])
  try command([registerTool, "-f", app.path], allowFailure: true)
  print("Updated app; previous entry saved at \(backup.path)")
}
let registerTool =
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
func packageSources(_ runtime: URL, output: URL) throws {
  try require(
    !output.exists && !output.appendingPathExtension("sha256").exists,
    "Refusing to overwrite source archive")
  let stage = try temp(work.at("build"), "sources-")
  defer { try? fm.removeItem(at: stage) }
  for value in try json(project.at("licenses/sources.json")).values {
    let e = value as! [String: String]
    let file = work.at("downloads/license-sources/" + (value as! [String: String])["file"]!)
    try download(e["url"]!, file, e["sha256"]!)
    try copy(file, stage.at("upstream/" + e["file"]!))
  }
  for item in sourceInputs.prefix(2) {
    let file = work.at("downloads/" + item.0)
    try download(item.1, file, item.2)
    try copy(file, stage.at("upstream/" + item.0))
  }
  for name in [
    "Sources", "Tests", "Patches", "Resources", "Package.swift", "licenses",
    "dependencies.lock.json", "macports.lock.json", "moltenvk-experimental.lock.json", "kosmickrisp.lock.json",
  ] { try copy(project.at(name), stage.at(name)) }
  if runtime.at("renderers/moltenvk-experimental/provenance.json").exists {
    for (name, value) in try json(project.at("moltenvk-experimental.lock.json")) {
      let e = value as! [String: String]
      let filename =
        name == "cpm"
        ? "CPM_0.40.8.cmake" : name + "-" + (value as! [String: String])["commit"]! + ".tar.gz"
      let file = work.at("downloads/moltenvk-experimental/" + filename)
      try download(e["url"]!, file, e["sha256"]!)
      try copy(file, stage.at("moltenvk-experimental/" + filename))
    }
  }
  if work.at("build/source-patches.json").exists {
    try copy(work.at("build/source-patches.json"), stage.at("source-patches.json"))
  }
  try mkdir(output.deletingLastPathComponent())
  try command(["tar", "-czf", output.path, "-C", stage.path, "."])
  try checksumFile(output)
}
