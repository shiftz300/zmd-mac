import Foundation

func bootstrap(nativeOnly: Bool = false, sevenzipOnly: Bool = false) throws {
  if sevenzipOnly { _ = try buildSevenZip(); return }
  let locks = try json(project.at("dependencies.lock.json"))
  let base = work.at("tools/native")
  let lib = base.at("lib")
  try mkdir(lib)
  var selected = Set<String>()
  func visit(_ name: String) throws {
    guard selected.insert(name).inserted else { return }
    guard let entry = locks["native/" + name] as? [String: Any] else {
      throw Failure("Unpinned dependency: \(name)")
    }
    for dep in entry["dependencies"] as! [String] { try visit(dep) }
  }
  for name in ["bison", "mingw-w64", "pkgconf"] {
    try visit(name)
  }
  for name in selected.sorted() {
    let e = locks["native/" + name] as! [String: Any]
    let opt = base.at("opt/" + name)
    if opt.exists { continue }
    let sha = e["sha256"] as! String
    let archive = work.at(
      "downloads/" + name.replacingOccurrences(of: "@", with: "-") + "-" + String(sha.prefix(16))
        + ".tar.gz")
    if try !archive.exists || digest(archive) != sha {
      let scope =
        "repository:homebrew/core/" + name.replacingOccurrences(of: "@", with: "/") + ":pull"
      var url = URLComponents(string: "https://ghcr.io/token")!
      url.queryItems = [
        URLQueryItem(name: "service", value: "ghcr.io"), URLQueryItem(name: "scope", value: scope),
      ]
      let response = try command(["curl", "-fLsS", url.url!.absoluteString], capture: true).output
      let token =
        (try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any])["token"]
        as! String
      try download(e["url"] as! String, archive, sha, headers: ["Authorization": "Bearer " + token])
    }
    try mkdir(base.at("Cellar"))
    try command(["tar", "-xzf", archive.path, "-C", base.at("Cellar").path])
    let versions = try children(base.at("Cellar/" + name)).filter {
      $0.hasDirectoryPath
        || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    try require(versions.count == 1, "Ambiguous bottle version: \(name)")
    try mkdir(opt.deletingLastPathComponent())
    try fm.createSymbolicLink(
      atPath: opt.path, withDestinationPath: relative(versions[0], opt.deletingLastPathComponent()))
  }
  for package in try children(base.at("opt")) {
    for file in files(package.at("lib")).filter({ $0.pathExtension == "dylib" }) {
      let target = lib.at(file.lastPathComponent)
      if !target.exists && !target.link {
        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: relative(file, lib))
      }
    }
  }
  let all = files(base.at("Cellar"))
  for file in all where regular(file) && !file.link {
    try writable(file)
    if macho(file) {
      var args: [String] = []
      for old in try dependencies(file)
      where old.contains("HOMEBREW") || old.hasPrefix("/opt/homebrew/")
        || old.hasPrefix("/usr/local/")
      {
        let name = URL(fileURLWithPath: old).lastPathComponent
        let target = lib.at(URL(fileURLWithPath: old).lastPathComponent)
        if !target.exists {
          guard let match = all.first(where: { $0.lastPathComponent == name }) else {
            throw Failure("Missing library: \(old)")
          }
          try fm.createSymbolicLink(atPath: target.path, withDestinationPath: relative(match, lib))
        }
        args += ["-change", old, "@rpath/" + name]
      }
      let rpath = "@loader_path/" + relative(lib, file.deletingLastPathComponent())
      if try !command(["otool", "-l", file.path], capture: true).output.contains(
        "path " + rpath + " ")
      {
        args += ["-add_rpath", rpath]
      }
      if !args.isEmpty {
        try command(["install_name_tool"] + args + [file.path])
        try sign(file)
      }
    } else if ["o", "a"].contains(file.pathExtension) {
      var data = try Data(contentsOf: file)
      for (old, new) in [
        ("@@HOMEBREW_CELLAR@@", "/opt/homebrew/Cellar"), ("@@HOMEBREW_PREFIX@@", "/opt/homebrew"),
      ] {
        let needle = Data(old.utf8)
        var cursor = data.startIndex
        while let range = data.range(of: needle, in: cursor..<data.endIndex) {
          data.replaceSubrange(range, with: Data(new.utf8))
          cursor = range.lowerBound + new.utf8.count
        }
      }
      try data.write(to: file)
    } else if ["pc", "la", "cmake"].contains(file.pathExtension)
      || file.lastPathComponent.hasSuffix("-config"), var text = try? file.text
    {
      for old in ["@@HOMEBREW_CELLAR@@", "/opt/homebrew/Cellar", "/usr/local/Cellar"] {
        text = text.replacingOccurrences(of: old, with: base.at("Cellar").path)
      }
      for old in ["@@HOMEBREW_PREFIX@@", "/opt/homebrew", "/usr/local"] {
        text = text.replacingOccurrences(of: old, with: base.path)
      }
      try write(text, file)
    }
  }
  if nativeOnly { return }
  let sdk = work.at("tools/x86_64")
  let ports = try json(project.at("macports.lock.json"))
  var done = Set<String>()
  try mkdir(sdk)
  func install(_ name: String) throws {
    guard done.insert(name).inserted else { return }
    guard let e = ports[name] as? [String: Any] else {
      throw Failure("Unpinned MacPorts dependency: \(name)")
    }
    for dep in e["dependencies"] as! [String] { try install(dep) }
    let marker = sdk.at(".packages/" + (e["filename"] as! String))
    if marker.exists { return }
    let archive = work.at("downloads/" + (e["filename"] as! String))
    try download(e["url"] as! String, archive, e["sha256"] as! String)
    try command(["tar", "-xjf", archive.path, "-C", sdk.path, "--strip-components=3", "opt/local"])
    try write("", marker)
  }
  for name in ["gnutls", "freetype", "libsdl2", "vulkan-loader", "libpcap"] { try install(name) }
  for file in files(sdk) where regular(file) && !file.link {
    try writable(file)
    if macho(file) {
      var args = file.pathExtension == "dylib" ? ["-id", "@rpath/" + file.lastPathComponent] : []
      for old in try dependencies(file) where old.hasPrefix("/opt/local/") {
        let target = sdk.at(String(old.dropFirst("/opt/local/".count)))
        try require(target.exists, "Missing library: \(old)")
        args += [
          "-change", old, "@loader_path/" + relative(target, file.deletingLastPathComponent()),
        ]
      }
      if !args.isEmpty {
        try command(["install_name_tool"] + args + [file.path])
        try sign(file)
      }
    } else if ["pc", "la", "cmake"].contains(file.pathExtension)
      || file.lastPathComponent.hasSuffix("-config"), let text = try? file.text
    {
      try write(text.replacingOccurrences(of: "/opt/local", with: sdk.path), file)
    }
  }
}

