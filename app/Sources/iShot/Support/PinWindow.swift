import AppKit

/// Borderless, always-on-top window that "pins" an image to the desktop.
/// Drag to move, scroll to zoom, double-click / Esc / close button to dismiss.
final class PinWindow: NSPanel {
    /// Keeps pinned windows alive until they are closed.
    private static var openPins: Set<PinWindow> = []

    static func pin(_ image: CGImage, scale: CGFloat, near origin: NSPoint? = nil) {
        let window = PinWindow(image: image.nsImage(scale: scale))
        if let origin {
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
        openPins.insert(window)
        window.orderFrontRegardless()
        window.makeKey()
    }

    private init(image: NSImage) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var size = image.size
        let maxSize = NSSize(width: screen.width * 0.8, height: screen.height * 0.8)
        let fit = min(1, maxSize.width / size.width, maxSize.height / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        contentView = PinContentView(image: image, onClose: { [weak self] in self?.close() })
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        PinWindow.openPins.remove(self)
    }
}

private final class PinContentView: NSView {
    private let image: NSImage
    private let onClose: () -> Void
    private let closeButton: NSButton
    private var tracking: NSTrackingArea?

    init(image: NSImage, onClose: @escaping () -> Void) {
        self.image = image
        self.onClose = onClose
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") ?? NSImage(),
                               target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor

        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        toolTip = "Drag to move · Scroll to zoom · Double-click or Esc to close"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose() } else { super.mouseDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.05 : (event.scrollingDeltaY < 0 ? 0.95 : 1)
        guard factor != 1 else { return }
        var frame = window.frame
        let newWidth = max(60, frame.width * factor)
        let newHeight = newWidth * (frame.height / frame.width)
        frame.origin.x += (frame.width - newWidth) / 2
        frame.origin.y += (frame.height - newHeight) / 2
        frame.size = NSSize(width: newWidth, height: newHeight)
        window.setFrame(frame, display: true)
    }

    @objc private func closeClicked() { onClose() }
}
