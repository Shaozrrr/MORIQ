import Foundation

func range(_ start: Int64, _ end: Int64) -> CaptionSampleRange { .init(start: start, end: end) }
func word(_ start: Int64, _ end: Int64) -> CaptionTimedWord { .init(text: "word", range: range(start, end)) }
func turn(_ id: String, _ start: Int64, _ end: Int64) -> CaptionSpeakerTurn { .init(speakerID: id, range: range(start, end)) }
func check(_ word: CaptionTimedWord, _ turns: [CaptionSpeakerTurn], _ expected: String?) {
    let result = CaptionSpeakerAlignment.align(words: [word], turns: turns, minimumCoverage: 0.7, maximumCompetition: 0.2)
    precondition(result.count == 1 && result[0].speakerID == expected)
}
check(word(100, 200), [turn("A", 100, 200)], "A")
check(word(100, 200), [turn("A", 100, 180), turn("B", 180, 200)], nil)
check(word(100, 200), [turn("A", 100, 180), turn("B", 170, 200)], nil)
check(word(100, 200), [turn("A", 100, 150), turn("A", 140, 180)], "A")
check(word(100, 200), [turn("A", 100, 160), turn("A", 100, 160)], nil)
check(word(100, 200), [turn("", 100, 200)], nil)
check(word(200, 100), [turn("A", 100, 200)], nil)
precondition(CaptionSpeakerAlignment.align(words: [word(100, 200)], turns: [turn("A", 100, 200)], minimumCoverage: .nan, maximumCompetition: 0.2)[0].speakerID == nil)
print("PASS timestamp alignment handles overlap, uncertainty and duplicate intervals")
