import AppKit
import Vision

/// Text recognition on floating images via the Vision framework.
enum OCRService {
    /// Recognizes text in `image` (Korean + English) and copies it to the
    /// pasteboard. Returns false when nothing was recognized.
    @discardableResult
    static func copyText(from image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results, !results.isEmpty
        else { return false }
        let text = results
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }
}
