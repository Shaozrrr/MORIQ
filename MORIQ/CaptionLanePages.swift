import Foundation
import AppKit
import CoreText

/// One independently ordered stream. The caller validates transport epochs and
/// offsets; no source/translation sentence association is implied.
struct CaptionLanePages {
    private(set) var confirmed = ""
    private(set) var provisional = ""
    private(set) var revision: UInt64?
    private(set) var followsLatest = true
    private(set) var pageCapacity: Int
    private struct Layout: Equatable { let width: CGFloat; let fontSize: CGFloat; let lines: Int }
    private var layout: Layout?
    private var completePages: [String] = []
    private var pendingConfirmed = ""
    private var tailPages: [String] = []
    private var selectedIndex = 0

    init(pageCapacity: Int = 90) {
        precondition(pageCapacity >= 8)
        self.pageCapacity = pageCapacity
    }

    /// Snapshot helper for callers with cumulative text. Runtime transport uses
    /// append(), so it does not reconstruct and repaginate confirmed history on
    /// every provisional update.
    @discardableResult
    mutating func apply(confirmed newConfirmed: String, provisional newProvisional: String, revision newRevision: UInt64) -> Bool {
        guard newConfirmed.hasPrefix(confirmed) else { return false }
        let delta = String(newConfirmed.dropFirst(confirmed.count))
        return append(confirmedDelta: delta, provisional: newProvisional, revision: newRevision)
    }

    @discardableResult
    mutating func append(confirmedDelta: String, provisional newProvisional: String, revision newRevision: UInt64) -> Bool {
        guard revision.map({ newRevision > $0 }) ?? true else { return false }
        confirmed.append(contentsOf: confirmedDelta)
        pendingConfirmed.append(contentsOf: confirmedDelta)
        provisional = newProvisional
        revision = newRevision
        reflowTail()
        if followsLatest { selectedIndex = max(0, pageCount - 1) }
        else { selectedIndex = min(selectedIndex, max(0, pageCount - 1)) }
        return true
    }

    /// Full confirmed text remains available for history/copy. Provisional is
    /// intentionally never committed merely because a session is interrupted.
    var text: String { confirmed + provisional }
    var pages: [String] { completePages + tailPages }
    var visible: String {
        guard pageCount > 0 else { return "" }
        let index = followsLatest ? pageCount - 1 : min(selectedIndex, pageCount - 1)
        return index < completePages.count ? completePages[index] : tailPages[index - completePages.count]
    }
    var hasPrevious: Bool { pageCount > 0 && (followsLatest ? pageCount - 1 : selectedIndex) > 0 }
    var hasNext: Bool { pageCount > 0 && !followsLatest && selectedIndex + 1 < pageCount }
    var pageCount: Int { completePages.count + tailPages.count }
    var visiblePageIndex: Int { followsLatest ? max(0, pageCount - 1) : min(selectedIndex, max(0, pageCount - 1)) }
    func page(at index: Int) -> String? {
        guard index >= 0 && index < pageCount else { return nil }
        return index < completePages.count ? completePages[index] : tailPages[index - completePages.count]
    }

    mutating func previous() {
        guard pageCount > 0 else { return }
        let index = followsLatest ? pageCount - 1 : selectedIndex
        guard index > 0 else { return }
        selectedIndex = index - 1; followsLatest = false
    }
    mutating func selectPage(_ index: Int) {
        guard pageCount > 0 else { return }
        selectedIndex = max(0, min(index, pageCount - 1))
        followsLatest = false
    }
    mutating func next() {
        guard hasNext else { return }
        selectedIndex += 1; followsLatest = selectedIndex == pageCount - 1
    }
    mutating func resumeFollowing() { followsLatest = true; selectedIndex = max(0, pageCount - 1) }
    mutating func discardProvisional() {
        guard !provisional.isEmpty else { return }
        provisional = ""; reflowTail()
        selectedIndex = followsLatest ? max(0, pageCount - 1) : min(selectedIndex, max(0, pageCount - 1))
    }
    mutating func resize(pageCapacity: Int) {
        precondition(pageCapacity >= 8)
        guard self.pageCapacity != pageCapacity || layout != nil else { return }
        layout = nil
        rebuild(pageCapacity: pageCapacity)
    }
    /// Use the same system font/width as the real lane view. Reflow happens
    /// only on geometry changes, never on every incoming speech token.
    mutating func resize(width: CGFloat, fontSize: CGFloat, lines: Int = 2) {
        guard width.isFinite, fontSize.isFinite, width >= 20, fontSize >= 8, (1...4).contains(lines) else { return }
        let updated = Layout(width: (width * 2).rounded() / 2, fontSize: fontSize, lines: lines)
        guard updated != layout else { return }
        layout = updated
        rebuild(pageCapacity: pageCapacity)
    }
    private mutating func rebuild(pageCapacity: Int) {
        let oldPages = pages
        let oldIndex = followsLatest ? max(0, oldPages.count - 1) : min(selectedIndex, max(0, oldPages.count - 1))
        let anchor = oldPages.prefix(oldIndex).reduce(0) { $0 + $1.count }
        self.pageCapacity = pageCapacity
        completePages.removeAll(); pendingConfirmed = confirmed; reflowTail()
        if followsLatest { selectedIndex = max(0, pageCount - 1) }
        else {
            var offset = 0; selectedIndex = 0
            for (index, page) in pages.enumerated() {
                if offset > anchor { break }; selectedIndex = index; offset += page.count
            }
        }
    }
    mutating func reset() {
        confirmed = ""; provisional = ""; revision = nil; followsLatest = true
        completePages.removeAll(); pendingConfirmed = ""; tailPages.removeAll(); selectedIndex = 0
    }

