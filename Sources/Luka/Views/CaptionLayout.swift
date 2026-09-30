import AppKit
import LukaCore

/// Captions render one SwiftUI row per visual line so they can roll up line by line,
/// like broadcast captions, instead of reflowing a clipped paragraph.
struct CaptionRow: Identifiable, Equatable {
    let id: String
    let speaker: SpeakerID?
    var showsLabel = false
    let isOriginal: Bool
    let solid: String
    let faint: String
    let height: CGFloat
}

struct CaptionBlock: Equatable {
    let id: Int
    let speaker: SpeakerID?
    let solid: String
    let faint: String
    let original: String
    let originalFaint: String
    let translated: Bool
}

struct CaptionMetrics: Equatable {
    let fontSize: CGFloat

    var font: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    var lineHeight: CGFloat { ceil(fontSize * 1.36) }
    var originalFontSize: CGFloat { max(11, (fontSize * 0.62).rounded()) }
    var originalFont: NSFont { .systemFont(ofSize: originalFontSize, weight: .regular) }
    var originalLineHeight: CGFloat { ceil(originalFontSize * 1.4) }
    var labelFontSize: CGFloat { max(10, (fontSize * 0.54).rounded()) }
    var labelFont: NSFont { .systemFont(ofSize: labelFontSize, weight: .semibold) }
    var horizontalPadding: CGFloat { max(14, fontSize * 0.75) }
    var verticalPadding: CGFloat { max(8, fontSize * 0.42) }
    var gutterSpacing: CGFloat { max(8, fontSize * 0.45) }

    func height(lines: Int) -> CGFloat { CGFloat(lines) * lineHeight + verticalPadding * 2 }
}

@MainActor
enum CaptionLayout {
    static func blocks(from transcript: Transcript, dual: Bool, limit: Int = 8) -> [CaptionBlock] {
        var blocks: [CaptionBlock] = []
        let provisional = transcript.provisional
        var provisionalPlaced = false
        let recent = transcript.lines.suffix(limit)
        for line in recent {
            var faint = line.untranslatedTail
            var originalFaint = ""
            if let p = provisional, line.id == recent.last?.id, line.isOpen,
               p.speaker.map(transcript.canonical) == line.speaker.map(transcript.canonical) || p.speaker == nil {
                faint = join(faint, p.text)
                originalFaint = p.text
                provisionalPlaced = true
            }
            blocks.append(CaptionBlock(
                id: line.id, speaker: line.speaker,
                solid: line.primary, faint: faint,
                original: line.original, originalFaint: originalFaint, translated: line.expectsTranslation))
        }
        if let p = provisional, !provisionalPlaced {
            blocks.append(CaptionBlock(id: transcript.nextLineID, speaker: p.speaker, solid: "", faint: p.text,
                                       original: "", originalFaint: p.text, translated: true))
        }
        return blocks
    }

    static func rows(_ blocks: [CaptionBlock], width: CGFloat, metrics: CaptionMetrics, dual: Bool, budget: CGFloat,
                     same: (SpeakerID?, SpeakerID?) -> Bool) -> [CaptionRow] {
        guard width > 20 else { return [] }
        var remaining = budget
        var visible: [[CaptionRow]] = []

        outer: for block in blocks.reversed() {
            var paragraphs: [(original: Bool, solid: String, faint: String)] = []
            if dual && block.translated {
                paragraphs.append((true, block.original, block.originalFaint))
                paragraphs.append((false, block.solid, ""))
            } else {
                paragraphs.append((false, block.solid, block.faint))
            }
            var blockRows: [CaptionRow] = []
            var truncated = false
            for paragraph in paragraphs.reversed() {
                let font = paragraph.original ? metrics.originalFont : metrics.font
                let lh = paragraph.original ? metrics.originalLineHeight : metrics.lineHeight
                let text = join(paragraph.solid, paragraph.faint)
                guard !text.isEmpty else { continue }
                let solidLength = paragraph.faint.isEmpty ? text.count : (paragraph.solid.isEmpty ? 0 : paragraph.solid.count + 1)
                let lines = lineRanges(text, font: font, width: width)
                var taken: [CaptionRow] = []
                for (index, range) in lines.enumerated().reversed() {
                    guard remaining >= lh - 0.5 else { truncated = true; break }
                    remaining -= lh
                    let start = text.distance(from: text.startIndex, to: range.lowerBound)
                    let end = text.distance(from: text.startIndex, to: range.upperBound)
                    let cut = min(max(solidLength, start), end)
                    let solid = String(text[range.lowerBound..<text.index(text.startIndex, offsetBy: cut)])
                    let faint = String(text[text.index(text.startIndex, offsetBy: cut)..<range.upperBound])
                    taken.insert(CaptionRow(
                        id: "\(block.id).\(paragraph.original ? "o" : "t").\(index)",
                        speaker: block.speaker, isOriginal: paragraph.original,
                        solid: faint.isEmpty ? solid.trimmingLeadingWhitespace().trimmingTrailingWhitespace() : solid.trimmingLeadingWhitespace(),
                        faint: faint.trimmingTrailingWhitespace(), height: lh), at: 0)
                }
                blockRows.insert(contentsOf: taken, at: 0)
                if truncated { break }
            }
            if !blockRows.isEmpty { visible.insert(blockRows, at: 0) }
            if truncated { break outer }
        }

        var previous: SpeakerID?? = .none
        for i in visible.indices {
            let speaker = visible[i].first?.speaker
            if case .some(let p) = previous, same(p, speaker) {
            } else if speaker != nil {
                visible[i][0].showsLabel = true
            }
            previous = .some(speaker)
        }
        return visible.flatMap { $0 }
    }

    static func lineRanges(_ text: String, font: NSFont, width: CGFloat) -> [Range<String.Index>] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .standard
        let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: style])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var ranges: [Range<String.Index>] = []
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var lineRange = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            let chars = layout.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
            if let r = Range(chars, in: text) { ranges.append(r) }
            glyph = NSMaxRange(lineRange)
        }
        return ranges
    }

    static func labelWidth(_ names: [String], metrics: CaptionMetrics, limit: CGFloat) -> CGFloat {
        let widest = names.map { ($0 as NSString).size(withAttributes: [.font: metrics.labelFont]).width }.max() ?? 0
        return min(ceil(widest) + 2, limit)
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

extension String {
    func trimmingLeadingWhitespace() -> String { String(drop(while: \.isWhitespace)) }
    func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while s.last?.isWhitespace == true { s = s.dropLast() }
        return String(s)
    }
}
