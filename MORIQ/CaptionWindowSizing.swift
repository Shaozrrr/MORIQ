import AppKit

enum CaptionWindowSizing {
    static func laneHeight(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return ceil(NSLayoutManager().defaultLineHeight(for: font) * 2) + 4
    }
    static func requiredHeight(fontSize: CGFloat, mode: String) -> CGFloat {
        let original = laneHeight(fontSize: fontSize)
        let translation = laneHeight(fontSize: max(6, fontSize - 2))
        let lanes: CGFloat = mode == "original" ? original : mode == "zh" ? translation : max(original, translation) * 2 + 4
        return lanes + 22
    }
    static func nativeHeight(fontSize: CGFloat, mode: String) -> CGFloat {
        max(mode == "bilingual" ? 128 : 80, requiredHeight(fontSize: fontSize, mode: mode))
    }
    static func effectiveMode(mode: String, sameLanguage: Bool) -> String { sameLanguage ? "original" : mode }
    static func canFit(mode: String, availableContent: CGFloat) -> Bool {
        requiredHeight(fontSize: 6, mode: mode) <= availableContent
    }
    static func fittedFontSize(requested: CGFloat, mode: String, availableContent: CGFloat) -> CGFloat {
        var low: CGFloat = 6, high = max(6, requested)
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if requiredHeight(fontSize: mid, mode: mode) <= availableContent { low = mid } else { high = mid }
        }
        return min(requested, low)
    }
    static func windowHeight(fontSize: CGFloat, mode: String, review: CGFloat, available: CGFloat) -> CGFloat {
        min(max(0, available), 66 + nativeHeight(fontSize: fontSize, mode: mode) + review)
    }
}
