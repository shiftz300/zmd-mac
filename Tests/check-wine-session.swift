import AppKit
import Foundation

let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
guard Bundle(url: bundle)?.bundleIdentifier == "local.zmdmac.wine-session-test" else { exit(2) }
if CommandLine.arguments.dropFirst(2).first == "--cleanup" {
    for app in NSWorkspace.shared.runningApplications
    where app.bundleIdentifier == "local.zmdmac.wine-session-test" &&
        app.bundleURL?.path == bundle.path {
        app.forceTerminate()
    }
    exit(0)
}
let support = bundle.appendingPathComponent("Contents/SharedSupport")
let markers = support.appendingPathComponent("markers")
func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: markers.appendingPathComponent(name).path)
}
func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return condition()
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
var wrapper: NSRunningApplication?
NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
    wrapper = app
    if let error = error { print(error) }
}
guard wait(30, { wrapper != nil && exists("game-ready") && exists("launcher-ready") && exists("helper-ready") }),
      let wrapper = wrapper else { print("FAIL: fixtures did not start"); exit(1) }
guard wrapper.activationPolicy == .accessory else { print("FAIL: wrapper has Dock icon"); exit(1) }
// Names must come from our own runtime's named loader links, not arbitrary apps.
let loader = support.appendingPathComponent("runtime/wine/lib/wine/x86_64-unix/wine")
let inode = try FileManager.default.attributesOfItem(atPath: loader.path)[.systemFileNumber] as? NSNumber
let device = try FileManager.default.attributesOfItem(atPath: loader.path)[.systemNumber] as? NSNumber
func own(_ app: NSRunningApplication) -> Bool {
    guard let path = app.executableURL?.resolvingSymlinksInPath().path,
          let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
    return attrs[.systemFileNumber] as? NSNumber == inode && attrs[.systemNumber] as? NSNumber == device
}
let apps = NSWorkspace.shared.runningApplications.filter(own)
guard let game = apps.first(where: { $0.localizedName == "终末地" }),
      let launcher = apps.first(where: { $0.localizedName == "鹰角启动器" }) else {
    print("FAIL: wrong names: \(apps.map { $0.localizedName ?? "" })"); exit(1)
}
// Equivalent to choosing Quit on a Wine Dock icon, not on the wrapper.
let scenario = CommandLine.arguments.dropFirst(2).first ?? "game"
let selected = scenario.hasPrefix("launcher") ? launcher : game
if scenario == "launcher-retry" { try Data().write(to: markers.appendingPathComponent("reject-qt")) }
_ = selected.terminate()
if scenario == "launcher-retry" {
    guard wait(10, { exists("launcher-qt-rejected") }) else {
        print("FAIL: did not exercise unavailable Qt action"); exit(1)
    }
    _ = wait(16, { false }) // Cross the coordinator's quiet cancellation deadline.
    guard !launcher.isTerminated, !wrapper.isTerminated,
          !exists("launcher-query"), !exists("launcher-ended"), !exists("helper-query") else {
        print("FAIL: unavailable Qt action must preserve the launcher"); exit(1)
    }
    try FileManager.default.removeItem(at: markers.appendingPathComponent("reject-qt"))
    _ = selected.terminate()
}
guard wait(20, { wrapper.isTerminated && game.isTerminated && launcher.isTerminated }) else {
    print("FAIL: session still running"); exit(1)
}
guard exists("game-close"), !exists("game-query"), exists("launcher-tray-exit"),
      exists("launcher-ended"), !exists("launcher-query") else {
    print("FAIL: wrong shutdown path"); exit(1)
}
guard exists("helper-ended"), !exists("helper-query"), !exists("helper-close") else {
    print("FAIL: coordinator interrupted a launcher-owned helper"); exit(1)
}
print("PASS: \(scenario) Quit -> game close -> launcher tray Exit -> helper drains; no session-end fallback")
