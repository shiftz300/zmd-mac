import Foundation

@main enum RuntimeProbe {
  static func main() throws {
    let env = ProcessInfo.processInfo.environment
    let args = Array(CommandLine.arguments.dropFirst())
    if let destination = env["ZMD_PROBE_OUTPUT"] {
      try JSONSerialization.data(
        withJSONObject: ["arguments": args, "environment": env], options: [.sortedKeys]
      ).write(to: URL(fileURLWithPath: destination))
    }
    if let mode = env["ZMD_PROBE_MODE"], mode == "reg", args.first == "reg" {
      if args.count > 1 && args[1] == "export" { exit(1) }
      try JSONSerialization.data(withJSONObject: args).write(
        to: URL(
          fileURLWithPath: "captured-args",
          relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
    }
    if args.first == "C:\\EndfieldLauncher\\Launcher.exe" {
      exit(Int32(env["ZMD_PROBE_EXIT"] ?? "0") ?? 0)
    }
  }
}
