import Foundation

func fixtureSession() throws -> Bool {
  let support = Bundle.main.bundleURL.appendingPathComponent("Contents/SharedSupport")
  let fm = FileManager.default
  func file(_ name: String) -> URL { support.appendingPathComponent(name) }
  func exists(_ name: String) -> Bool { fm.fileExists(atPath: file(name).path) }
  #if WINE_SESSION_TEST
    var runtime = WineRuntime(support: support)
    runtime.inherited["ZMD_SESSION_TEST_DIR"] = "Z:" + file("markers").path
    var processes: [Process] = []
    for (name, role) in [
      ("Endfield.exe", "game"), ("Games.exe", "launcher"), ("QtWebEngineProcess.exe", "helper"),
    ] {
      let p = Process()
      p.executableURL = runtime.runtime.appendingPathComponent("wine/bin/wine")
      p.arguments = ["start.exe", "/wait", "/unix", file(name).path, role]
      p.currentDirectoryURL = file("markers")
      p.environment = try runtime.environment()
      try p.run()
      processes.append(p)
    }
    for p in processes {
      p.waitUntilExit()
      try check(p.terminationStatus == 0, "Wine fixture failed")
    }
    try check(try runtime.execute(["-w"], server: true) == 0, "Wine server wait failed")
  #else
    if exists("ready") {
      fm.createFile(atPath: file("restarted").path, contents: nil)
      while !exists("session-ended") { Thread.sleep(forTimeInterval: 0.1) }
    } else {
      fm.createFile(atPath: file("ready").path, contents: nil)
      while !exists("session-ended") {
        if exists("game-ended") && exists("launcher-ended") { break }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }
  #endif
  return true
}
