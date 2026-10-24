import Foundation

// MARK: - KosmicKrisp and its application cache layer

/// Import only the pinned x86_64 driver; reuse our Wine runtime's Vulkan loader.
/// The LunarG SDK driver is arm64-only and cannot be loaded by this Wine process.
func installKosmicKrisp(_ runtime: URL) throws {
  let lockfile = project.at("kosmickrisp.lock.json")
  let lock = try json(lockfile) as! [String: String]
  let target = runtime.at("renderers/kosmickrisp")
  if target.exists {
    let record = try json(target.at("provenance.json"))
    try require(record["archive_sha256"] as? String == lock["sha256"], "Different KosmicKrisp exists; preserve it before replacing")
    let hashes = record["files"] as? [String: String] ?? [:]
    try require(Set(hashes.keys) == Set(["libvulkan_kosmickrisp.dylib", "libvulkan.1.dylib", "kosmickrisp_icd.json"]), "Incomplete KosmicKrisp provenance")
    for (name, hash) in hashes {
      try require(try digest(target.at(name)) == hash, "Modified KosmicKrisp component: \(name)")
    }
    for file in files(project.at("licenses/KosmicKrisp")) where regular(file) {
      let installed = target.at("licenses/" + relative(file, project.at("licenses/KosmicKrisp")))
      try require(try digest(installed) == digest(file), "KosmicKrisp license mismatch; preserve and reinstall the component")
    }
    try installCacheLayer(target)
    return
  }
  let archive = work.at("downloads/" + lock["file"]!)
  try download(lock["url"]!, archive, lock["sha256"]!)
  let stage = try temp(runtime.at("renderers"), ".kosmickrisp-")
  defer { try? fm.removeItem(at: stage) }
  let candidate = stage.at("renderer")
  try mkdir(candidate)
  try command(["unzip", "-q", archive.path, "libvulkan_kosmickrisp.dylib", "kosmickrisp_mesa_icd.json", "-d", candidate.path])
  try copy(runtime.at("wine/lib/libvulkan.1.dylib").resolvingSymlinksInPath(), candidate.at("libvulkan.1.dylib"))
  for name in ["libvulkan_kosmickrisp.dylib", "libvulkan.1.dylib"] {
    let file = candidate.at(name)
    try require(try command(["lipo", "-archs", file.path], capture: true).output.split(separator: " ").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "x86_64" }), "Expected x86_64 \(name)")
    for dep in try dependencies(file).dropFirst() {
      try require(dep.hasPrefix("/usr/lib/") || dep.hasPrefix("/System/Library/"), "Non-system dependency: \(dep)")
    }
    try command(["install_name_tool", "-id", "@loader_path/" + name, file.path])
    try sign(file)
    try command(["codesign", "--verify", file.path])
  }
  var manifest = try json(candidate.at("kosmickrisp_mesa_icd.json"))
  var icd = manifest["ICD"] as! [String: Any]
  icd["library_path"] = "./libvulkan_kosmickrisp.dylib"
  manifest["ICD"] = icd
  try saveJSON(manifest, candidate.at("kosmickrisp_icd.json"))
  try fm.removeItem(at: candidate.at("kosmickrisp_mesa_icd.json"))
  try copy(project.at("licenses/KosmicKrisp"), candidate.at("licenses"))
  try copy(lockfile, candidate.at("sources.lock.json"))
  var hashes: [String: String] = [:]
  for name in ["libvulkan_kosmickrisp.dylib", "libvulkan.1.dylib", "kosmickrisp_icd.json"] {
    hashes[name] = try digest(candidate.at(name))
  }
  try saveJSON([
    "version": lock["version"]!, "distribution": "Sikarugir-App/mesa-kosmickrisp",
    "archive_url": lock["url"]!, "archive_sha256": lock["sha256"]!,
    "build_commit": lock["build_commit"]!, "mesa_commit": lock["mesa_commit"]!,
    "architecture": "x86_64", "files": hashes, "license": "MIT and included component notices",
    "verification": "Experimental; game compatibility and performance require validation",
  ], candidate.at("provenance.json"))
  try fm.moveItem(at: candidate, to: target)
  try installCacheLayer(target)
}

