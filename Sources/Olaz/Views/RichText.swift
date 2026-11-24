import AppKit
import SwiftUI

/// Rich-text messages (official `textProperties.styles`): bold / italic / underline / strike, the four text colors, small
/// and large sizes, bulleted and numbered lists, indent. The bubble draws the same text twice (SwiftUI `Text` and the
/// selectable AppKit layer over it), so both are built from one layout here.
extension ChatFormat {
    /// The text as drawn: list lines get their "• " / "1. " marker. `insertions` (UTF-16, ascending) shift the message's
    /// own offsets (styles, mentions) into the drawn text.
    struct RichLayout: Equatable {
        var text: String
        var insertions: [(at: Int, length: Int)]
        /// Formatting of each drawn range (ranges in the drawn text, ascending, not overlapping).
        var segments: [(range: NSRange, format: TextFormat)]

        static func == (a: RichLayout, b: RichLayout) -> Bool { a.text == b.text }

        /// A message offset in the drawn text.
        func map(_ offset: Int) -> Int {
            var shift = 0
            for ins in insertions where ins.at <= offset { shift += ins.length }
            return offset + shift
        }
    }

    static func richLayout(_ text: String, styles: [TextStyle]) -> RichLayout {
        let ns = text as NSString
        let length = ns.length
        let clamped = styles.compactMap { s -> (NSRange, [String])? in
            let start = min(max(0, s.start), length)
            let end = min(length, s.start + s.len)
            guard end > start else { return nil }
            return (NSRange(location: start, length: end - start), s.tokens)
        }

        // List markers: one per line that a list range touches, numbered within a run of consecutive numbered lines.
        var insertions: [(at: Int, length: Int, marker: String)] = []
        var lineStart = 0
        var number = 0
        while lineStart <= length {
            let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: lineStart, length: length - lineStart)).location
            let end = lineEnd == NSNotFound ? length : lineEnd
            let list = clamped.compactMap { range, tokens -> Int? in
                guard NSIntersectionRange(range, NSRange(location: lineStart, length: max(1, end - lineStart))).length > 0
                        || (range.location == lineStart && end == lineStart) else { return nil }
                return TextFormat(tokens: tokens).list
            }.first
            if let list, end > lineStart {
                number = list == 2 ? number + 1 : 0
                let marker = list == 2 ? "\(number). " : "• "
                insertions.append((lineStart, (marker as NSString).length, marker))
            } else {
                number = 0
            }
            if lineEnd == NSNotFound { break }
            lineStart = end + 1
        }
        var drawn = ""
        var cursor = 0
        for ins in insertions {
            drawn += ns.substring(with: NSRange(location: cursor, length: ins.at - cursor)) + ins.marker
            cursor = ins.at
        }
        drawn += ns.substring(from: cursor)
        let layout0 = RichLayout(text: drawn, insertions: insertions.map { ($0.at, $0.length) }, segments: [])

        // Segments: split at every style boundary, each piece takes the union of the styles covering it.
        var cuts = Set<Int>([0, length])
        for (range, _) in clamped { cuts.insert(range.location); cuts.insert(NSMaxRange(range)) }
        let points = cuts.sorted()
        var segments: [(range: NSRange, format: TextFormat)] = []
        for (a, b) in zip(points, points.dropFirst()) where b > a {
            let tokens = clamped.filter { $0.0.location <= a && NSMaxRange($0.0) >= b }.flatMap(\.1)
            var format = TextFormat(tokens: tokens)
            format.list = nil
            guard !format.isPlain else { continue }
            let from = layout0.map(a), to = layout0.map(b)
            // A marker inserted at `b` belongs to the next line, not to this piece.
            let markerAtEnd = insertions.first { $0.at == b }?.length ?? 0
            segments.append((NSRange(location: from, length: to - from - markerAtEnd), format))
        }
        var layout = layout0
        layout.segments = segments
        return layout
    }

    private static func color(_ hex: String) -> NSColor? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// Official sizes are pixels at the default 14; the bubble's own size scales them.
    private static func pointSize(_ format: TextFormat, base: CGFloat) -> CGFloat {
        guard let size = format.size else { return base }
        return base * CGFloat(min(max(size, 11), 24)) / 14
    }

    static func nsFont(_ format: TextFormat, base: CGFloat) -> NSFont {
        var font = NSFont.systemFont(ofSize: pointSize(format, base: base), weight: format.bold ? .semibold : .regular)
        if format.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    /// Styles the SwiftUI form of the bubble text (already linkified / mentioned over `layout.text`).
    static func applyRich(_ layout: RichLayout, to out: inout AttributedString, mine: Bool, base: CGFloat) {
        let s = layout.text
        for (range, format) in layout.segments {
            guard let r = Range(range, in: s), let ar = Range<AttributedString.Index>(r, in: out) else { continue }
            var font = Font.system(size: pointSize(format, base: base), weight: format.bold ? .semibold : .regular)
            if format.italic { font = font.italic() }
            out[ar].font = font
            if format.underline { out[ar].underlineStyle = .single }
            if format.strike { out[ar].strikethroughStyle = .single }
            if let hex = format.color, let c = color(hex) { out[ar].foregroundColor = Color(nsColor: c) }
        }
    }

    /// Styles the AppKit form (the selectable layer), same as `applyRich(_:to:mine:base:)`.
    static func applyRich(_ layout: RichLayout, to out: NSMutableAttributedString, base: CGFloat) {
        for (range, format) in layout.segments where NSMaxRange(range) <= out.length {
            out.addAttribute(.font, value: nsFont(format, base: base), range: range)
            if format.underline { out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if format.strike { out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if let hex = format.color, let c = color(hex) { out.addAttribute(.foregroundColor, value: c, range: range) }
        }
    }

    /// Mentions of the message moved into the drawn text.
    static func mapped(_ mentions: [Mention], _ layout: RichLayout) -> [Mention] {
        mentions.map { m in
            var m = m
            m.pos = layout.map(m.pos)
            return m
        }
    }
}
