import AppKit
import Vision

enum OCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "The image could not be read for text recognition."
        }
    }
}

/// On-device text recognition using Vision.
enum OCRService {

    /// Recognizes text in a CGImage. Blocking: call from a background queue.
    static func recognize(from image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        // Vision returns normalized bounding boxes with a bottom-left origin: sort top-to-bottom,
        // then left-to-right, so lines come out in reading order.
        let sorted = observations.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func recognize(from image: NSImage) throws -> String {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.invalidImage
        }
        return try recognize(from: cg)
    }

    /// Async convenience: runs recognition off the main thread and delivers the result on main.
    static func recognize(from image: CGImage, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try recognize(from: image) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Small window that shows OCR output with a Copy button.
final class OCRResultWindow: NSWindowController, NSWindowDelegate {
    private static var open: Set<OCRResultWindow> = []

    static func show(text: String) {
        let controller = OCRResultWindow(text: text)
        open.insert(controller)
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let text: String

    private init(text: String) {
        self.text = text
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Recognized Text"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI(in window: NSWindow) {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.string = text.isEmpty ? "" : text
        textView.font = .systemFont(ofSize: 13)
        textView.isEditable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: text.isEmpty ? "No text found." : "\(text.count) characters")
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copy.keyEquivalent = "\r"
        copy.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(scroll)
        content.addSubview(status)
        content.addSubview(copy)
        content.addSubview(close)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -12),
            copy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: copy.centerYAnchor)
        ])
        self.textView = textView
    }

    private weak var textView: NSTextView?

    @objc private func copyText() {
        Exporter.copyToClipboard(textView?.string ?? text)
        window?.close()
    }

    @objc private func closeWindow() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        OCRResultWindow.open.remove(self)
    }
}
