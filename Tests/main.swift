import Foundation

func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch { print("PASS: \(label)"); return }
    throw ZMDError("Expected rejection: \(label)")
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("zmd-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let valid = """
Path = $0/1.6.0/Games.exe
Size = 1024

Path = $0/1.6.0/Launcher.exe
Size = 1024
"""
try check(try GameRegion.parse("cn") == .cn, "CN region")
try check(try GameRegion.parse("global") == .global, "global region")
try check(GameRegion.cn.appName != GameRegion.global.appName, "regions must not share default app")
try check(URL(string: GameRegion.global.installerURL)?.host == "launcher.gryphline.com", "official global download host")
try rejects("unknown region") { _ = try GameRegion.parse("typo") }
try validateInstallerListing(valid)
for bad in ["../escape", "/tmp/escape", "C:\\escape", "$0/../../escape", "$0\\..\\escape"] {
    try rejects("archive path: \(bad)") { try validateInstallerListing(valid + "\nPath = " + bad) }
}
try rejects("ambiguous version") {
    try validateInstallerListing(valid + "\nPath = $0/2.0/Games.exe")
}
try rejects("direct game executable") { try validateInstallerListing("Path = Endfield.exe\nSize = 5") }
try rejects("archive symlink") { try validateInstallerListing(valid + "\nSymbolic Link = /tmp") }
try rejects("oversized archive") { try validateInstallerListing(valid + "\nSize = 8589934592") }

let content = root.appendingPathComponent("file with spaces")
try Data("abc".utf8).write(to: content)
let hash = try sha256(content)
try check(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 implementation")
let manifest = root.appendingPathComponent("manifest.json")
try JSONEncoder().encode(PayloadManifest(format: 1, files: ["file with spaces": hash], links: [:])).write(to: manifest)
try verifyPayload(root)
try Data("changed".utf8).write(to: content)
try rejects("modified payload") { try verifyPayload(root) }
try Data("abc".utf8).write(to: content)
let extra = root.appendingPathComponent("unlisted")
try Data().write(to: extra)
try rejects("unlisted payload") { try verifyPayload(root) }
try FileManager.default.removeItem(at: extra)
let link = root.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp")
try JSONEncoder().encode(PayloadManifest(format: 1, files: ["file with spaces": hash], links: ["link": "/tmp"])).write(to: manifest)
try rejects("escaping payload link") { try verifyPayload(root) }
try FileManager.default.removeItem(at: link)
try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "file with spaces")
try JSONEncoder().encode(PayloadManifest(format: 1, files: ["file with spaces": hash], links: ["link": "file with spaces"])).write(to: manifest)
try verifyPayload(root)

let literal = "path with spaces; $(echo no) `echo no`"
try check(try run("/usr/bin/printf", ["%s", literal], capture: true) == literal, "Argument escaping")
print("PASS: payload hashes, internal links and literal process arguments")

let cacheApp = root.appendingPathComponent("Cache Test.app")
let profiles = cacheApp.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/users")
let cnCache = profiles.appendingPathComponent("user/AppData/LocalLow/Hypergryph/Endfield/vulkan_pso_cache.bin")
let globalCache = profiles.appendingPathComponent("user/AppData/LocalLow/Gryphline/Endfield/vulkan_pso_cache.bin")
for cache in [cnCache, globalCache] {
    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("cache".utf8).write(to: cache)
}
let prefs = cnCache.deletingLastPathComponent().appendingPathComponent("settings.json")
try Data("keep".utf8).write(to: prefs)
try check(try clearVulkanCache(cacheApp) == 2, "clear both known cache paths")
try check(try Data(contentsOf: prefs) == Data("keep".utf8), "preserve adjacent settings")
try check(try clearVulkanCache(cacheApp) == 0, "missing cache is harmless")
let outsideCache = root.appendingPathComponent("outside-cache")
try Data("keep".utf8).write(to: outsideCache)
try FileManager.default.createSymbolicLink(at: cnCache, withDestinationURL: outsideCache)
try rejects("cache file symlink") { _ = try clearVulkanCache(cacheApp) }
try FileManager.default.removeItem(at: cnCache)
try FileManager.default.createDirectory(at: cnCache, withIntermediateDirectories: true)
try rejects("cache path is directory") { _ = try clearVulkanCache(cacheApp) }
try FileManager.default.removeItem(at: cnCache)
let externalProfile = root.appendingPathComponent("external-profile")
let externalPipeline = externalProfile.appendingPathComponent("AppData/LocalLow/Hypergryph/Endfield/vulkan_pso_cache.bin")
try FileManager.default.createDirectory(at: externalPipeline.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("keep".utf8).write(to: externalPipeline)
try FileManager.default.createSymbolicLink(at: profiles.appendingPathComponent("linked-user"), withDestinationURL: externalProfile)
try rejects("profile symlink escapes prefix") { _ = try clearVulkanCache(cacheApp) }
try check(try Data(contentsOf: externalPipeline) == Data("keep".utf8), "preserve outside cache")
print("PASS: scoped Vulkan cache clearing, absent files and external path protection")