/// Native loader layer; reuses the runtime's bundled zstd library.
private func installCacheLayer(_ backend: URL) throws {
  let source = project.at("Sources/VulkanCache")
  let target = backend.at("cache")
  var hashes = try Dictionary(uniqueKeysWithValues: ["cache_layer.c", "cache_codec.h"].map {
    ($0, try digest(source.at($0)))
  })
  hashes["zstd.h"] = try digest(work.at("tools/x86_64/include/zstd.h"))
  hashes["libzstd.1.5.7.dylib"] = try digest(work.at("tools/x86_64/lib/libzstd.1.5.7.dylib"))
  if target.at("provenance.json").exists,
     let record = try? json(target.at("provenance.json")),
     record["source_sha256"] as? [String: String] == hashes {
    let files = record["files"] as? [String: String] ?? [:]
    try require(Set(files.keys) == Set(["libzmd_cache.dylib", "cache_layer.json"]), "Incomplete cache layer")
    for (name, hash) in files { try require(try digest(target.at(name)) == hash, "Modified cache layer: \(name)") }
    return
  }
  let stage = try temp(backend, ".cache-build-")
  defer { try? fm.removeItem(at: stage) }
  // The pinned Vulkan framework flattens video headers. Restore the standard
  // include layout locally, without another SDK or dependency download.
  let headers = work.at("tools/x86_64/Library/Frameworks/vulkan.framework/Versions/A/Headers")
  let include = stage.at("include")
  try mkdir(include.at("vk_video"))
  for file in try children(headers) where file.pathExtension == "h" {
    try copy(file, include.at(file.lastPathComponent))
    if file.lastPathComponent.hasPrefix("vulkan_video_") {
      try copy(file, include.at("vk_video/" + file.lastPathComponent))
    }
  }
  let candidate = stage.at("cache")
  try mkdir(candidate)
  let library = candidate.at("libzmd_cache.dylib")
  try command(["xcrun", "clang", "-arch", "x86_64", "-mmacosx-version-min=26.0", "-O2",
               "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations", "-fvisibility=hidden",
               "-dynamiclib", "-I" + include.path,
               "-I" + work.at("tools/x86_64/include").path,
               "-L" + work.at("tools/x86_64/lib").path, "-lzstd",
               "-Wl,-rpath,@loader_path/../../../wine/lib",
               "-Wl,-install_name,@loader_path/libzmd_cache.dylib", source.at("cache_layer.c").path,
               "-o", library.path])
  try sign(library)
  try saveJSON(["file_format_version": "1.2.0", "layer": [
    "name": "VK_LAYER_ZMD_pipeline_cache", "type": "GLOBAL", "library_path": "./libzmd_cache.dylib",
    "api_version": "1.4.0", "implementation_version": "1",
    "description": "ZMD application pipeline cache compression",
  ]], candidate.at("cache_layer.json"))
  try saveJSON(["format": 1, "source_sha256": hashes,
    "files": ["libzmd_cache.dylib": try digest(library),
              "cache_layer.json": try digest(candidate.at("cache_layer.json"))]], candidate.at("provenance.json"))
  if target.exists { try fm.moveItem(at: target, to: stage.at("previous")) }
  do { try fm.moveItem(at: candidate, to: target) }
  catch {
    if stage.at("previous").exists { try? fm.moveItem(at: stage.at("previous"), to: target) }
    throw error
  }
}

// MARK: - MoltenVK stable distribution

func installMoltenVK(_ runtime: URL) throws {
  let url =
    "https://github.com/stoicswe/Endfield_FineWine/releases/download/1.2.4/endfield-wine-modules.tar.gz"
  let sha = "c5955e0ca68e722e3043902615f1d219f8f36972906e62dd8564ba3107a57b04"
  let archive = work.at("downloads/finewine-1.2.4-modules.tar.gz")
  let stage = try temp(work.at("build"), "moltenvk-")
  defer { try? fm.removeItem(at: stage) }
  try download(url, archive, sha)
  let names = ["libMoltenVK.dylib", "LICENSE.MoltenVK", "SOURCE.txt"]
  try command(
    ["tar", "-xzf", archive.path, "-C", stage.path, "--strip-components=1"]
      + names.map { "endfield-wine-modules/" + $0 })
  let library = stage.at(names[0])
  try command(["codesign", "--verify", library.path])
  try require(
    try command(["file", "-b", library.path], capture: true).output.contains("x86_64"),
    "Expected x86_64 MoltenVK")
  let target = runtime.at("renderers/moltenvk")
  let hash = try digest(library)
  if target.at(names[0]).exists {
    try require(try digest(target.at(names[0])) == hash, "Refusing to overwrite different MoltenVK")
  }
  try mkdir(target)
  for name in names where !target.at(name).exists { try copy(stage.at(name), target.at(name)) }
  try saveJSON(
    [
      "version": "1.4.2", "distribution": "FineWine 1.2.4", "archive_url": url,
      "archive_sha256": sha, "library_sha256": hash,
      "source_commit": "db66022459ffb663aa2b50f6b018bc2e124f5edf",
      "patches_commit": "ab8b9e909c5f5d87f166de0cf4ec00a1a8aa29da", "license": "Apache-2.0",
    ], target.at("provenance.json"))
}
// MARK: - DXMT MetalFX bridge

