import Foundation

@main enum GameResolutionTests {
  static func main() throws {
    let keys = ["Screenmanager Resolution Width_h182942802",
                "Screenmanager Resolution Height_h2627697771",
                "Screenmanager Resolution Window Width_h2524650974",
                "Screenmanager Resolution Window Height_h1684712807",
                "video_resolution_width_h583690364", "video_resolution_height_h2517654917"]
    func fixture(_ key: String) -> String {
      "Windows Registry Editor Version 5.00\r\n\r\n[\(key)]\r\n"
        + keys.map { "\"\($0)\"=dword:00000100" }.joined(separator: "\r\n")
        + "\r\n\"Screenmanager Resolution Width Default_h1\"=dword:00000400\r\n"
        + "\"unrelated-setting\"=\"keep-me\"\r\n"
    }
    for company in ["Hypergryph", "Gryphline"] {
      let key = "HKEY_CURRENT_USER\\Software\\\(company)\\Endfield"
      let source = fixture(key) + "\r\n[\(key)\\Other]\r\n\"video_resolution_width_h9\"=dword:00000001\r\n"
      let edit = try GameResolutionEdit(exported: source, key: key, resolution: "3024x1964")
      try check(edit.updated.count == 6 && edit.original.count == 6, "Wrong preference selection")
      try check(edit.updated.filter { $0.hasSuffix("00000bd0") }.count == 3, "Width not synchronized")
      try check(edit.updated.filter { $0.hasSuffix("000007ac") }.count == 3, "Height not synchronized")
      try check(!edit.document(edit.original).contains("keep-me"), "Backup contains unrelated data")
      try check(try GameResolutionEdit(exported: source, key: key, resolution: "game").updated.isEmpty,
                "Game setting must not override preferences")
      let partial = source.replacingOccurrences(of: "video_resolution_height_h2517654917", with: "unknown")
      do {
        _ = try GameResolutionEdit(exported: partial, key: key, resolution: "3024x1964")
        throw NSError(domain: "Expected partial configuration rejection", code: 1)
      } catch is ZMDError {}
    }
    print("PASS: CN/Global resolution values, unrelated/default/subkey preservation, minimal backup and incomplete schema")
    try check(!savedRetinaMode(""), "Absent Retina preference must be off")
    try check(savedRetinaMode("[Software\\\\Wine\\\\Mac Driver] 123\n\"RetinaMode\"=\"y\"\n"), "Retina preference")
    try check(!savedRetinaMode("[Software\\\\Wine\\\\AppDefaults\\\\game.exe\\\\Mac Driver]\n\"RetinaMode\"=\"y\"\n"),
              "Retina must be prefix-wide, not per-app")
    guard CommandLine.arguments.count > 1 else { return }
    let fm = FileManager.default
    var template = Array("/tmp/zmd-res-XXXXXX".utf8CString)
    let root = try template.withUnsafeMutableBufferPointer { p -> URL in
      guard let path = mkdtemp(p.baseAddress!) else { throw ZMDError("mkdtemp") }
      return URL(fileURLWithPath: String(cString: path))
    }
    try fm.createSymbolicLink(at: root.appendingPathComponent("runtime"),
                             withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[1]))
    var runtime = WineRuntime(support: root)
    runtime.inherited["ZMD_PREFIX"] = root.appendingPathComponent("prefix").path
    runtime.inherited["ZMD_RENDERER"] = "dxmt"
    runtime.inherited["ZMD_SESSION_ID"] = nil
    runtime.inherited["WINEDEBUG"] = "-all"
    defer {
      _ = try? runtime.execute(["-k"], server: true)
      _ = try? runtime.execute(["-w"], server: true)
      try? fm.removeItem(at: root)
    }
    try writeText("3024x1964", root.appendingPathComponent("resolution.conf"))
    try runtime.applyGameResolution() // Fresh prefix has no game settings.
    // Exercise the production Retina transition, including the graceful setup-session wait.
    for (choice, resolution, expected) in [("auto", "3024x1964", true), ("auto", "game", false),
                                          ("on", "game", true), ("off", "3024x1964", false)] {
      try writeText(choice, root.appendingPathComponent("retina.conf"))
      try writeText(resolution, root.appendingPathComponent("resolution.conf"))
      try runtime.applyRetinaMode()
      let saved = try String(contentsOf: root.appendingPathComponent("prefix/user.reg"), encoding: .utf8)
      try check(savedRetinaMode(saved) == expected, "Retina transition did not flush before launch")
      try runtime.applyRetinaMode() // Already configured: must remain a no-op.
    }
    print("PASS: real Wine Retina auto/on/off transitions and graceful session drain")
    try writeText("3024x1964", root.appendingPathComponent("resolution.conf"))
    for (region, company) in [("cn", "Hypergryph"), ("global", "Gryphline")] {
      try writeText(region, root.appendingPathComponent("region.conf"))
      let key = "HKEY_CURRENT_USER\\Software\\\(company)\\Endfield"
      let input = root.appendingPathComponent("fixture.reg")
      try fixture(key).write(to: input, atomically: true, encoding: .utf16)
      try check(try runtime.execute(["reg", "import", input.path]) == 0, "Fixture import")
      try runtime.applyGameResolution()
      let output = root.appendingPathComponent("after.reg")
      try check(try runtime.execute(["reg", "export", key, output.path, "/y"]) == 0, "Export")
      let actual = try String(contentsOf: output, encoding: .utf16)
      let parsed = try GameResolutionEdit(exported: actual, key: key, resolution: "3024x1964")
      try check(parsed.original == parsed.updated, "Real Wine values not updated")
      try check(actual.contains("keep-me") && actual.contains("Default_h1\"=dword:00000400"),
                "Real Wine unrelated values changed")
      let backup = root.appendingPathComponent("display-resolution-original.reg")
      let original = try Data(contentsOf: backup)
      try runtime.applyGameResolution()
      try check(try Data(contentsOf: backup) == original, "Original backup overwritten")
      try writeText("game", root.appendingPathComponent("resolution.conf"))
      try runtime.applyGameResolution()
      try check(try runtime.execute(["reg", "export", key, output.path, "/y"]) == 0, "Export game mode")
      try check(try String(contentsOf: output, encoding: .utf16) == actual, "Game mode altered registry")
      try writeText("3024x1964", root.appendingPathComponent("resolution.conf"))
      try fm.removeItem(at: backup)
      print("PASS: real Wine \(region) preference import, preservation, backup and game-default no-op")
    }
  }
}
