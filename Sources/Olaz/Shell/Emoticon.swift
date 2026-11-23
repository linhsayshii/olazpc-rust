import SwiftUI

/// Text emoticons (`:)`, `:z`, `&-(`, `/-heart`…) shown as emoji, like the official Zalo PC.
///
/// The shortcut set and the tokenizer rules are the official client's (`emojiMapPos` keys + `xp5P` parser in `app.asar`,
/// zpw_ver 694): case-insensitive, longest match wins, and a match counts only when it stands alone, that is, it is
/// preceded by the start of the text, a space or a newline (or directly by another emoticon) and followed by the end of
/// the text, a space or a newline (or directly by another emoticon). So `10:30`, `http://…` and `a:)` stay as typed.
/// The official client draws its own sprite; here each shortcut maps to the closest Unicode emoji.
/// Display only: stored and sent text is never changed.
enum Emoticon {
    /// Lowercase shortcut → emoji. (`<3` is not an official shortcut and is left alone.)
    static let table: [String: String] = [
        ":d": "😁", "b-)": "😄", ":')": "😂", ":>": "🤣", ":))": "😎", ":-bye": "👋", "$-)": "🤑", ":)": "🙂",
        ":$": "😊", ";p": "🤭", "/-showlove": "🤗", ";-d": "😌", ":b": "😍", ":-*": "😘", ":*": "😚", ":3": "😊",
        ":p": "😜", ";g": "😋", "8-)": "😎", ":;": "😎", ";-)": "😉", "x-)": "😏", ":v": "😮", ";f": "🤔",
        ";d": "🤔", ":-l": "😒", ":-<": "😑", ":|": "😤", ":l": "😓", ":-r": "😣", ";-x": "🤫", ":handclap": "🙏",
        ":-dig": "🤧", ">-|": "😡", ":(": "🙁", ";o": "😕", "p-(": "🥺", ":--|": "😢", ":((": "😭", "8*": "🥹",
        ";!": "😵",
        ":!": "😳", ":-((": "😭", ":-h": "😡", ";-s": "😠", ":q": "😫", ";8": "😫", ";xx": "🔨", ";-/": "🤕",
        ";?": "😵‍💫", ":o": "😮", ";-a": "🤧", "8*)": "😳", ":x": "🤐", "--b": "😓", ":wipe": "😅", "&-(": "😥",
        ":~": "😖", ":-f": "😵", ":t": "🤮", "|-)": "🥱", ":-o": "🥱", ":z": "😴", ";-!": "😴",
        "/-beer": "🍺", "/-coffee": "☕", "/-rose": "🌹", "/-fade": "🥀", "/-bd": "🔪", "/-bome": "💣",
        "/-cake": "🎂", "/-heart": "❤️", "/-break": "💔", "/-shit": "💩", "/-li": "⚡", "/-strong": "👍",
        "/-weak": "👎", "/-ok": "👌", "/-v": "✌️", "/-thanks": "🙏", "/-punch": "✊", "/-share": "🤝",
        "_()_": "🙏", "/-no": "☝️", "/-bad": "✋", "/-loveu": "🤟", "/-flag": "🇻🇳", ":-|": "🥵", ":+": "😤",
    ]

    private static let longest = table.keys.map(\.count).max() ?? 0
    private static let firstChars = Set(table.keys.compactMap(\.first))

    /// Case folding that keeps one `Character` per `Character` (a few scripts lowercase to several).
    private static func fold(_ c: Character) -> Character {
        let l = c.lowercased()
        return l.count == 1 ? l.first! : c
    }

    /// One recognised emoticon: where it sits in the text and the emoji that replaces it.
    struct Match: Equatable {
        let range: Range<Int>      // character offsets
        let emoji: String
    }

    /// The standalone emoticons of `text`, in order (the official `xp5P` algorithm).
    static func matches(in text: String) -> [Match] {
        let chars = Array(text)
        let lower = chars.map(fold)
        guard lower.contains(where: firstChars.contains) else { return [] }

        // Greedy longest match from each position, non-overlapping.
        var found: [(start: Int, end: Int, key: String)] = []
        var i = 0
        while i < lower.count {
            var hit: (end: Int, key: String)?
            if firstChars.contains(lower[i]) {
                var key = ""
                var j = i
                while j < lower.count, j - i < longest {
                    key.append(lower[j])
                    if table[key] != nil { hit = (j, key) }
                    j += 1
                }
            }
            if let hit { found.append((i, hit.end, hit.key)); i = hit.end + 1 } else { i += 1 }
        }
        guard !found.isEmpty else { return [] }

        func isSeparator(_ index: Int) -> Bool {
            guard chars.indices.contains(index) else { return true }
            return chars[index] == " " || chars[index] == "\n" || chars[index] == "\r\n"
        }
        let starts = Set(found.map(\.start)), ends = Set(found.map(\.end))
        return found.compactMap { f in
            guard isSeparator(f.start - 1) || ends.contains(f.start - 1),
                  isSeparator(f.end + 1) || starts.contains(f.end + 1) else { return nil }
            return Match(range: f.start..<(f.end + 1), emoji: table[f.key]!)
        }
    }

    /// `text` with every standalone emoticon replaced by its emoji (previews, plain strings).
    static func replacing(in text: String) -> String {
        let found = matches(in: text)
        guard !found.isEmpty else { return text }
        let chars = Array(text)
        var out = ""
        var cursor = 0
        for m in found {
            out += String(chars[cursor..<m.range.lowerBound]) + m.emoji
            cursor = m.range.upperBound
        }
        return out + String(chars[cursor...])
    }

    /// Replaces the emoticons of an already styled text, keeping each replaced run's attributes.
    /// Run after mentions are applied: their ranges are offsets into the original text. Linked text is left alone.
    static func replacing(in text: AttributedString) -> AttributedString {
        let found = matches(in: String(text.characters))
        guard !found.isEmpty else { return text }
        var out = text
        for m in found.reversed() {
            let lo = out.characters.index(out.startIndex, offsetBy: m.range.lowerBound)
            let hi = out.characters.index(out.startIndex, offsetBy: m.range.upperBound)
            let range = lo..<hi
            guard out[range].link == nil else { continue }
            var emoji = AttributedString(m.emoji)
            if let first = out[range].runs.first { emoji.mergeAttributes(first.attributes) }
            out.replaceSubrange(range, with: emoji)
        }
        return out
    }
}
