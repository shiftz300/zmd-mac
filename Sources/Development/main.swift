import Foundation

setbuf(stdout, nil)
setbuf(stderr, nil)
let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, default fallback: String? = nil) throws -> String {
  if let i = arguments.firstIndex(of: name), i + 1 < arguments.count { return arguments[i + 1] }
  if let fallback { return fallback }
  throw Failure("Missing \(name)")
}
func pathOption(_ name: String, _ fallback: URL? = nil) throws -> URL {
  URL(
    fileURLWithPath: NSString(string: try option(name, default: fallback?.path))
      .expandingTildeInPath
  ).standardizedFileURL
}
do {
  try require(["arm64", "x86_64"].contains(targetArchitecture), "ZMD_TARGET_ARCH must be arm64 or x86_64")
  let values: [String: Set<String>] = [
    "bootstrap": [], "fetch": [], "wine": [], "runtime": [], "build": [], "test": [],
    "test-lifecycle": [], "test-cache-codec": [], "help": [], "--help": [],
    "moltenvk": ["--runtime"], "kosmickrisp": ["--runtime"], "metalfx": ["--runtime"], "experimental": ["--runtime", "--jobs"],
    "package": ["--runtime", "--sevenzip", "--output"], "pkg": ["--distribution", "--output"],
    "sources": ["--runtime", "--output"], "release": ["--tag", "--directory"],
    "update-app": ["--app"],
    "test-pkg": ["--package"], "test-display": ["--runtime"], "test-vulkan": ["--runtime"], "test-kosmickrisp": ["--runtime"],
    "test-session": ["--runtime"], "test-resolution": ["--runtime"],
    "test-install": ["--distribution", "--cn-exe", "--global-exe"],
    "test-kosmickrisp-cache": ["--runtime", "--app"],
  ]
  let selected = arguments.first ?? "help"
  guard let allowed = values[selected] else { throw Failure("Unknown command: " + selected) }
  let flags = [
    "bootstrap": "--sevenzip-only", "release": "--check-only", "test-pkg": "--static-only",
    "test-cache-codec": "--large",
  ]
  var seen = Set<String>()
  var index = 1
  while index < arguments.count {
    let key = arguments[index]
    try require(seen.insert(key).inserted, "Duplicate option: " + key)
    if flags[selected] == key {
      index += 1
      continue
    }
    try require(
      allowed.contains(key) && index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--"),
      "Unknown option or missing value: " + key)
    index += 2
  }
  switch selected {
  case "bootstrap": try bootstrap(sevenzipOnly: arguments.contains("--sevenzip-only"))
  case "fetch": try fetchSources()
  case "wine": try buildWine()
  case "runtime": try assembleRuntime()
  case "moltenvk": try installMoltenVK(pathOption("--runtime", work.at("runtime")))
  case "kosmickrisp": try installKosmicKrisp(pathOption("--runtime", work.at("runtime")))
  case "metalfx": try buildMetalFX(pathOption("--runtime", work.at("runtime")))
  case "experimental":
    try buildExperimental(
      pathOption("--runtime", work.at("runtime")), jobs: Int(option("--jobs", default: "6")) ?? 0)
  case "package":
    try packageDistribution(
      runtime: pathOption("--runtime", work.at("runtime")),
      sevenzip: pathOption("--sevenzip", work.at("tools/sevenzip-" + targetArchitecture)),
      output: pathOption("--output", project.at("release/zmd-mac")))
  case "pkg":
    try packagePKG(
      distribution: pathOption("--distribution", project.at("release/zmd-mac")),
      output: pathOption("--output", project.at("release/zmd-mac-macos-\(targetArchitecture).pkg")))
  case "sources":
    try packageSources(
      pathOption(
        "--runtime", URL(fileURLWithPath: env["ZMD_RUNTIME_SOURCE"] ?? work.at("runtime").path)),
      output: pathOption("--output", project.at("release/third-party-sources.tar.gz")))
  case "release":
    try publishRelease(
      option("--tag"), pathOption("--directory", project.at("release")),
      checkOnly: arguments.contains("--check-only"))
  case "update-app": try updateApp(pathOption("--app"))
  case "build":
    let runtime: URL
    if let existing = env["ZMD_RUNTIME_SOURCE"] {
      runtime = URL(fileURLWithPath: existing)
    } else {
      try bootstrap()
      try fetchSources()
      try buildWine()
      try assembleRuntime()
      runtime = work.at("runtime")
      try installMoltenVK(runtime)
      try buildMetalFX(runtime)
    }
    try installKosmicKrisp(runtime)
    let sevenzip: URL
    if let existing = env["ZMD_SEVENZIP_SOURCE"] {
      sevenzip = URL(fileURLWithPath: existing)
    } else {
      sevenzip = try buildSevenZip()
    }
    let output = URL(
      fileURLWithPath: env["ZMD_RELEASE_OUTPUT"] ?? project.at("release/zmd-mac").path)
    try packageDistribution(runtime: runtime, sevenzip: sevenzip, output: output)
    try packagePKG(
      distribution: output,
      output: output.deletingLastPathComponent().at(output.lastPathComponent + "-macos-\(targetArchitecture).pkg"))
  case "test": try testQuick()
  case "test-cache-codec": try testCacheCodec(large: arguments.contains("--large"))
  case "test-kosmickrisp-cache":
    try testKosmicCache(runtime: pathOption("--runtime", work.at("runtime")),
                       app: arguments.contains("--app") ? pathOption("--app") : nil)
  case "test-pkg":
    try testPKG(pathOption("--package"), staticOnly: arguments.contains("--static-only"))
  case "test-display", "test-vulkan", "test-kosmickrisp":
    try testGraphics(
      selected == "test-display" ? .displays : selected == "test-kosmickrisp" ? .kosmicKrisp : .moltenVK,
      runtime: pathOption("--runtime", work.at("runtime")))
  case "test-lifecycle": try testLifecycle()
  case "test-session": try testWineSession(pathOption("--runtime", work.at("runtime")))
  case "test-resolution":
    let test = work.at("build/tests/game-resolution-tests")
    try compile(runtimeSources + ["Tests/GameResolutionTests.swift"], test)
    try command([test.path, pathOption("--runtime", work.at("runtime")).path], timeout: 180)
  case "test-install":
    try testInstall(
      pathOption("--distribution"), cn: pathOption("--cn-exe"), global: pathOption("--global-exe"))
  case "help", "--help":
    print(
      """
      zmd-dev — Swift development tools (no Python; minimal PKG shell hooks)
      test | test-lifecycle | test-display | test-session | test-vulkan | test-resolution
      test-cache-codec [--large]
      test-pkg --package FILE [--static-only]
      test-install --distribution DIR --cn-exe FILE --global-exe FILE
      build | bootstrap [--sevenzip-only] | fetch | wine | runtime
      moltenvk | kosmickrisp | metalfx | experimental [--runtime DIR] [--jobs N]
      test-kosmickrisp [--runtime DIR]
      test-kosmickrisp-cache [--runtime DIR] [--app PATH]
      package [--runtime DIR] [--sevenzip DIR] [--output DIR]
      pkg [--distribution DIR] [--output FILE]
      sources [--runtime DIR] [--output FILE]
      release --tag vX.Y.Z [--directory DIR] [--check-only]
      update-app --app PATH
      """)
  default: throw Failure("Unknown command")
  }
} catch {
  FileHandle.standardError.write(Data(("Error: \(error.localizedDescription)\n").utf8))
  exit(1)
}
