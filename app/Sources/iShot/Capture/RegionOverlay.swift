import AppKit

/// A window that the overlay can snap to.
struct WindowTarget: Equatable {
    let id: CGWindowID
    /// Frame in AppKit global coordinates.
    let frame: NSRect
}

/// Full-screen, semi-transparent overlay (one window per screen) used to pick what to capture:
/// - the window in front is highlighted right away ("snapped"); moving the pointer over another
///   window snaps to that one. A click (or ↩) captures the highlighted window;
/// - click-and-drag selects a custom area, as before.
/// The completion receives the choice, or nil if cancelled.
final class RegionOverlay {
    enum Result {
        /// A dragged area in AppKit global coordinates.
        case region(NSRect)
        case window(WindowTarget)
    }
    typealias Completion = (Result?) -> Void

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var completion: Completion?
    private var keyMonitor: Any?

    /// On-screen windows of other apps, front to back.
    private var candidates: [WindowTarget] = []
    /// The window currently snapped to.
    fileprivate private(set) var highlighted: WindowTarget? {
        didSet { if highlighted != oldValue { views.forEach { $0.needsDisplay = true } } }
    }
    /// True while any screen is dragging a custom area (hides the window highlight).
    fileprivate var isDragging = false {
        didSet { views.forEach { $0.needsDisplay = true } }
    }

    func begin(completion: @escaping Completion) {
        self.completion = completion
        // Read the window list before our overlay covers the screen: the first entry is the window in front.
        candidates = Self.visibleWindows()
        highlighted = candidates.first

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), overlay: self)
            view.onFinish = { [weak self] result in self?.finish(with: result) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Make the window under the cursor key so it receives Esc.
        let mouse = NSEvent.mouseLocation
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // Esc
                self.finish(with: nil)
                return nil
            case 36, 76: // Return / Enter: capture the highlighted window
                if let target = self.highlighted { self.finish(with: .window(target)) }
                return nil
            default:
                return event
            }
        }
        NSCursor.crosshair.push()
    }

    /// Snaps to the topmost window under a point (AppKit global coordinates); over the desktop it
    /// falls back to the window in front.
    fileprivate func pointerMoved(to point: NSPoint) {
        guard !isDragging else { return }
        highlighted = candidates.first { $0.frame.contains(point) } ?? candidates.first
    }

    private func finish(with result: Result?) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        completion(result)
    }

    /// Normal app windows (layer 0) of other processes that are on screen, front to back.
    private static func visibleWindows() -> [WindowTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            return WindowTarget(id: id, frame: ScreenCapture.appKitRect(fromCG: bounds))
        }
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the dimmed backdrop, the clear selection and a live "W × H" label.
/// The view uses AppKit's default bottom-left origin; conversion to global coordinates
/// goes through `window.convertToScreen`.
private final class OverlayView: NSView {
    var onFinish: ((RegionOverlay.Result?) -> Void)?
    private unowned let overlay: RegionOverlay

    init(frame: NSRect, overlay: RegionOverlay) {
        self.overlay = overlay
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var start: NSPoint?
    private var current: NSPoint?

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func globalPoint(_ event: NSEvent) -> NSPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        overlay.pointerMoved(to: globalPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        overlay.pointerMoved(to: globalPoint(event))
        start = convert(event.locationInWindow, from: nil)
        current = start
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        current = NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX),
                          y: min(max(p.y, bounds.minY), bounds.maxY))
        // Switch from "snap to window" to a custom area once the pointer really moves.
        if let selection, selection.width >= 3 || selection.height >= 3 { overlay.isDragging = true }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            current = nil
        }
        if overlay.isDragging, let selection, selection.width >= 3, selection.height >= 3, let window {
            let inWindow = convert(selection, to: nil)
            onFinish?(.region(window.convertToScreen(inWindow)))
            return
        }
        // A plain click captures the snapped window (with no windows at all, just try again).
        overlay.isDragging = false
        if let target = overlay.highlighted {
            onFinish?(.window(target))
        } else {
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard overlay.isDragging, let selection else {
            drawWindowHighlight()
            return
        }

        // Punch a clear hole for the selection.
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        border.stroke()

        drawSizeLabel(for: selection)
    }

    private func drawSizeLabel(for rect: NSRect) {
        let scale = window?.backingScaleFactor ?? 1
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height + 4 > bounds.maxY { origin.y = rect.maxY - size.height - 10 }
        origin.x = min(origin.x, bounds.maxX - size.width - 10)
        let bg = NSRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: bg.minX + 5, y: bg.minY + 2), withAttributes: attrs)
    }

    /// Clears and outlines the snapped window (the part of it on this screen).
    private func drawWindowHighlight() {
        guard let target = overlay.highlighted, let window else {
            drawHint("Drag to select an area — Esc to cancel")
            return
        }
        let local = target.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        guard local.intersects(bounds) else { return }

        NSColor.clear.setFill()
        local.fill(using: .copy)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        local.fill()

        let border = NSBezierPath(rect: local.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        drawSizeLabel(for: local.intersection(bounds))
        drawHint("Click to capture this window — drag to select an area — Esc to cancel",
                 in: local.intersection(bounds))
    }

    private func drawHint(_ text: String, in area: NSRect? = nil) {
        let area = area ?? bounds
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let bg = NSRect(x: area.midX - size.width / 2 - 12, y: area.midY - size.height / 2 - 6,
                        width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: bg.minX + 12, y: bg.minY + 6), withAttributes: attrs)
    }
}
