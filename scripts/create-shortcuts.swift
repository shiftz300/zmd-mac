import AppKit
import Foundation

// Finder aliases preserve the live bundle location and do not duplicate game data.
guard CommandLine.arguments.count >= 3 else {
    fatalError("Usage: create-shortcuts.swift application.app alias.app [alias.app ...]")
}
let manager = FileManager.default
let application = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard Bundle(url: application)?.executableURL != nil else {
    fatalError("The target is not an application bundle.")
}
let destinations = CommandLine.arguments.dropFirst(2).map {
    URL(fileURLWithPath: $0).standardizedFileURL
}
// Validate all destinations before creating any files; preserve unrelated entries.
for destination in destinations {
    guard manager.fileExists(atPath: destination.deletingLastPathComponent().path) else {
        fatalError("Destination folder does not exist: \(destination.path)")
    }
    if manager.fileExists(atPath: destination.path) {
        let existing = try URL(resolvingAliasFileAt: destination, options: [.withoutUI])
        guard existing.standardizedFileURL == application else {
            fatalError("Refusing to replace an existing item: \(destination.path)")
        }
    }
}
let data = try application.bookmarkData(
    options: [.suitableForBookmarkFile],
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
let icon = NSImage(contentsOf: application.appendingPathComponent("Contents/Resources/Endfield.icns"))
for destination in destinations {
    if !manager.fileExists(atPath: destination.path) {
        try URL.writeBookmarkData(data, to: destination)
    }
    if let icon = icon {
        guard NSWorkspace.shared.setIcon(icon, forFile: destination.path, options: []) else {
            fatalError("Could not set shortcut icon: \(destination.path)")
        }
    }
    let resolved = try URL(resolvingAliasFileAt: destination, options: [.withoutUI])
    guard resolved.standardizedFileURL == application else {
        fatalError("Shortcut verification failed: \(destination.path)")
    }
    print("\(destination.path) -> \(resolved.path)")
}
