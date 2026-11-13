import Foundation

// All positions are absolute sample indices on the same 16 kHz mono timeline.
// These value types do not capture audio, assign identities, or run inference.
struct CaptionSampleRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    var isValid: Bool { start >= 0 && end > start }
}

struct CaptionTimedWord: Equatable, Sendable {
    let text: String
    let range: CaptionSampleRange
}

struct CaptionSpeakerTurn: Equatable, Sendable {
    let speakerID: String
    let range: CaptionSampleRange
}

struct CaptionAlignedWord: Equatable, Sendable {
    let word: CaptionTimedWord
    // nil means insufficient coverage or competing speakers, never a guess.
    let speakerID: String?
}

enum CaptionSpeakerAlignment {
    // Thresholds must be selected from a measured dataset for the chosen
    // engine; there are deliberately no production defaults. The caller must
    // supply one shared audio clock and real inferred turns.
    static func align(words: [CaptionTimedWord], turns: [CaptionSpeakerTurn], minimumCoverage: Double, maximumCompetition: Double) -> [CaptionAlignedWord] {
        words.map { word in
            guard word.range.isValid, minimumCoverage.isFinite, maximumCompetition.isFinite,
                  (0...1).contains(minimumCoverage), (0...1).contains(maximumCompetition),
                  minimumCoverage > maximumCompetition else { return CaptionAlignedWord(word: word, speakerID: nil) }
            let duration = Double(word.range.end - word.range.start)
            var intervals: [String: [(Int64, Int64)]] = [:]
            for turn in turns where turn.range.isValid && !turn.speakerID.isEmpty {
                let lo = max(word.range.start, turn.range.start), hi = min(word.range.end, turn.range.end)
                if hi > lo { intervals[turn.speakerID, default: []].append((lo, hi)) }
            }
            let coverage: [(String, Double)] = intervals.map { id, ranges in
                let sorted = ranges.sorted { $0.0 < $1.0 }
                var sum: Int64 = 0, lo: Int64 = 0, hi: Int64 = 0
                for range in sorted {
                    if hi <= lo { lo = range.0; hi = range.1 }
                    else if range.0 <= hi { hi = max(hi, range.1) }
                    else { sum += hi - lo; lo = range.0; hi = range.1 }
                }
                sum += hi - lo
                return (id, Double(sum) / duration)
            }.sorted { $0.1 > $1.1 }
            let selected: String?
            if let first = coverage.first, first.1 >= minimumCoverage,
               coverage.dropFirst().allSatisfy({ $0.1 < maximumCompetition }) { selected = first.0 }
            else { selected = nil }
            return CaptionAlignedWord(word: word, speakerID: selected)
        }
    }
}
