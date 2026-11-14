import AppKit
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case encodingFailed
    case writeFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "The image could not be encoded."
        case let .writeFailed(url, error):
            return "Could not write \(url.path): \(error.localizedDescription)"
        }
    }
}

/// Saving, clipboard and sharing.
enum Exporter {

    /// `prefix_YYYYMMDD_HHMMSS.<ext>`
    static func fileName(prefix: String, ext: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(formatter.string(from: date)).\(ext)"
    }

    /// Returns a URL in `directory` that does not exist yet, appending "-2", "-3", … if needed.
    static func uniqueURL(in directory: URL, fileName: String) -> URL {
        var url = directory.appendingPathComponent(fileName)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return url
    }

    static func encode(_ image: CGImage, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    /// Saves the image to the configured folder and returns the file URL.
    @discardableResult
    static func save(_ image: CGImage, settings: SettingsStore = .shared) throws -> URL {
        let format = settings.format
        guard let data = encode(image, format: format) else { throw ExportError.encodingFailed }
        let dir = settings.saveDirURL
        let url = uniqueURL(in: dir, fileName: fileName(prefix: settings.fileNamePrefix, ext: format.rawValue))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(url, error)
        }
        return url
    }

    /// Copies the image to the general pasteboard (PNG + TIFF).
    @discardableResult
    static func copyToClipboard(_ image: CGImage, scale: CGFloat) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image.nsImage(scale: scale)])
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Shows the system share picker anchored to a view.
    /// The image is written to a temporary PNG so receiving services get a real file.
    static func share(_ image: CGImage, scale: CGFloat, from view: NSView) {
        var items: [Any] = [image.nsImage(scale: scale)]
        if let data = encode(image, format: .png) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName(prefix: SettingsStore.shared.fileNamePrefix, ext: "png"))
            if (try? data.write(to: tmp, options: .atomic)) != nil { items = [tmp] }
        }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = ShareExtras.shared
        ShareExtras.shared.image = image
        ShareExtras.shared.scale = scale
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// Adds messaging apps the system share menu cannot offer on its own, each only when its desktop
/// app is installed:
/// - **WhatsApp** for Mac has no Share extension but opens images: it gets the screenshot file, and
///   the image is also put on the clipboard so ⌘V in a chat works too.
/// - **Mattermost** Desktop has no Share extension and does not open files: the image goes on the
///   clipboard, Mattermost comes to the front and a toast says to paste it with ⌘V.
/// - **Telegram** ships its own Share extension, so macOS lists it already; it is only moved up.
final class ShareExtras: NSObject, NSSharingServicePickerDelegate {
    static let shared = ShareExtras()

    private struct MessagingApp {
        enum Delivery { case openFile, pasteFromClipboard }
        let title: String
        let bundleIDs: [String]
        let delivery: Delivery
    }

    private static let apps: [MessagingApp] = [
        MessagingApp(title: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp"], delivery: .openFile),
        MessagingApp(title: "Mattermost", bundleIDs: ["Mattermost.Desktop"], delivery: .pasteFromClipboard)
    ]

    var image: CGImage?
    var scale: CGFloat = 1

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              sharingServicesForItems items: [Any],
                              proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        let fileURL = items.compactMap { $0 as? URL }.first(where: \.isFileURL)
        let custom = Self.apps.compactMap { service(for: $0, fileURL: fileURL) }
        let isTelegram: (NSSharingService) -> Bool = { $0.title.localizedCaseInsensitiveContains("Telegram") }
        return custom + proposedServices.filter(isTelegram) + proposedServices.filter { !isTelegram($0) }
    }

    private func service(for app: MessagingApp, fileURL: URL?) -> NSSharingService? {
        guard let appURL = app.bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { return nil }
        if app.delivery == .openFile && fileURL == nil { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let image = self.image, scale = self.scale
        return NSSharingService(title: app.title, image: icon, alternateImage: nil) {
            if let image { Exporter.copyToClipboard(image, scale: scale) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let completion: (NSRunningApplication?, Error?) -> Void = { _, error in
                DispatchQueue.main.async {
                    if let error {
                        let alert = NSAlert()
                        alert.messageText = "Could not open \(app.title)"
                        alert.informativeText = error.localizedDescription + "\n\nThe image is on the clipboard: paste it with ⌘V."
                        alert.runModal()
                    } else if app.delivery == .pasteFromClipboard {
                        Toast.show("Image copied — open a \(app.title) channel and press ⌘V")
                    }
                }
            }
            switch app.delivery {
            case .openFile:
                NSWorkspace.shared.open([fileURL!], withApplicationAt: appURL, configuration: configuration, completionHandler: completion)
            case .pasteFromClipboard:
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: completion)
            }
        }
    }
}

/// Small floating message that does not take focus and fades out by itself.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, duration: TimeInterval = 4) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.appearance = NSAppearance(named: .vibrantDark)
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14)
        ])

        let size = background.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
                if self.panel === panel { self.panel = nil }
            }
        }
    }
}
