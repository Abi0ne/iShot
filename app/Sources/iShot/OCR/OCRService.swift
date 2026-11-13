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