/// Build the shipped extractor from the already pinned source, not a host-OS bottle.
func buildSevenZip() throws -> URL {
  let input = try json(project.at("licenses/sources.json"))["7zip"] as! [String: String]
  let archive = work.at("downloads/license-sources/" + input["file"]!)
  try download(input["url"]!, archive, input["sha256"]!)
  let source = work.at("build/sevenzip-" + String(input["sha256"]!.prefix(12)))
  if !source.exists {
    try mkdir(source)
    try command(["tar", "-xf", archive.path, "-C", source.path])
  }
  let bundle = source.at("CPP/7zip/Bundles/Alone2")
  let platform = targetArchitecture == "arm64" ? "arm64" : "x64"
  var environment = env
  environment["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  try command(["make", "-f", "../../cmpl_mac_\(platform).mak", "-j" + (env["JOBS"] ?? "8"),
               "MY_ARCH=-arch \(targetArchitecture) -mmacosx-version-min=14.0", "DISABLE_RAR_COMPRESS=1"],
              cwd: bundle, environment: environment)
  let output = work.at("tools/sevenzip-" + targetArchitecture)
  try copy(bundle.at("b/m_\(platform)/7zz"), output.at("bin/7zz"))
  try sign(output.at("bin/7zz"))
  try verifyDeployment(output, maximum: 14)
  return output
}
let sourceInputs = [
  (
    "crossover-sources-26.3.0.tar.gz",
    "https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz",
    "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
  ),
  (
    "finewine-a62d906c.tar.gz",
    "https://codeload.github.com/Lunarchy107/Endfield_FineWine/tar.gz/a62d906c18e790acad3603ea639a3baba4e201ad",
    "5f5260628591599219dbe3ea8d14e9c3962d24f14817fe5f60616559385a859d"
  ),
  (
    "dxmt-v0.80-builtin.tar.gz",
    "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
    "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
  ),
]
let finewineCommit = "a62d906c18e790acad3603ea639a3baba4e201ad"
let localPatches = [
  ("wine-session-dock.patch", "39e6e744c238949ebecaa9ba661502c1eeae5cf9f8656dc06ffa268c4486daa9"),
  (
    "wine-display-monitors.patch",
    "ce42fd397f03533a5e70c4599fa91ae6d10ccc4c86bbc4cc04fa61bd472ac379"
  ),
]
func fetchSources() throws {
  for (name, url, sha) in sourceInputs { try download(url, work.at("downloads/" + name), sha) }
  let patches = work.at("vendor/Endfield_FineWine-" + finewineCommit)
  if !patches.exists {
    try mkdir(patches.deletingLastPathComponent())
    try command([
      "tar", "-xzf", work.at("downloads/" + sourceInputs[1].0).path, "-C",
      patches.deletingLastPathComponent().path,
    ])
  }
  let renderer = work.at("runtime/renderers/dxmt")
  if !renderer.exists {
    try mkdir(renderer)
    try command([
      "tar", "-xzf", work.at("downloads/" + sourceInputs[2].0).path, "-C", renderer.path,
      "--strip-components=1",
    ])
  }
}
func prepareSource() throws {
  let source = work.at("build/wine-src")
  let stamp = work.at("build/source-patches.json")
  if !stamp.exists {
    try require(
      !source.exists || (try children(source)).isEmpty,
      "Partial Wine source exists; inspect before retrying")
    let archive = work.at("downloads/" + sourceInputs[0].0)
    try require(try digest(archive) == sourceInputs[0].2, "Wine source checksum mismatch")
    try mkdir(source)
    try command([
      "tar", "-xzf", archive.path, "-C", source.path, "--strip-components=2", "sources/wine",
    ])
    let patches = work.at("vendor/Endfield_FineWine-" + finewineCommit + "/patches")
    var records: [[String: String]] = []
    for folder in [
      "highball", "stage2-dwproton/em-backports", "stage2-dwproton/misc",
      "stage2-dwproton/ace-core", "stage1-macos", "sikarugir",
    ] {
      for patch in try children(patches.at(folder)).filter({ $0.pathExtension == "patch" }).sorted(
        by: { $0.path < $1.path })
      {
        if folder == "highball" {
          try command(["patch", "-p1", "-s", "--no-backup-if-mismatch"], cwd: source, input: patch)
        } else {
          try ensurePatch(patch, source, idempotent: false)
        }
        records.append(["path": relative(patch, patches), "sha256": try digest(patch)])
      }
    }
    try saveJSON(
      [
        "wine_version": "26.3.0", "wine_source_sha256": sourceInputs[0].2,
        "finewine_commit": finewineCommit, "patches": records,
      ], stamp)
  }
  var record = try json(stamp)
  var local: [[String: String]] = []
  for (name, sha) in localPatches {
    let patch = project.at("Patches/" + name)
    try require(try digest(patch) == sha, "Local Wine patch checksum mismatch")
    try ensurePatch(patch, source)
    local.append(["path": "Patches/" + name, "sha256": sha])
  }
  record["local_patches"] = local
  try saveJSON(record, stamp)
}
func buildWine() throws {
  try prepareSource()
  let sdk = work.at("tools/x86_64")
  let native = work.at("tools/native")
  let source = work.at("build/wine-src")
  let build = work.at("build/wine")
  var e = env
  e["PATH"] =
    ["mingw-w64", "bison", "pkgconf"].map { native.at("opt/" + $0 + "/bin").path }.joined(
      separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin")
  e["BISON_PKGDATADIR"] = native.at("opt/bison/share/bison").path
  e["PKG_CONFIG_LIBDIR"] = sdk.at("lib/pkgconfig").path + ":" + sdk.at("share/pkgconfig").path
  e["PKG_CONFIG_PATH"] = ""
  e["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  e["CC"] = "clang -arch x86_64 -mmacosx-version-min=14.0"
  e["CXX"] = "clang++ -arch x86_64 -mmacosx-version-min=14.0"
  e["OBJC"] = "clang -arch x86_64 -mmacosx-version-min=14.0"
  e["CPPFLAGS"] = "-I" + sdk.at("include").path
  e["LDFLAGS"] = "-L\(sdk.path)/lib -Wl,-rpath,\(sdk.path)/lib"
  e["CROSSCFLAGS"] = "-O2"
  try mkdir(build)
  // Configure records the target in CC, including subsequent manual make invocations.
  // Rebuild objects from older build directories whose target was only an environment variable.
  if build.at("Makefile").exists,
     try !build.at("Makefile").text.contains("CC = clang -arch x86_64 -mmacosx-version-min=14.0") {
    try command(["make", "distclean"], cwd: build, environment: e)
  }
  if !build.at("Makefile").exists {
    var args = [
      source.at("configure").path, "--prefix=" + work.at("runtime/wine").path,
      "--build=x86_64-apple-darwin", "--host=x86_64-apple-darwin", "--enable-archs=i386,x86_64",
      "--with-mingw", "x86_64_CC=x86_64-w64-mingw32-gcc", "i386_CC=i686-w64-mingw32-gcc",
      "--disable-tests", "--disable-winebth_sys",
    ]
    args += [
      "coreaudio", "freetype", "gettext", "gnutls", "opencl", "pcap", "pcsclite", "pthread", "sdl",
      "vulkan",
    ].map { "--with-" + $0 }
    args += [
      "alsa", "capi", "cups", "dbus", "ffmpeg", "fontconfig", "gettextpo", "gphoto", "gssapi",
      "gstreamer", "inotify", "krb5", "netapi", "opengl", "oss", "pulse", "sane", "udev", "usb",
      "v4l2", "wayland", "x",
    ].map { "--without-" + $0 }
    try command(args, cwd: build, environment: e)
  }
  try command(["make", "-j" + (env["JOBS"] ?? "8")], cwd: build, environment: e)
  try command(["make", "install-lib"], cwd: build, environment: e)
  try copy(source.at("COPYING.LIB"), work.at("runtime/wine/COPYING.LIB"))
}
func assembleRuntime() throws {
  let sdk = work.at("tools/x86_64")
  let runtime = work.at("runtime")
  let lib = runtime.at("wine/lib")
  let unix = lib.at("wine/x86_64-unix")
  try mkdir(lib)
  var copied = Set<String>()
  func locate(_ old: String, _ source: URL) -> URL? {
    if old.hasPrefix("@loader_path/") {
      return source.deletingLastPathComponent().at(String(old.dropFirst(13)))
        .resolvingSymlinksInPath()
    }
    if old.hasPrefix("@rpath/") {
      let p = sdk.at("lib/" + String(old.dropFirst(7)))
      return p.exists ? p.resolvingSymlinksInPath() : nil
    }
    if old.hasPrefix(sdk.path + "/") { return URL(fileURLWithPath: old).resolvingSymlinksInPath() }
    return nil
  }
  func bundle(_ input: URL) throws {
    let source = input.resolvingSymlinksInPath()
    let name = source.lastPathComponent
    guard copied.insert(name).inserted else { return }
    let target = lib.at(name)
    try copy(source, target)
    try writable(target)
    var changes: [String] = []
    for old in try dependencies(source) {
      if let child = locate(old, source), child != source {
        try require(
          child.exists && child.path.hasPrefix(sdk.path + "/"), "Unexpected library: \(old)")
        try bundle(child)
        changes += ["-change", old, "@rpath/" + child.lastPathComponent]
      }
    }
    try command(["install_name_tool", "-id", "@rpath/" + name] + changes + [target.path])
  }
  for name in [
    "libgnutls.30.dylib", "libfreetype.6.dylib", "libSDL2-2.0.0.dylib", "libvulkan.1.dylib",
    "libpcap.A.dylib",
  ] {
    let source = sdk.at("lib/" + name)
    try bundle(source)
    if name != source.resolvingSymlinksInPath().lastPathComponent && !lib.at(name).exists {
      try fm.createSymbolicLink(
        atPath: lib.at(name).path,
        withDestinationPath: source.resolvingSymlinksInPath().lastPathComponent)
    }
  }
  for arch in ["i386-windows", "x86_64-windows"] {
    try copy(
      runtime.at("renderers/dxmt/" + arch + "/winemetal.dll"),
      lib.at("wine/" + arch + "/winemetal.dll"))
  }
  // Renderer distributions already carry their own loader paths and signatures.
  for file in files(runtime.at("wine")) where macho(file) {
    try writable(file)
    var changes: [String] = []
    for old in try dependencies(file) where old.hasPrefix(sdk.path + "/") {
      changes += ["-change", old, "@rpath/" + URL(fileURLWithPath: old).lastPathComponent]
    }
    let load = try command(["otool", "-l", file.path], capture: true).output
    if load.contains("path \(sdk.path)/lib ") { changes += ["-delete_rpath", sdk.at("lib").path] }
    for target in [lib, unix] {
      let path = "@loader_path/" + relative(target, file.deletingLastPathComponent())
      if !load.contains("path " + path + " ") { changes += ["-add_rpath", path] }
    }
    if !changes.isEmpty { try command(["install_name_tool"] + changes + [file.path]) }
    try sign(file)
  }
  try copy(sdk.at("share/curl/curl-ca-bundle.crt"), runtime.at("ca-bundle.crt"))
  var modules: [String: String] = [:]
  for name in [
    "x86_64-unix/ntdll.so", "x86_64-unix/win32u.so", "x86_64-unix/winemac.so",
    "x86_64-windows/winemac.drv", "i386-windows/winemac.drv",
  ] {
    modules["wine/lib/wine/" + name] = try digest(lib.at("wine/" + name))
  }
  try saveJSON(
    [
      "wine": try json(work.at("build/source-patches.json")),
      "dxmt": ["version": "0.80", "url": sourceInputs[2].1, "sha256": sourceInputs[2].2],
      "libraries": copied.sorted(), "session_modules": modules,
    ], runtime.at("provenance.json"))
}
