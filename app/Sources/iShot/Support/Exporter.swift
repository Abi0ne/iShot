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

/// Adds services the system share menu cannot offer on its own.
///
/// WhatsApp for Mac ships no Share extension (only Intents and notification extensions), so macOS
/// never lists it in the share menu or in System Settings. It does open images, though: the
/// "WhatsApp" entry hands it the screenshot file and also puts the image on the clipboard, so ⌘V
/// in a chat works too.
final class ShareExtras: NSObject, NSSharingServicePickerDelegate {
    static let shared = ShareExtras()
    static let whatsAppBundleID = "net.whatsapp.WhatsApp"

    var image: CGImage?
    var scale: CGFloat = 1

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              sharingServicesForItems items: [Any],
                              proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        guard let whatsApp = whatsAppService(for: items) else { return proposedServices }
        return [whatsApp] + proposedServices
    }

    private func whatsAppService(for items: [Any]) -> NSSharingService? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.whatsAppBundleID),
              let fileURL = items.compactMap({ $0 as? URL }).first(where: \.isFileURL) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let image = self.image, scale = self.scale
        return NSSharingService(title: "WhatsApp", image: icon, alternateImage: nil) {
            if let image { Exporter.copyToClipboard(image, scale: scale) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration) { _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Could not open WhatsApp"
                    alert.informativeText = error.localizedDescription + "\n\nThe image is on the clipboard: paste it into a chat with ⌘V."
                    alert.runModal()
                }
            }
        }
    }
}
