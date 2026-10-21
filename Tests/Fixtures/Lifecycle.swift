import AppKit
import Foundation

let values = CommandLine.arguments
func argument(_ key: String) -> String {
    guard let index = values.firstIndex(of: key), index + 1 < values.count else { fatalError(key) }
    return values[index + 1]
}
let support = URL(fileURLWithPath: argument("--support"))
let kind = argument("--kind")
func mark(_ suffix: String) { try! Data().write(to: support.appendingPathComponent(kind + "-" + suffix)) }
final class Fixture: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { mark("ready") }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mark("request")
        let mode = try! String(contentsOf: support.appendingPathComponent("scenario"), encoding: .utf8)
        if kind == "game" && mode == "refuse" { return .terminateCancel }
        if kind == "launcher" && !FileManager.default.fileExists(atPath: support.appendingPathComponent("game-ended").path) {
            mark("wrong-order")
        }
        if kind == "game" && mode == "slow" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { mark("ended") }
}
let fixture = Fixture()
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = fixture
NSApplication.shared.run()
