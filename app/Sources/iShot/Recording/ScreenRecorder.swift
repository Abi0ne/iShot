import AppKit
import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case permissionDenied
    case noDisplay
    case alreadyRecording
    case notRecording
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "iShot does not have the Screen Recording permission. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch iShot."
        case .noDisplay:
            return "No display available to record."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No recording is in progress."
        case let .writerFailed(message):
            return "The video file could not be written: \(message)"
        }
    }
}

/// Records the display under the mouse cursor to a `.mov` file using ScreenCaptureKit + AVAssetWriter.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?
    private let sampleQueue = DispatchQueue(label: "iShot.recorder.samples")

    /// Called on the main queue if the stream stops unexpectedly.
    var onUnexpectedStop: ((Error) -> Void)?

    private(set) var isRecording = false

    /// Starts recording. Throws `RecorderError.permissionDenied` when access is missing.
    func start(saveDirectory: URL, prefix: String) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.permissionDenied
        }

        let targetID = await MainActor.run { () -> CGDirectDisplayID? in
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            return screen?.displayID
        }
        guard let display = content.displays.first(where: { $0.displayID == targetID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }

        // Exclude iShot's own windows (menus, pins) from the recording.
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = CGFloat(filter.pointPixelScale)
        let width = Int(CGFloat(display.width) * scale) & ~1   // H.264 wants even dimensions
        let height = Int(CGFloat(display.height) * scale) & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6

        // Writer
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let url = Exporter.uniqueURL(in: saveDirectory, fileName: Exporter.fileName(prefix: prefix, ext: "mov"))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 4),
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        sampleQueue.sync {
            self.writer = writer
            self.videoInput = input
            self.sessionStarted = false
        }
        self.outputURL = url
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            cleanup()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            // A TCC denial surfaces here on first launch.
            if CGPreflightScreenCaptureAccess() == false { throw RecorderError.permissionDenied }
            throw error
        }
        isRecording = true
    }

    /// Stops recording and returns the URL of the finished `.mov`.
    func stop() async throws -> URL {
        guard isRecording, let stream, let url = outputURL else { throw RecorderError.notRecording }
        isRecording = false
        try? await stream.stopCapture()

        let (writer, input, started): (AVAssetWriter?, AVAssetWriterInput?, Bool) = sampleQueue.sync {
            (self.writer, self.videoInput, self.sessionStarted)
        }
        cleanup()

        guard let writer, let input else { throw RecorderError.writerFailed("writer missing") }
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.writerFailed("no frames were captured")
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return url
    }

    private func cleanup() {
        sampleQueue.sync {
            self.writer = nil
            self.videoInput = nil
            self.sessionStarted = false
        }
        stream = nil
        outputURL = nil
    }

    // MARK: SCStreamOutput (runs on sampleQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let writer, let videoInput else { return }

        // Skip idle/blank frames: only "complete" frames carry new pixels.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard isRecording else { return }
        isRecording = false
        let (writer, _) = sampleQueue.sync { (self.writer, self.videoInput) }
        writer?.cancelWriting()
        cleanup()
        DispatchQueue.main.async { self.onUnexpectedStop?(error) }
    }
}