func buildMetalFX(_ runtime: URL) throws {
  let base = runtime.at("renderers/dxmt")
  let original = base.at("x86_64-windows/nvngx.dll")
  let patch = project.at("Patches/dxmt-235-ngx-resource-pointer.patch")
  let nvpatch = project.at("Patches/dxmt-nvapi-logical-gpu.patch")
  let compiler = work.at("tools/native/opt/mingw-w64/bin/x86_64-w64-mingw32-g++")
  let objdump = compiler.deletingLastPathComponent().at("x86_64-w64-mingw32-objdump")
  let winebuild = work.at("build/wine/tools/winebuild/winebuild")
  let sourceURL = "https://codeload.github.com/3Shain/dxmt/tar.gz/refs/tags/v0.80"
  let sourceSHA = "79cd3a2b32749fc3890b6c2a9337f45de26fdb750014f3457bb7ebafa679492d"
  let patchSHA = "b77aad68fa862f57a43f192d8a80743c5439d633a979b3704dabe6fd31ee9a8f"
  let nvSHA = "83b67c1b2074a2918314dc6cbbb1635b52f6c6995343b9ce2bf0a088621d334a"
  let nvcommit = "d08488fcc82eef313b0464db37d2955709691e94"
  let nvsourceSHA = "436936c965f711f743c8606cb7c2621736cecf41e0fd6557555b2f1903b0350f"
  let nvURL = "https://codeload.github.com/NVIDIA/nvapi/tar.gz/" + nvcommit
  for file in [original, compiler, objdump, winebuild] {
    try require(file.exists, "Missing build input: \(file.path)")
  }
  try require(
    try digest(patch) == patchSHA && digest(nvpatch) == nvSHA, "MetalFX patch checksum mismatch")
  try require(
    (try json(runtime.at("provenance.json"))["dxmt"] as? [String: Any])?["version"] as? String
      == "0.80", "Requires DXMT 0.80")
  let archive = work.at("downloads/license-sources/dxmt-v0.80-source.tar.gz")
  let nvarchive = work.at("downloads/license-sources/nvapi-" + nvcommit + ".tar.gz")
  try download(sourceURL, archive, sourceSHA)
  try download(nvURL, nvarchive, nvsourceSHA)
  let stage = try temp(work.at("build/dxmt-metalfx"))
  defer { try? fm.removeItem(at: stage) }
  for file in [archive, nvarchive] { try command(["tar", "-xzf", file.path, "-C", stage.path]) }
  let source = stage.at("dxmt-0.80")
  for file in [patch, nvpatch] {
    try command(["patch", "-p1", "--batch", "--fuzz=0", "-i", file.path], cwd: source)
  }
  let flags = [
    compiler.path, "-std=c++20", "-O2", "-DNDEBUG", "-DNOMINMAX", "-D_WIN32_WINNT=0xa00",
    "-DDXMT_PAGE_SIZE=4096", "-include", "iomanip",
    "-fmacro-prefix-map=" + source.path + "=dxmt-0.80", "-shared", "-static", "-s",
    "-Wl,--file-alignment=4096", "-Wl,--no-insert-timestamp",
  ]
  let includes = ["include", "libs", "src/util", "src/dxgi", "src/winemetal"].map {
    "-I" + source.at($0).path
  }
  let common = [
    "util/log/log.cpp", "util/util_env.cpp", "util/util_string.cpp", "util/thread.cpp",
    "util/com/com_guid.cpp",
  ]
  let dll = stage.at("nvngx.dll")
  let nvapi = stage.at("nvapi64.dll")
  try command(
    flags + ["-o", dll.path] + includes
      + (["nvngx/nvngx.cpp"] + common).map { source.at("src/" + $0).path } + ["-ldxgi", "-luuid"])
  try command([winebuild.path, "--builtin", dll.path])
  let expected = Set(
    try matches(
      "\\bNVSDK_NGX_[A-Za-z0-9_]+",
      command([objdump.path, "-p", original.path], capture: true).output))
  try require(
    !expected.isEmpty
      && expected
        == Set(
          matches(
            "\\bNVSDK_NGX_[A-Za-z0-9_]+",
            command([objdump.path, "-p", dll.path], capture: true).output)),
    "NGX exports differ")
  try command(
    flags + ["-o", nvapi.path, "-include", "format"] + includes + [
      "-I" + stage.at("nvapi-" + nvcommit).path
    ]
      + (["nvapi/nvapi.cpp", "nvapi/nvapi64.def"] + common + ["util/wsi_monitor_win32.cpp"]).map {
        source.at("src/" + $0).path
      } + [base.at("x86_64-windows/winemetal.dll").path, "-ldxgi", "-luuid"])
  try command([winebuild.path, "--builtin", nvapi.path])
  try require(
    try command([objdump.path, "-p", nvapi.path], capture: true).output.contains(
      "nvapi_QueryInterface"), "Missing NVAPI query interface")
  let record: [String: Any] = [
    "version": "0.80+ngx235+nvapi-logical-gpu", "base_version": "0.80", "source_url": sourceURL,
    "source_sha256": sourceSHA, "patch_commit": "50102f994b406f58f56d5d09f2ad20f9b90390a2",
    "patch_sha256": patchSHA, "module": "x86_64-windows/nvngx.dll",
    "module_sha256": try digest(dll), "nvapi_module": "x86_64-windows/nvapi64.dll",
    "nvapi_module_sha256": try digest(nvapi), "nvapi_headers_commit": nvcommit,
    "nvapi_headers_url": nvURL, "nvapi_headers_sha256": nvsourceSHA, "nvapi_patch_sha256": nvSHA,
    "compiler": try command([compiler.path, "-dumpfullversion"], capture: true).output
      .trimmingCharacters(in: .whitespacesAndNewlines),
    "license": "MIT base; LGPL-2.1-or-later NGX backport",
    "upscaler": "MetalFX Temporal via NGX/DLSS", "nvext": true,
  ]
  let target = runtime.at("renderers/dxmt-metalfx")
  if target.exists {
    try require(
      NSDictionary(dictionary: try json(target.at("provenance.json"))).isEqual(to: record),
      "Different MetalFX exists; preserve it before rebuilding")
    for name in ["module", "nvapi_module"] {
      try require(
        try digest(target.at(record[name] as! String)) == record[name + "_sha256"] as! String,
        "MetalFX module checksum mismatch")
    }
    return
  }
  let candidate = stage.at("backend")
  try clone(base, candidate)
  for file in [dll, nvapi] {
    try copy(file, candidate.at("x86_64-windows/" + file.lastPathComponent))
  }
  for file in [patch, nvpatch] { try copy(file, candidate.at(file.lastPathComponent)) }
  for name in ["DXMT-0.80.txt", "DXMT-NGX-patch.txt", "Wine-LGPL-2.1.txt", "NVAPI-headers.txt"] {
    try copy(project.at("licenses/" + name), candidate.at(name))
  }
  try saveJSON(record, candidate.at("provenance.json"))
  try fm.moveItem(at: candidate, to: target)
}
// MARK: - MoltenVK experimental build

