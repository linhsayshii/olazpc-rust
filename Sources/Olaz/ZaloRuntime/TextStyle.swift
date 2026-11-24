import Foundation

/// One styled range of a rich-text message (official `textProperties` / `content.params.styles`): `start` / `len` are
/// UTF-16 offsets into the text, `st` the comma-separated tokens the official editor writes (`normalizeFormat`).
struct TextStyle: Equatable, Hashable, Sendable {
    var start: Int
    var len: Int
    var st: String

    /// The official text colors (`text-color-red` … `text-color-green`).
    static let colors: [(token: String, hex: String, name: String)] = [
        ("c_db342e", "db342e", "Đỏ"),
        ("c_f27806", "f27806", "Cam"),
        ("c_f7b503", "f7b503", "Vàng"),
        ("c_15a85f", "15a85f", "Xanh lá"),
    ]
    /// Official font-size tokens: small and large (medium is the default and is never written).
    static let smallSize = 13
    static let largeSize = 18

    var tokens: [String] {
        st.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var json: [String: Any] { ["start": start, "len": len, "st": st] }

    /// `[{start, len, st}]`; entries without a style or a positive length are dropped.
    static func list(json: Any?) -> [TextStyle] {
        (json as? [[String: Any]] ?? []).compactMap { row in
            let st = (row["st"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let start = (row["start"] as? NSNumber)?.intValue ?? 0
            let len = (row["len"] as? NSNumber)?.intValue ?? 0
            guard !st.isEmpty, len > 0, start >= 0 else { return nil }
            return TextStyle(start: start, len: len, st: st)
        }
    }

    /// The `textProperties` value the official client sends with a styled message.
    static func textProperties(_ styles: [TextStyle]) -> String? {
        guard !styles.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["styles": styles.map(\.json), "ver": 0], options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The resolved look of a range: what the bubble draws and what the composer edits.
struct TextFormat: Equatable, Sendable {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    /// Hex without `#`, one of `TextStyle.colors`.
    var color: String?
    var size: Int?
    /// 1 bulleted, 2 numbered (official `lst_1` / `lst_2`).
    var list: Int?
    var indent: Int?

    init() {}

    init(tokens: [String]) {
        for token in tokens {
            switch token {
            case "b": bold = true
            case "i": italic = true
            case "u": underline = true
            case "s": strike = true
            case "lst_1": list = 1
            case "lst_2": list = 2
            default:
                if token.hasPrefix("c_") { color = String(token.dropFirst(2)) }
                else if token.hasPrefix("f_") { size = Int(token.dropFirst(2)) }
                else if token.hasPrefix("ind_") { indent = Int(token.dropFirst(4)) }
            }
        }
    }

    /// Tokens in the official order (`normalizeFormat`).
    var tokens: [String] {
        var out: [String] = []
        if let list { out.append(list == 2 ? "lst_2" : "lst_1") }
        if bold { out.append("b") }
        if italic { out.append("i") }
        if underline { out.append("u") }
        if let size { out.append("f_\(size)") }
        if let indent, indent != 0 { out.append("ind_\(indent)") }
        if strike { out.append("s") }
        if let color, color.lowercased() != "000000" { out.append("c_\(color)") }
        return out
    }

    var isPlain: Bool { tokens.isEmpty }
}
