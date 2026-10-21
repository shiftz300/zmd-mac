import Foundation

@main enum WineRunner {
  static func main() {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      try check(args.count >= 2, "support path and Wine arguments required")
      let runtime = WineRuntime(support: URL(fileURLWithPath: args[0]))
      if args[1] == "--apply-resolution" {
        try runtime.applyGameResolution()
        return
      }
      exit(try runtime.execute(Array(args.dropFirst())))
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(2)
    }
  }
}
