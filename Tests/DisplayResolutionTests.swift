import AppKit
import IOKit.graphics

@main
enum DisplayResolutionTests {
    static func main() throws {
        let native = UInt32(kDisplayModeNativeFlag)
        let retina = DisplayPixelMode(width: 3024, height: 1964, flags: native)
        precondition(DisplayResolution.native(modes: [retina], portrait: false)
                     == DisplayResolution(width: 3024, height: 1964))
        let panel = DisplayPixelMode(width: 3840, height: 2160, flags: native)
        let buffer = DisplayPixelMode(width: 5120, height: 2880, flags: 3)
        let points = DisplayPixelMode(width: 2560, height: 1440, flags: 3)
        precondition(DisplayResolution.native(modes: [buffer, points, panel, panel], portrait: false)
                     == DisplayResolution(width: 3840, height: 2160))
        let rotated = DisplayPixelMode(width: 2160, height: 3840, flags: native)
        precondition(DisplayResolution.native(modes: [panel, rotated], portrait: true)
                     == DisplayResolution(width: 2160, height: 3840))
        precondition(DisplayResolution.native(modes: [buffer, points], portrait: false) == nil)
        precondition(DisplayResolution.native(modes: [], portrait: false) == nil)
        precondition(DisplayResolution.native(modes: [panel, retina], portrait: false) == nil)
        precondition(DisplayResolution.native(modes: [
            DisplayPixelMode(width: 0, height: 2160, flags: native)
        ], portrait: false) == nil)
        print("PASS: native pixels, HiDPI supersampling, duplicate modes, rotation and unavailable/ambiguous modes")
        if CommandLine.arguments.contains("--live") {
            guard !NSScreen.screens.isEmpty else { throw ZMDError("No connected screens") }
            for screen in NSScreen.screens {
                let size = try DisplayResolution.read(screen)
                print("\(screen.localizedName): \(size.width)×\(size.height) pixels (desktop \(screen.frame.size))")
            }
        }
    }
}
