import AppKit

/// Full-screen, semi-transparent overlay (one window per screen) used to drag-select a capture region.
/// The completion receives the selected rect in **AppKit global coordinates**, or nil if cancelled.
final class RegionOverlay {
    typealias Completion = (NSRect?) -> Void

    private var windows: [OverlayWindow] = []
    private var completion: Completion?
    private var escMonitor: Any?

    func begin(completion: @escaping Completion) {
        self.completion = completion
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] rect in self?.finish(with: rect) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Make the window under the cursor key so it receives Esc.
        let mouse = NSEvent.mouseLocation
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.finish(with: nil)
                return nil
            }
            return event
        }
        NSCursor.crosshair.push()
    }

    private func finish(with rect: NSRect?) {
        guard let completion else { return }
        self.completion = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        completion(rect)
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
    var onFinish: ((NSRect?) -> Void)?

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

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        current = NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX),
                          y: min(max(p.y, bounds.minY), bounds.maxY))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= 3, selection.height >= 3, let window else {
            // A plain click (no drag) cancels nothing: reset and let the user try again.
            start = nil
            current = nil
            needsDisplay = true
            return
        }
        let inWindow = convert(selection, to: nil)
        onFinish?(window.convertToScreen(inWindow))
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

        guard let selection else {
            drawHint()
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

    private func drawHint() {
        let text = "Drag to select an area — Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let bg = NSRect(x: bounds.midX - size.width / 2 - 12, y: bounds.midY - size.height / 2 - 6,
                        width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: bg.minX + 12, y: bg.minY + 6), withAttributes: attrs)
    }
}
