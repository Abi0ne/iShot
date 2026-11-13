import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case emptyRect
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The display to capture could not be found."
        case .emptyRect: return "The selected area is empty."
        case .windowNotFound: return "The window to capture is no longer on screen."
        }
    }
}

/// Screen capture helpers built on ScreenCaptureKit (`SCScreenshotManager`).
///
/// The legacy `CGDisplayCreateImage` API is deprecated since macOS 15 and makes the system
/// re-ask for Screen Recording periodically, so it is no longer used.
///
/// Coordinate systems:
/// - AppKit global space: origin at the bottom-left of the primary screen, y grows upward.
/// - CoreGraphics display space: origin at the top-left of the primary display, y grows downward.
/// All public functions here take **CoreGraphics global** rects; use `cgRect(fromAppKit:)` to convert.
enum ScreenCapture {

    /// Returns true if the process already has the Screen Recording permission.
    /// Note: after granting it in System Settings the process must be relaunched before this turns true.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for the Screen Recording permission (shows the system prompt once).
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures an entire display at native pixel resolution.
    static func captureDisplay(_ displayID: CGDirectDisplayID = CGMainDisplayID()) async throws -> CGImage {
        let display = try await scDisplay(for: displayID)
        return try await capture(display: display, sourceRect: nil)
    }

    /// Captures a rectangle expressed in CoreGraphics global coordinates (points).
    /// Rectangles spanning several displays are composited into a single image.
    static func capture(globalRect rect: CGRect) async throws -> CGImage {
        let rect = rect.integral
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.emptyRect }

        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 0, nil, &count) == .success, count > 0 else { throw CaptureError.displayNotFound }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetDisplaysWithRect(rect, count, &displayIDs, &count) == .success else { throw CaptureError.displayNotFound }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = displayIDs.compactMap { id in content.displays.first { $0.displayID == id } }
        guard !displays.isEmpty else { throw CaptureError.displayNotFound }

        // Fast path: whole rect lives on one display.
        if displays.count == 1 {
            let bounds = CGDisplayBounds(displays[0].displayID)
            return try await capture(display: displays[0], sourceRect: rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
        }

        // Composite: render at the highest scale among the involved displays.
        let scale = displays.map { scaleFactor(of: $0.displayID) }.max() ?? 1
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw CaptureError.emptyRect }
        ctx.interpolationQuality = .high

        for display in displays {
            let bounds = CGDisplayBounds(display.displayID)
            let piece = bounds.intersection(rect)
            guard !piece.isNull, !piece.isEmpty else { continue }
            let local = piece.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let image = try await capture(display: display, sourceRect: local)
            // Destination in the bitmap: CG contexts are bottom-left origin, CG display space is top-left.
            let dest = CGRect(x: (piece.minX - rect.minX) * scale,
                              y: (rect.maxY - piece.maxY) * scale,
                              width: piece.width * scale,
                              height: piece.height * scale)
            ctx.draw(image, in: dest)
        }
        guard let image = ctx.makeImage() else { throw CaptureError.emptyRect }
        return image
    }

    // MARK: - ScreenCaptureKit

    private static func scDisplay(for displayID: CGDirectDisplayID) async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        return display
    }

    /// Captures `sourceRect` (display-local points, top-left origin) of a display, or the whole
    /// display when nil, at the display's native pixel density.
    private static func capture(display: SCDisplay, sourceRect: CGRect?) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let area = sourceRect ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)

        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = max(1, Int((area.width * scale).rounded()))
        config.height = max(1, Int((area.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures a single window by its CoreGraphics window number, without the windows covering it
    /// and without its shadow, at the display's native pixel density.
    static func captureWindow(_ windowID: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Converts a CoreGraphics global rect (top-left origin) to AppKit global space (bottom-left origin).
    static func appKitRect(fromCG rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
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
