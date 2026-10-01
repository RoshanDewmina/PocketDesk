import Foundation
import CoreGraphics
import Vision
import CoreML

struct LegibilityCellScore: Equatable {
    let cell: LegibilityChart.Cell
    let recognized: String?
    /// Character error rate, 0 (perfect) to 1 (unread).
    let cer: Double
}

struct LegibilityResult: Equatable {
    let seed: UInt16
    let cells: [LegibilityCellScore]

    /// Mean CER in percent per point size, plus the coloured 11 pt tokens on their own.
    var cerBySize: [String: Double] {
        var out: [String: Double] = [:]
        for size in LegibilityChart.pointSizes {
            let scores = cells.filter { $0.cell.pointSize == size }
            if !scores.isEmpty { out["\(Int(size))pt"] = Self.percent(scores) }
        }
        let coloured = cells.filter { $0.cell.pointSize == 11 && $0.cell.colourway.isColoured }
        if !coloured.isEmpty { out["coloured11pt"] = Self.percent(coloured) }
        return out
    }

    private static func percent(_ scores: [LegibilityCellScore]) -> Double {
        (scores.map(\.cer).reduce(0, +) / Double(scores.count) * 1000).rounded() / 10
    }
}

/// Scores a chart image with Vision and assigns recognized words to cells by best edit distance.
/// The score is relative: run it on the Test Pad's own render too for the Vision ceiling.
enum LegibilityScore {
    /// A cell whose best match is worse than this counts as unread: two random 8-character tokens
    /// typically differ in 6–8 places, a read token with confusions in 1–3.
    static let unmatchedThreshold = 0.5

    /// Vision sometimes emits a look-alike from another script for a Latin glyph; those are not
    /// legibility errors, so they fold to ASCII before the edit distance.
    static let lookalikes: [Character: Character] = [
        "Ø": "0", "ø": "0", "О": "O", "о": "o", "Х": "X", "х": "x", "М": "M", "З": "3", "Е": "E", "е": "e",
        "А": "A", "а": "a", "В": "B", "С": "C", "с": "c", "Н": "H", "К": "K", "Т": "T", "Р": "P", "р": "p",
        "І": "I", "і": "i", "Ѕ": "S", "ѕ": "s", "Ι": "I", "Ο": "O", "Ζ": "Z", "Ν": "N", "Μ": "M", "Α": "A",
        "Β": "B", "Ε": "E", "Η": "H", "Κ": "K", "Τ": "T", "Υ": "Y", "Χ": "X", "‘": "'", "’": "'"
    ]

    static func normalize(_ word: String) -> String {
        String(word.map { lookalikes[$0] ?? $0 })
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[t.count]
    }

    static func assign(words: [String], to cells: [LegibilityChart.Cell],
                       unmatched: Double = unmatchedThreshold) -> [LegibilityCellScore] {
        cells.map { cell in
            let length = Double(max(1, cell.text.count))
            var best: (word: String, cer: Double)?
            for word in words {
                let cer = min(1, Double(levenshtein(word, cell.text)) / length)
                if best == nil || cer < best!.cer { best = (word, cer) }
            }
            if let best, best.cer <= unmatched {
                return LegibilityCellScore(cell: cell, recognized: best.word, cer: best.cer)
            }
            return LegibilityCellScore(cell: cell, recognized: nil, cer: 1)
        }
    }

    /// Words Vision reads in `image`: accurate level, no language correction (the tokens are not
    /// words), English script. Synchronous; call it off the main thread.
    static func recognizeWords(in image: CGImage, minimumTextHeight: Float = 0.004) throws -> [String] {
        func makeRequest() -> VNRecognizeTextRequest {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.automaticallyDetectsLanguage = false
            request.minimumTextHeight = minimumTextHeight
            return request
        }
        var request = makeRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            // An accelerator can fail to initialize even in a fresh process. Retry once with
            // a fresh request, using only CPU devices Vision advertises for this request.
            // Preserve the same OCR model and settings; failure still propagates to the caller.
            let originalError = error
            let fallback = makeRequest()
            let stages = try fallback.supportedComputeStageDevices
            var selectedCPU = false
            for (stage, devices) in stages {
                guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
                    throw originalError
                }
                fallback.setComputeDevice(cpu, for: stage)
                selectedCPU = true
            }
            guard selectedCPU else { throw originalError }
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([fallback])
            request = fallback
        }
        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) } }
    }

    static func score(image: CGImage, seed: UInt16) throws -> LegibilityResult {
        let words = try recognizeWords(in: image)
        return LegibilityResult(seed: seed, cells: assign(words: words, to: LegibilityChart.cells(seed: seed)))
    }
}
