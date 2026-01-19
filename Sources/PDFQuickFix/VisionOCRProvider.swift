import CoreGraphics
import Vision

final class VisionOCRProvider {
    private let languages: [String]

    init(languages: [String]) {
        self.languages = languages
    }

    func recognizeText(cgImage: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.minimumTextHeight = 0.01
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = [] // can be extended for domain terms
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }
}
