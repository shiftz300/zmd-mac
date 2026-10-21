import AppKit
import IOKit.graphics

struct DisplayPixelMode {
    let width: Int
    let height: Int
    let flags: UInt32
}

struct DisplayResolution: Hashable {
    let width: Int
    let height: Int

    // Current-mode pixels can be a supersampled HiDPI buffer (e.g. 5120×2880
    // on a 3840×2160 panel). Only use modes explicitly marked native by macOS.
    static func native(modes: [DisplayPixelMode], portrait: Bool) -> Self? {
        let sizes = Set(modes.compactMap { mode -> Self? in
            guard mode.flags & UInt32(kDisplayModeNativeFlag) != 0,
                  mode.width > 0, mode.height > 0 else { return nil }
            let short = min(mode.width, mode.height)
            let long = max(mode.width, mode.height)
            // Mode dimensions can already be rotated; orient once to the screen.
            return Self(width: portrait ? short : long, height: portrait ? long : short)
        })
        // Don't guess from the largest mode or silently fall back to points.
        return sizes.count == 1 ? sizes.first : nil
    }

    static func read(_ screen: NSScreen) throws -> Self {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let modes = CGDisplayCopyAllDisplayModes(number.uint32Value,
                  [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode],
              let size = native(modes: modes.map {
                  DisplayPixelMode(width: $0.pixelWidth, height: $0.pixelHeight, flags: $0.ioFlags)
              }, portrait: screen.frame.height > screen.frame.width) else {
            throw ZMDError("无法确认屏幕的原生像素分辨率，请手动选择。")
        }
        return size
    }
}