func buildExperimental(_ runtime: URL, jobs: Int) throws {
  try require(jobs > 0, "Jobs must be positive")
  let lockfile = project.at("moltenvk-experimental.lock.json")
  let lock = try json(lockfile)
  let recipe = project.at("Sources/Development/Renderers.swift")
  let target = runtime.at("renderers/moltenvk-experimental")
  try require(!target.exists, "Refusing to replace an installed experiment")
  let key = try String(digest(lockfile).prefix(12)) + "-" + String(digest(recipe).prefix(12))
  let stage = work.at("build/moltenvk-experimental/" + key)
  let cache = work.at("downloads/moltenvk-experimental")
  let source = stage.at("moltenvk")
  try mkdir(stage)
  if !stage.at("prepared.json").exists {
    for name in lock.keys.sorted() where name != "cpm" {
      let e = lock[name] as! [String: String]
      let archive = cache.at(name + "-" + (lock[name] as! [String: String])["commit"]! + ".tar.gz")
      try download(e["url"]!, archive, e["sha256"]!)
      let directory = stage.at(name)
      if directory.exists { try fm.removeItem(at: directory) }
      try mkdir(directory)
      try command(["tar", "-xzf", archive.path, "-C", directory.path, "--strip-components=1"])
    }
    let patches = stage.at("finewine/patches/moltenvk")
    var records: [[String: String]] = []
    for (directory, folder) in [
      (source, patches), (stage.at("spirv-cross"), patches.at("spirv-cross")),
    ] {
      let patchset = try children(folder).filter { $0.pathExtension == "patch" }.sorted {
        $0.path < $1.path
      }
      try require(!patchset.isEmpty, "Missing pinned MoltenVK patches")
      for patch in patchset {
        try command(["patch", "--batch", "--fuzz=0", "-p1", "-i", patch.path], cwd: directory)
        records.append(["file": relative(patch, patches), "sha256": try digest(patch)])
      }
    }
    let cmake = source.at("MoltenVK/CMakeLists.txt")
    let text = try cmake.text
    let marker = "\tconfigure_file("
    try require(text.components(separatedBy: marker).count == 2, "Upstream revision recipe changed")
    let revision = (lock["moltenvk"] as! [String: String])["commit"]!
    try write(
      text.replacingOccurrences(of: marker, with: "\tset(MVK_GIT_REV \"\(revision)\")\n" + marker),
      cmake)
    try saveJSON(records, stage.at("prepared.json"))
  }
  let cpm = lock["cpm"] as! [String: String]
  let cpmfile = cache.at("CPM_0.40.8.cmake")
  try download(cpm["url"]!, cpmfile, cpm["sha256"]!)
  try copy(cpmfile, stage.at("cpm/cpm/CPM_0.40.8.cmake"))
  var e = env
  e["GIT_CEILING_DIRECTORIES"] = stage.path
  e["CPM_SOURCE_CACHE"] = stage.at("cpm").path
  let obj = stage.at("obj")
  var args = [
    "cmake", "-S", source.path, "-B", obj.path, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_OSX_ARCHITECTURES=x86_64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
    "-DMOLTEN_VK_WITH_CCACHE=OFF", "-DMVK_EXCLUDE_SPIRV_TOOLS=ON", "-DMVK_EXCLUDE_CEREAL=OFF",
    "-DCPM_SOURCE_CACHE=" + stage.at("cpm").path,
  ]
  for (name, package) in [
    ("spirv-cross", "SPIRV-Cross"), ("vulkan-headers", "Vulkan-Headers"), ("cereal", "cereal"),
  ] { args.append("-DCPM_\(package)_SOURCE=" + stage.at(name).path) }
  try command(args, environment: e, log: stage.at("configure.log"))
  try command(
    ["cmake", "--build", obj.path, "--target", "MoltenVK", "-j", String(jobs)], environment: e,
    log: stage.at("build.log"))
  let library = obj.at("MoltenVK/libMoltenVK.dylib")
  let arch = try command(["lipo", "-archs", library.path], capture: true).output.trimmingCharacters(
    in: .whitespacesAndNewlines)
  try require(arch == "x86_64", "Wrong MoltenVK architecture")
  for dep in try dependencies(library).dropFirst() {
    try require(
      dep.hasPrefix("/usr/lib/") || dep.hasPrefix("/System/Library/"),
      "Non-system dependency: \(dep)")
  }
  let staging = try temp(runtime.at("renderers"), ".moltenvk-")
  defer { try? fm.removeItem(at: staging) }
  let candidate = staging.at("renderer")
  try mkdir(candidate)
  let installed = candidate.at("libMoltenVK.dylib")
  try copy(library, installed)
  try command(["install_name_tool", "-id", "@rpath/libMoltenVK.dylib", installed.path])
  try sign(installed)
  try command(["codesign", "--verify", installed.path])
  for (name, file) in [
    ("MoltenVK", source.at("LICENSE")), ("SPIRV-Cross", stage.at("spirv-cross/LICENSE")),
    ("cereal", stage.at("cereal/LICENSE")),
  ] { try copy(file, candidate.at("LICENSE." + name)) }
  try copy(lockfile, candidate.at("sources.lock.json"))
  try saveJSON(
    [
      "version": "1.4.3-dev", "channel": "experimental",
      "source_commit": (lock["moltenvk"] as! [String: String])["commit"]!,
      "spirv_cross_commit": (lock["spirv-cross"] as! [String: String])["commit"]!,
      "finewine_commit": (lock["finewine"] as! [String: String])["commit"]!,
      "patches": try JSONSerialization.jsonObject(
        with: Data(contentsOf: stage.at("prepared.json"))), "library_sha256": try digest(installed),
      "build_recipe_sha256": try digest(recipe), "architecture": arch, "configuration": "Release",
      "spirv_tools": false, "pipeline_cache": true,
      "verification": "build and signature only; gameplay/performance not verified",
    ], candidate.at("provenance.json"))
  try fm.moveItem(at: candidate, to: target)
}
