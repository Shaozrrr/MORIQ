import Foundation
import Vision
import CoreGraphics

/// Bounding boxes use Vision's normalized bottom-left coordinate space.
struct OCRBlock {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}
enum ScreenshotTranslationLanguage {
    /// OCR is configured for simplified Chinese and English. Supplying an
    /// explicit source avoids the system language-picker for short strings.
    static func source(for text: String, target: String) -> String? {
        let scalars = text.unicodeScalars
        let hasHan = scalars.contains { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
        let hasLatin = scalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        if target == "zh-Hans" && hasLatin { return "en" }
        if target == "en" && hasHan { return "zh-Hans" }
        return nil
    }
}
struct OCREngine {
    func recognizeBlocks(_ image: CGImage) throws -> [OCRBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRBlock(text: candidate.string, confidence: candidate.confidence, boundingBox: observation.boundingBox)
        }
    }
    func recognize(_ image: CGImage) throws -> String {
        try recognizeBlocks(image).map(\.text).joined(separator: "\n")
    }
}
