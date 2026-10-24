import CryptoKit
import Foundation

let fm = FileManager.default
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()
let env = ProcessInfo.processInfo.environment
let work = URL(fileURLWithPath: env["ZMD_WORK_DIR"] ?? project.path).standardizedFileURL
let version = "0.8.0"
struct Failure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure(message) }
}
extension URL {
  func at(_ path: String) -> URL { appendingPathComponent(path) }
  var exists: Bool { fm.fileExists(atPath: path) }
  var link: Bool { (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
  var text: String { get throws { try String(contentsOf: self, encoding: .utf8) } }
}
func mkdir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
func write(_ text: String, _ url: URL) throws {
  try mkdir(url.deletingLastPathComponent())
  try text.write(to: url, atomically: true, encoding: .utf8)
}
func files(_ url: URL) -> [URL] {
  (fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])?
    .allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
}
func children(_ url: URL) throws -> [URL] {
  try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
}
func regular(_ url: URL) -> Bool {
  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}
func digest(_ url: URL) throws -> String {
  let f = try FileHandle(forReadingFrom: url)
  defer { try? f.close() }
  var h = SHA256()
  while let data = try f.read(upToCount: 1_048_576), !data.isEmpty { h.update(data: data) }
  return h.finalize().map { String(format: "%02x", $0) }.joined()
}
func json(_ url: URL) throws -> [String: Any] {
  try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}
func saveJSON(_ value: Any, _ url: URL) throws {
  try mkdir(url.deletingLastPathComponent())
  try JSONSerialization.data(
    withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  ).write(to: url, options: .atomic)
}
func plist(_ url: URL) throws -> [String: Any] {
  try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    as! [String: Any]
}
func savePlist(_ value: Any, _ url: URL) throws {
  try mkdir(url.deletingLastPathComponent())
  try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(
    to: url, options: .atomic)
}
func copy(_ from: URL, _ to: URL) throws {
  try mkdir(to.deletingLastPathComponent())
  if to.exists || to.link { try fm.removeItem(at: to) }
  try fm.copyItem(at: from, to: to)
}
func clone(_ from: URL, _ to: URL) throws {
  try mkdir(to.deletingLastPathComponent())
  try command(["/bin/cp", "-cR", from.path, to.path])
}
func temp(_ parent: URL = fm.temporaryDirectory, _ name: String = "zmd-") throws -> URL {
  try mkdir(parent)
  // mkdtemp creates exclusively and keeps Wine paths below legacy path limits.
  var template = Array(parent.at(name + "XXXXXX").path.utf8CString)
  return try template.withUnsafeMutableBufferPointer { buffer in
    guard let result = mkdtemp(buffer.baseAddress!) else { throw Failure("Cannot create temporary directory") }
    return URL(fileURLWithPath: String(cString: result))
  }
}
func relative(_ target: URL, _ base: URL) -> String {
  let a = target.standardizedFileURL.pathComponents
  let b = base.standardizedFileURL.pathComponents
  var i = 0
  while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
  return (Array(repeating: "..", count: b.count - i) + a.dropFirst(i)).joined(separator: "/")
}
struct CommandResult {
  let status: Int32
  let output: String
}
@discardableResult
func command(
  _ args: [String], cwd: URL? = nil, environment: [String: String]? = nil, capture: Bool = false,
  allowFailure: Bool = false, timeout: Double = 7200, input: URL? = nil, log: URL? = nil
) throws -> CommandResult {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = args
  p.currentDirectoryURL = cwd ?? project
  p.environment = environment ?? env
  p.standardInput = input == nil ? FileHandle.nullDevice : try FileHandle(forReadingFrom: input!)
  // File capture avoids pipe-buffer deadlocks on verbose compiler output.
  let captureURL = capture ? fm.temporaryDirectory.at("zmd-output-" + UUID().uuidString) : log
  var handle: FileHandle?
  if let url = captureURL {
    try mkdir(url.deletingLastPathComponent())
    fm.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
    p.standardOutput = handle
  }
  if log != nil { p.standardError = handle }
  defer {
    try? handle?.close()
    if capture, let url = captureURL { try? fm.removeItem(at: url) }
  }
  let done = DispatchSemaphore(value: 0)
  p.terminationHandler = { _ in done.signal() }
  try p.run()
  if done.wait(timeout: .now() + timeout) == .timedOut {
    p.terminate()
    if done.wait(timeout: .now() + 5) == .timedOut {
      kill(p.processIdentifier, SIGKILL)
      p.waitUntilExit()
    }
    throw Failure("Timed out: \(args.first ?? "command")")
  }
  let result = CommandResult(
    status: p.terminationStatus,
    output: capture ? String(decoding: try Data(contentsOf: captureURL!), as: UTF8.self) : "")
  try require(
    allowFailure || result.status == 0,
    "Command failed (\(result.status)): \(args.first ?? "command")")
  return result
}
func download(_ url: String, _ target: URL, _ sha: String, headers: [String: String] = [:]) throws {
  if target.exists, try digest(target) == sha { return }
  try mkdir(target.deletingLastPathComponent())
  let partial = target.appendingPathExtension("part")
  var args = [
    "curl", "-fLsS", "--proto", "=https", "--proto-redir", "=https", "--retry", "3",
    "--connect-timeout", "30",
  ]
  for key in headers.keys.sorted() { args += ["-H", key + ": " + headers[key]!] }
  try command(args + ["-o", partial.path, url])
  try require(try digest(partial) == sha, "Checksum mismatch: \(target.lastPathComponent)")
  if target.exists { try fm.removeItem(at: target) }
  try fm.moveItem(at: partial, to: target)
}
func macho(_ path: URL) -> Bool {
  guard regular(path), !path.link, let f = try? FileHandle(forReadingFrom: path) else {
    return false
  }
  defer { try? f.close() }
  guard let d = try? f.read(upToCount: 4) else { return false }
  return [
    [0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe],
    [0xfe, 0xed, 0xfa, 0xcf], [0xbe, 0xba, 0xfe, 0xca],
  ].contains(Array(d).map(Int.init))
}
func writable(_ file: URL) throws {
  let a = try fm.attributesOfItem(atPath: file.path)
  try fm.setAttributes(
    [.posixPermissions: (a[.posixPermissions] as! NSNumber).intValue | 0o200],
    ofItemAtPath: file.path)
}
func dependencies(_ file: URL) throws -> [String] {
  try command(["otool", "-L", file.path], capture: true).output.split(separator: "\n").dropFirst()
    .filter { $0.hasPrefix("\t") }.map {
      $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " (")[0]
    }
}
func sign(_ file: URL) throws { try command(["codesign", "--force", "--sign", "-", file.path]) }
func compile(_ sources: [String], _ output: URL, defines: [String] = []) throws {
  try mkdir(output.deletingLastPathComponent())
  try mkdir(work.at("build/swift-module-cache"))
  let mode =
    sources.contains { (try? project.at($0).text.contains("@main")) == true }
    ? ["-parse-as-library"] : []
  try command(
    ["xcrun", "swiftc", "-O", "-module-cache-path", work.at("build/swift-module-cache").path] + mode
      + defines.flatMap { ["-D", $0] } + sources.map { project.at($0).path } + ["-o", output.path])
}
let runtimeSources = ["Sources/Runtime/Application.swift", "Sources/Runtime/WineRuntime.swift"]
let cliSources = runtimeSources + ["Sources/CLI/main.swift"]
let settingsSources = runtimeSources + ["Sources/Launcher/Settings.swift"]
let launcherSources = settingsSources + ["Sources/Launcher/Launcher.swift"]
func checksumFile(_ file: URL) throws {
  try write(
    try digest(file) + "  " + file.lastPathComponent + "\n", file.appendingPathExtension("sha256"))
}
func ensurePatch(_ patch: URL, _ source: URL, idempotent: Bool = true) throws {
  var environment = env
  environment["GIT_CEILING_DIRECTORIES"] = source.deletingLastPathComponent().path
  if idempotent,
    try command(
      ["git", "apply", "--reverse", "--check", patch.path], cwd: source, environment: environment,
      capture: true, allowFailure: true
    ).status == 0
  {
    return
  }
  try command(["git", "apply", "--check", patch.path], cwd: source, environment: environment)
  try command(["git", "apply", patch.path], cwd: source, environment: environment)
}

func matches(_ pattern: String, _ text: String) throws -> [String] {
  let regex = try NSRegularExpression(pattern: pattern)
  return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
    String(text[Range($0.range, in: text)!])
  }
}
