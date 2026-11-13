import AppKit
import CoreGraphics

/// Screen capture helpers built on CoreGraphics.
///
/// Coordinate systems:
/// - AppKit global space: origin at the bottom-left of the primary screen, y grows upward.
/// - CoreGraphics display space: origin at the top-left of the primary display, y grows downward.
/// All public functions here take **CoreGraphics global** rects; use `cgRect(fromAppKit:)` to convert.
enum ScreenCapture {

    /// Returns true if the process already has the Screen Recording permission.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for the Screen Recording permission (shows the system prompt once).
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures an entire display at native pixel resolution.
    static func captureDisplay(_ displayID: CGDirectDisplayID = CGMainDisplayID()) -> CGImage? {
        CGDisplayCreateImage(displayID)
    }

    /// Captures the display that hosts the mouse cursor.
    static func captureScreenUnderMouse() -> CGImage? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return captureDisplay(screen?.displayID ?? CGMainDisplayID())
    }

    /// Captures a rectangle expressed in CoreGraphics global coordinates (points).
    /// Rectangles spanning several displays are composited into a single image.
    static func capture(globalRect rect: CGRect) -> CGImage? {
        let rect = rect.integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetDisplaysWithRect(rect, count, &displays, &count) == .success else { return nil }

        // Fast path: whole rect lives on one display.
        if displays.count == 1 {
            let bounds = CGDisplayBounds(displays[0])
            let local = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            return CGDisplayCreateImage(displays[0], rect: local)
        }

        // Composite: render at the highest scale among the involved displays.
        let scale = displays.map(scaleFactor(of:)).max() ?? 1
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high

        for display in displays {
            let bounds = CGDisplayBounds(display)
            let piece = bounds.intersection(rect)
            guard !piece.isNull, !piece.isEmpty else { continue }
            let local = piece.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            guard let image = CGDisplayCreateImage(display, rect: local) else { continue }
            // Destination in the bitmap: CG contexts are bottom-left origin, CG display space is top-left.
            let dest = CGRect(x: (piece.minX - rect.minX) * scale,
                              y: (rect.maxY - piece.maxY) * scale,
                              width: piece.width * scale,
                              height: piece.height * scale)
            ctx.draw(image, in: dest)
        }
        return ctx.makeImage()
    }

    /// Converts an AppKit global rect (bottom-left origin) to CoreGraphics global space (top-left origin).
    static func cgRect(fromAppKit rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func scaleFactor(of display: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

extension CGImage {
    /// Wraps the image in an NSImage whose point size matches the given scale (e.g. 2 for Retina).
    func nsImage(scale: CGFloat) -> NSImage {
        let s = max(scale, 1)
        return NSImage(cgImage: self, size: NSSize(width: CGFloat(width) / s, height: CGFloat(height) / s))
    }
}
