import AppKit

/// Editor window: tool bar on top, scrollable canvas in the middle, action bar at the bottom.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<EditorWindowController> = []

    /// Called with the flattened image whenever it is saved/copied/pinned (used for "OCR Last Screenshot").
    var onExport: ((CGImage) -> Void)?

    private let state = ToolState()
    private let editorView: EditorView
    private let scrollView = NSScrollView()

    private var toolControl: NSSegmentedControl!
    private var colorWell: NSColorWell!
    private var widthPopup: NSPopUpButton!
    private var undoButton: NSButton!
    private var shareButton: NSButton!

    private static let swatches: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                              .systemBlue, .systemPurple, .black, .white]
    private static let widths: [CGFloat] = [1, 2, 3, 5, 8, 12]

    @discardableResult
    static func show(image: CGImage, scale: CGFloat, onExport: ((CGImage) -> Void)? = nil) -> EditorWindowController {
        let controller = EditorWindowController(image: image, scale: scale)
        controller.onExport = onExport
        open.insert(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.editorView)
        return controller
    }

    private init(image: CGImage, scale: CGFloat) {
        editorView = EditorView(image: image, scale: scale, state: state)

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
        window.title = "iShot — \(image.width) × \(image.height)"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        window.cancelHandler = { [weak self] in self?.cancel() }

        buildUI(in: window)
        sizeWindowToFit(window)
        syncControls()
        state.onChange = { [weak self] in self?.syncControls() }
        editorView.onChange = { [weak self] in self?.syncControls() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - UI

    private func buildUI(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        // Tool bar
        let symbols = Tool.allCases.map { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.title) ?? NSImage() }
        toolControl = NSSegmentedControl(images: symbols, trackingMode: .selectOne, target: self, action: #selector(toolChanged))
        for (i, tool) in Tool.allCases.enumerated() {
            toolControl.setToolTip(tool.title, forSegment: i)
        }

        let swatchStack = NSStackView()
        swatchStack.spacing = 4
        for (i, color) in Self.swatches.enumerated() {
            let button = SwatchButton(color: color)
            button.tag = i
            button.target = self
            button.action = #selector(swatchClicked(_:))
            swatchStack.addArrangedSubview(button)
        }

        colorWell = NSColorWell(style: .minimal)
        colorWell.color = state.color
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged)
        colorWell.toolTip = "Custom color"

        widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for width in Self.widths { widthPopup.addItem(withTitle: "\(Int(width)) pt") }
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged)
        widthPopup.toolTip = "Line width / text size"

        undoButton = makeButton("Undo", symbol: "arrow.uturn.backward", action: #selector(undo))
        let clearButton = makeButton("Clear", symbol: "trash", action: #selector(clearAll))

        let toolbar = NSStackView(views: [toolControl, separator(), swatchStack, colorWell, separator(),
                                          widthPopup, NSView(), undoButton, clearButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)

        // Canvas
        scrollView.documentView = editorView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder

        // Action bar
        let save = makeButton("Save", symbol: "square.and.arrow.down", action: #selector(save))
        save.keyEquivalent = "\r"
        let copy = makeButton("Copy", symbol: "doc.on.doc", action: #selector(copyImage))
        let pin = makeButton("Pin", symbol: "pin", action: #selector(pin))
        let ocr = makeButton("OCR", symbol: "text.viewfinder", action: #selector(runOCR))
        shareButton = makeButton("Share", symbol: "square.and.arrow.up", action: #selector(share))
        let cancel = makeButton("Cancel", symbol: "xmark", action: #selector(cancelClicked))
        let hint = NSTextField(labelWithString: "⌘S Save · ⌘C Copy · ⌘Z Undo · ⌫ Delete · Esc Cancel")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let actionBar = NSStackView(views: [hint, NSView(), cancel, ocr, shareButton, pin, copy, save])
        actionBar.orientation = .horizontal
        actionBar.spacing = 8
        actionBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        for v in [toolbar, scrollView, actionBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            actionBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        return button
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }

    /// Fits the window to the image (up to 85% of the screen), zooming out if needed.
    private func sizeWindowToFit(_ window: NSWindow) {
        let chromeHeight: CGFloat = 100
        let minWidth: CGFloat = 860
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxContent = NSSize(width: visible.width * 0.85, height: visible.height * 0.85 - chromeHeight)
        let image = editorView.imageSize
        let zoom = min(1, maxContent.width / image.width, maxContent.height / image.height)
        let contentSize = NSSize(width: max(minWidth, image.width * zoom + 2),
                                 height: max(240, image.height * zoom + 2) + chromeHeight)
        window.setContentSize(contentSize)
        window.contentMinSize = NSSize(width: minWidth, height: 300)
        window.center()
        scrollView.magnification = zoom
    }

    private func syncControls() {
        if let index = Tool.allCases.firstIndex(of: state.tool) { toolControl.selectedSegment = index }
        colorWell.color = state.color
        if let index = Self.widths.firstIndex(of: state.lineWidth) { widthPopup.selectItem(at: index) }
        undoButton.isEnabled = editorView.canUndo
        editorView.needsDisplay = true
    }

    // MARK: - Tool bar actions

    @objc private func toolChanged() {
        editorView.commitTextEditing()
        state.tool = Tool.allCases[toolControl.selectedSegment]
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        state.color = Self.swatches[sender.tag]
        editorView.applyStyleToSelection()
    }

    @objc private func colorWellChanged() {
        state.color = colorWell.color
        editorView.applyStyleToSelection()
    }

    @objc private func widthChanged() {
        state.lineWidth = Self.widths[widthPopup.indexOfSelectedItem]
        editorView.applyStyleToSelection()
    }

    @objc private func undo() { editorView.undo() }
    @objc private func clearAll() { editorView.clear() }

    // MARK: - Export actions

    private func finalImage() -> CGImage? {
        guard let image = editorView.renderedImage() else {
            showError(ExportError.encodingFailed)
            return nil
        }
        onExport?(image)
        return image
    }

    @objc private func save() {
        guard let image = finalImage() else { return }
        do {
            let url = try Exporter.save(image)
            NSLog("iShot: saved \(url.path)")
            window?.close()
        } catch {
            showError(error)
        }
    }

    @objc private func copyImage() {
        guard let image = finalImage() else { return }
        Exporter.copyToClipboard(image, scale: editorView.scale)
        window?.close()
    }

    @objc private func pin() {
        guard let image = finalImage() else { return }
        let origin = window?.frame.origin
        window?.close()
        PinWindow.pin(image, scale: editorView.scale, near: origin)
    }

    @objc private func runOCR() {
        guard let image = editorView.renderedImage() else { return }
        OCRService.recognize(from: image) { [weak self] result in
            switch result {
            case let .success(text): OCRResultWindow.show(text: text)
            case let .failure(error): self?.showError(error)
            }
        }
    }

    @objc private func share() {
        guard let image = finalImage() else { return }
        Exporter.share(image, scale: editorView.scale, from: shareButton)
    }

    @objc private func cancelClicked() { window?.close() }

    private func cancel() {
        if editorView.isEditingText {
            editorView.commitTextEditing()
        } else {
            window?.close()
        }
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    /// Command-key shortcuts. Ignored while a text annotation is being edited so the field editor
    /// keeps standard copy/paste behavior.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard !editorView.isEditingText else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "s": save()
        case "c": copyImage()
        case "z": undo()
        case "p": pin()
        case "w": window?.close()
        case "0": scrollView.magnification = 1
        case "+", "=": scrollView.magnification *= 1.25
        case "-": scrollView.magnification /= 1.25
        default: return false
        }
        return true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        editorView.commitTextEditing()
        EditorWindowController.open.remove(self)
    }
}

/// Window subclass that forwards Esc and command-key shortcuts to the controller.
private final class EditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    var cancelHandler: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}

/// Small round color swatch.
private final class SwatchButton: NSButton {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        isBordered = false
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        color.setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }
}