    /// Finished pages are frozen only where every character is confirmed. A
    /// provisional retraction can therefore touch only the small live tail.
    private mutating func reflowTail() {
        let candidate = paginate(pendingConfirmed + provisional)
        let confirmedCount = pendingConfirmed.count
        var consumed = 0
        for page in candidate.dropLast() {
            guard consumed + page.count <= confirmedCount else { break }
            completePages.append(page); consumed += page.count
        }
        if consumed > 0 { pendingConfirmed = String(pendingConfirmed.dropFirst(consumed)) }
        tailPages = paginate(pendingConfirmed + provisional)
    }

    private func paginate(_ value: String) -> [String] {
        guard let layout else { return Self.paginate(value, capacity: pageCapacity) }
        return Self.paginateMeasured(value, width: layout.width, fontSize: layout.fontSize, lines: layout.lines)
    }

    /// Core Text wraps with the actual font and width, retaining each original
    /// character; text never disappears merely because its page advances.
    private static func paginateMeasured(_ value: String, width: CGFloat, fontSize: CGFloat, lines: Int) -> [String] {
        guard !value.isEmpty else { return [] }
        let attributed = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
        let chars = Array(value); var offsets = [0]; offsets.reserveCapacity(chars.count + 1)
        for char in chars { offsets.append(offsets.last! + String(char).utf16.count) }
        func safeIndex(_ proposed: Int, after lower: Int) -> Int {
            var lo = lower + 1, hi = chars.count
            while lo < hi { let mid = (lo + hi + 1) / 2; if offsets[mid] <= proposed { lo = mid } else { hi = mid - 1 } }
            return max(lower + 1, lo)
        }
        var result: [String] = [], start = 0
        while start < chars.count {
            var end = start
            for _ in 0..<lines {
                guard end < chars.count else { break }
                let proposed = offsets[end] + CTTypesetterSuggestLineBreak(typesetter, offsets[end], Double(width))
                end = safeIndex(proposed, after: end)
            }
            // On overflow prefer a nearby sentence boundary, but never throw
            // away half of an otherwise useful line just to find punctuation.
            if end < chars.count {
                let minimum = start + max(1, (end - start) * 3 / 4)
                if minimum < end {
                    var punctuation: Int?
                    for index in minimum..<end {
                        let c = chars[index]
                        if "!?。！？；;\n".contains(c) { punctuation = index + 1 }
                        else if c == "." && (index + 1 == chars.count || chars[index + 1].isWhitespace) { punctuation = index + 1 }
                    }
                    if let punctuation { end = punctuation }
                }
            }
            result.append(String(chars[start..<end])); start = end
        }
        return result
    }

    private static func paginate(_ value: String, capacity: Int) -> [String] {
        let chars = Array(value)
        guard !chars.isEmpty else { return [] }
        var result: [String] = [], start = 0
        while start < chars.count {
            let limit = min(start + capacity, chars.count)
            guard limit < chars.count else { result.append(String(chars[start..<limit])); break }
            let minimum = start + max(1, capacity / 2)
            var punctuation: Int?, whitespace: Int?
            for index in minimum..<limit {
                let character = chars[index]
                if ".!?。！？；;\n".contains(character) { punctuation = index + 1 }
                if character.isWhitespace { whitespace = index + 1 }
            }
            let end = punctuation ?? whitespace ?? limit
            result.append(String(chars[start..<end])); start = end
        }
        return result
    }
}
