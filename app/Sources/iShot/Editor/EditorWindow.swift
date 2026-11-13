import AppKit
import VisionKit

/// Editor window: tool bar on top, scrollable canvas in the middle, action bar at the bottom.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<EditorWindowController> = []

    /// Called with the flattened image whenever it is saved/copied/pinned (used for "OCR Last Screenshot").
    var onExport: ((CGImage) -> Void)?

    private let state = ToolState()
    private let editorView: EditorView
    private let scrollView = NSScrollView()
    private var toolbar: NSStackView!
    private var actionBar: NSStackView!

    private var toolControl: NSSegmentedControl!
    private var colorWell: NSColorWell!
    private var widthPopup: NSPopUpButton!
    private var undoButton: NSButton!
    private var shareButton: NSButton!
    private var ocrButton: NSButton!
    private var copyTextButton: NSButton!
    private var hintLabel: NSTextField!
    private let ocrSpinner = NSProgressIndicator()

    // Text mode (Live Text over the image)
    private var textOverlay: ImageAnalysisOverlayView?
    private var analysis: ImageAnalysis?
    private var analysisTask: Task<Void, Never>?
    private static let defaultHint = "⌘S Save · ⌘C Copy · ⌘Z Undo · ⌫ Delete · Esc Cancel"

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
        editorView.onChange = { [weak self] in
            guard let self else { return }
            // Recognized text no longer matches the image once annotations change.
            if self.isInTextMode { self.endTextMode() }
            self.syncControls()
        }
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

        toolbar = NSStackView(views: [toolControl, separator(), swatchStack, colorWell, separator(),
                                          widthPopup, NSView(), undoButton, clearButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)

        // Canvas: images smaller than the window stay centered, with a soft shadow to show their edges.
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = editorView
        editorView.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        editorView.shadow = shadow
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
        ocrButton = makeButton("OCR", symbol: "text.viewfinder", action: #selector(runOCR))
        ocrButton.setButtonType(.pushOnPushOff)
        ocrButton.toolTip = "Make the text in the image selectable (Live Text)"
        copyTextButton = makeButton("Copy All Text", symbol: "doc.on.clipboard", action: #selector(copyAllText))
        copyTextButton.isHidden = true
        ocrSpinner.style = .spinning
        ocrSpinner.controlSize = .small
        ocrSpinner.isDisplayedWhenStopped = false
        shareButton = makeButton("Share", symbol: "square.and.arrow.up", action: #selector(share))
        let cancel = makeButton("Cancel", symbol: "xmark", action: #selector(cancelClicked))
        let hint = NSTextField(labelWithString: Self.defaultHint)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel = hint

        actionBar = NSStackView(views: [ocrSpinner, hint, NSView(), cancel, copyTextButton, ocrButton,
                                            shareButton, pin, copy, save])
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

    /// Sizes the window to the capture:
    /// - large shots fill the window, zoomed out if needed so the window stays within 85% of the screen;
    /// - small shots sit centered in a modest window, just wide enough for the tool and action bars.
    private func sizeWindowToFit(_ window: NSWindow) {
        let bars = [toolbar!, actionBar!]
        let chromeHeight = bars.map { $0.fittingSize.height }.reduce(0, +)
        let minWidth = max(600, ceil(bars.map { $0.fittingSize.width }.max() ?? 0))
        let margin: CGFloat = 24          // breathing room around small shots
        let minCanvasHeight: CGFloat = 220

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxCanvas = NSSize(width: visible.width * 0.85, height: visible.height * 0.85 - chromeHeight)

        let image = editorView.imageSize
        let zoom = min(1, maxCanvas.width / image.width, maxCanvas.height / image.height)
        let shown = NSSize(width: image.width * zoom, height: image.height * zoom)
        // Leave a margin only when the shot is not filling the screen-limited canvas.
        let pad = zoom < 1 ? 0 : margin * 2
        let canvas = NSSize(width: min(maxCanvas.width, max(minWidth, shown.width + pad)),
                            height: min(maxCanvas.height, max(minCanvasHeight, shown.height + pad)))

        window.setContentSize(NSSize(width: ceil(canvas.width), height: ceil(canvas.height + chromeHeight)))
        window.contentMinSize = NSSize(width: minWidth, height: chromeHeight + 160)
        scrollView.magnification = zoom
        window.center()
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
        endTextMode()
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

    // MARK: - Text mode (OCR)

    private var isInTextMode: Bool { textOverlay != nil || analysisTask != nil }

    @objc private func runOCR() {
        if isInTextMode { endTextMode() } else { startTextRecognition() }
    }

    /// Recognizes the text in the image and lays it over the canvas as Live Text: it can be
    /// selected with the mouse and copied with ⌘C, or copied at once with "Copy All Text".
    func startTextRecognition() {
        guard !isInTextMode, let image = editorView.renderedImage() else { return }
        ocrButton.state = .on
        ocrSpinner.startAnimation(nil)
        setHint("Recognizing text…")

        guard ImageAnalyzer.isSupported else {
            recognizeWithVision(image)
            return
        }
        analysisTask = Task { @MainActor [weak self] in
            do {
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration)
                guard let self, !Task.isCancelled else { return }
                self.analysisTask = nil
                self.showTextOverlay(analysis)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.analysisTask = nil
                self.recognizeWithVision(image)
            }
        }
    }

    private func showTextOverlay(_ analysis: ImageAnalysis) {
        ocrSpinner.stopAnimation(nil)
        guard analysis.hasResults(for: .text) else {
            endTextMode()
            setHint("No text found in the image.", flash: true)
            return
        }
        self.analysis = analysis

        let overlay = ImageAnalysisOverlayView(frame: editorView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.preferredInteractionTypes = .textSelection
        overlay.analysis = analysis
        overlay.selectableItemsHighlighted = true
        editorView.addSubview(overlay)
        textOverlay = overlay
        window?.makeFirstResponder(overlay)

        copyTextButton.isHidden = false
        let lines = analysis.transcript.split(whereSeparator: \.isNewline).count
        setHint("\(lines) line\(lines == 1 ? "" : "s") of text found — drag to select, ⌘C to copy · Esc to exit")
    }

    /// Fallback when Live Text is unavailable: plain Vision OCR, copied straight to the clipboard.
    private func recognizeWithVision(_ image: CGImage) {
        OCRService.recognize(from: image) { [weak self] result in
            guard let self else { return }
            self.endTextMode()
            switch result {
            case let .success(text) where text.isEmpty:
                self.setHint("No text found in the image.", flash: true)
            case let .success(text):
                Exporter.copyToClipboard(text)
                let lines = text.split(whereSeparator: \.isNewline).count
                self.setHint("Copied \(lines) line\(lines == 1 ? "" : "s") of text to the clipboard.", flash: true)
            case let .failure(error):
                self.showError(error)
            }
        }
    }

    func endTextMode() {
        analysisTask?.cancel()
        analysisTask = nil
        textOverlay?.removeFromSuperview()
        textOverlay = nil
        analysis = nil
        ocrSpinner.stopAnimation(nil)
        ocrButton.state = .off
        copyTextButton.isHidden = true
        setHint(Self.defaultHint)
        window?.makeFirstResponder(editorView)
    }

    @objc private func copyAllText() {
        guard let text = analysis?.transcript, !text.isEmpty else { return }
        Exporter.copyToClipboard(text)
        setHint("All text copied to the clipboard.", flash: true)
    }

    /// Copies the selected text, or everything when nothing is selected.
    private func copySelectedText() {
        if let overlay = textOverlay, overlay.hasActiveTextSelection, !overlay.selectedText.isEmpty {
            Exporter.copyToClipboard(overlay.selectedText)
            setHint("Selected text copied to the clipboard.", flash: true)
        } else {
            copyAllText()
        }
    }

    private var hintResetWork: DispatchWorkItem?

    /// Shows a status message; with `flash`, it reverts after a few seconds.
    private func setHint(_ text: String, flash: Bool = false) {
        hintResetWork?.cancel()
        hintLabel.stringValue = text
        hintLabel.textColor = text == Self.defaultHint ? .secondaryLabelColor : .labelColor
        guard flash else { return }
        let previous = textOverlay != nil
            ? "Drag to select text, ⌘C to copy · Esc to exit"
            : Self.defaultHint
        let work = DispatchWorkItem { [weak self] in self?.setHint(previous) }
        hintResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    @objc private func share() {
        guard let image = finalImage() else { return }
        Exporter.share(image, scale: editorView.scale, from: shareButton)
    }

    @objc private func cancelClicked() { window?.close() }

    private func cancel() {
        if isInTextMode {
            endTextMode()
        } else if editorView.isEditingText {
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
        if isInTextMode, key == "c" {
            copySelectedText()
            return true
        }
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
        analysisTask?.cancel()
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

/// Clip view that keeps a document smaller than the visible area centered instead of pinned to a corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = frame.minX - (rect.width - frame.width) / 2 }
        if rect.height > frame.height { rect.origin.y = frame.minY - (rect.height - frame.height) / 2 }
        return rect
    }
}
