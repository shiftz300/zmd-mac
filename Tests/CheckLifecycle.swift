import AppKit
import Foundation

// All native application control in this test is confined to generated fixtures.
guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Pass a lifecycle-test app.") }
let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
guard Bundle(url: bundle)?.bundleIdentifier == "local.zmdmac.endfield.lifecycle-test" else {
    fatalError("Refusing to control a non-test application.")
}
let support = bundle.appendingPathComponent("Contents/SharedSupport")
let manager = FileManager.default
struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func file(_ name: String) -> URL { support.appendingPathComponent(name) }
func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return condition()
}
if CommandLine.arguments.dropFirst(2).first == "--cleanup" {
    let base = bundle.resolvingSymlinksInPath().path + "/"
    try? Data().write(to: file("session-ended"))
    let fixtures = NSWorkspace.shared.runningApplications.filter {
        ($0.bundleIdentifier == "local.zmdmac.endfield.lifecycle-test" ||
         $0.bundleIdentifier == "local.zmdmac.endfield.lifecycle-fixture") &&
        ($0.executableURL?.resolvingSymlinksInPath().path.hasPrefix(base) == true)
    }
    for app in fixtures where !app.isTerminated { app.forceTerminate() }
    exit(wait(5, until: { fixtures.allSatisfy(\.isTerminated) }) ? 0 : 1)
}
func launch(_ path: URL, _ args: [String] = [], prefix: URL? = nil) throws -> NSRunningApplication {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.createsNewApplicationInstance = true
    config.arguments = args
    if let prefix = prefix { config.environment = ["WINEPREFIX": prefix.path] }
    var running: NSRunningApplication?
    var failure: Error?
    NSWorkspace.shared.openApplication(at: path, configuration: config) { app, error in
        running = app; failure = error
    }
    guard wait(10, until: { running != nil || failure != nil }), let app = running else {
        throw TestFailure("Could not start fixture: \(String(describing: failure))")
    }
    return app
}
let client = support.appendingPathComponent("runtime/Fixture.app")
func check(_ scenario: String) throws {
    var fixtures: [NSRunningApplication] = []
    defer {
        try? Data().write(to: file("session-ended"))
        // Only fixture instances created by this test may be forced during cleanup.
        for app in fixtures where !app.isTerminated { app.forceTerminate() }
        _ = wait(5, until: { fixtures.allSatisfy(\.isTerminated) })
    }
    func start(_ path: URL, _ args: [String] = [], prefix: URL? = nil) throws -> NSRunningApplication {
        let app = try launch(path, args, prefix: prefix)
        fixtures.append(app)
        return app
    }
    for name in ["ready", "restarted", "session-ended", "game-ready", "game-request", "game-ended",
                 "launcher-ready", "launcher-request", "launcher-ended", "launcher-wrong-order",
                 "foreign-ready", "foreign-request", "foreign-ended"] {
        try? manager.removeItem(at: file(name))
    }
    let cache = file("prefix/drive_c/users/test/AppData/LocalLow/Hypergryph/Endfield/vulkan_pso_cache.bin")
    try manager.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("cache".utf8).write(to: cache)
    try (scenario.hasSuffix("-refuse") ? "refuse" : scenario).write(to: file("scenario"), atomically: true, encoding: .utf8)
    let foreign = try start(client, ["Endfield.exe", "--support", support.path, "--kind", "foreign"], prefix: file("other-prefix"))
    let game = try start(client, ["Endfield.exe", "--support", support.path, "--kind", "game"], prefix: file("prefix"))
    let launcher = try start(client, ["Games.exe", "--support", support.path, "--kind", "launcher"], prefix: file("prefix"))
    let wrapper = try start(bundle)
    guard wait(10, until: { wrapper.activationPolicy == .accessory }) else {
        throw TestFailure("Discoverable wrapper did not hide its extra Dock icon at runtime.")
    }
    guard wait(10, until: { ["game-ready", "launcher-ready", "foreign-ready", "ready"].allSatisfy { manager.fileExists(atPath: file($0).path) } }) else {
        throw TestFailure("Fixture did not become ready.")
    }
    if scenario == "natural-exit" {
        _ = game.terminate()
        guard wait(5, until: { game.isTerminated }) else { throw TestFailure("Fixture game did not exit.") }
        _ = launcher.terminate()
    } else {
        if scenario.hasPrefix("restart") || scenario.hasPrefix("cache") {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(scenario.hasPrefix("cache") ? "local.zmdmac.TestClearCache" : "local.zmdmac.TestRestart"), object: bundle.path,
                userInfo: nil, deliverImmediately: true)
        } else {
            guard wrapper.terminate() else { throw TestFailure("Wrapper rejected the quit event.") }
        }
        guard wait(8, until: { manager.fileExists(atPath: file("game-request").path) }) else {
            throw TestFailure("Native quit did not reach the game fixture.")
        }
        if scenario == "refuse" || scenario.hasSuffix("-refuse") {
            // Cross the production deadline: no timer may force or show a dialog.
            _ = wait(16, until: { false })
            guard !game.isTerminated && !launcher.isTerminated && !wrapper.isTerminated,
                  !manager.fileExists(atPath: file("launcher-request").path) else {
                throw TestFailure("Refusal did not preserve the session.")
            }
            try "quit".write(to: file("scenario"), atomically: true, encoding: .utf8)
            guard manager.fileExists(atPath: cache.path) else { throw TestFailure("Cache removed while game refused exit.") }
            if scenario.hasSuffix("-refuse") {
                _ = game.terminate()
                guard wait(5, until: { game.isTerminated }) else { throw TestFailure("Fixture game did not exit.") }
                _ = launcher.terminate()
            } else {
                guard wrapper.terminate() else { throw TestFailure("Could not retry a cancelled quit.") }
            }
        }
    }
    if scenario == "restart" || scenario == "cache" {
        guard wait(10, until: { manager.fileExists(atPath: file("restarted").path) }),
              game.isTerminated, launcher.isTerminated, !wrapper.isTerminated else {
            throw TestFailure("Restart did not wait for the old session to finish.")
        }
        if scenario == "cache" && manager.fileExists(atPath: cache.path) {
            throw TestFailure("Cache was not cleared before restart.")
        }
        try Data().write(to: file("session-ended"))
    }
    guard wait(10, until: { game.isTerminated && launcher.isTerminated && wrapper.isTerminated }) else {
        throw TestFailure("Session failed to finish: game=\(game.isTerminated), launcher=\(launcher.isTerminated), wrapper=\(wrapper.isTerminated)")
    }
    guard !manager.fileExists(atPath: file("launcher-wrong-order").path) else {
        throw TestFailure("Official launcher was closed before the game finished.")
    }
    guard !foreign.isTerminated && !manager.fileExists(atPath: file("foreign-request").path) else {
        throw TestFailure("Quit escaped to another Wine prefix sharing the runtime.")
    }
    if scenario.hasSuffix("-refuse") && manager.fileExists(atPath: file("restarted").path) {
        throw TestFailure("A cancelled restart was unexpectedly resumed.")
    }
    if scenario != "cache" && !manager.fileExists(atPath: cache.path) {
        throw TestFailure("Cache removed without a completed clear request.")
    }
    print("\(scenario): PASS (native quit, game before launcher, other prefix preserved)")
}
do {
    for scenario in ["quit", "slow", "refuse", "natural-exit", "restart", "restart-refuse", "cache", "cache-refuse"] { try check(scenario) }
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
