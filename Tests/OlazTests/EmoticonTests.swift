import Testing
import Foundation
import SwiftUI
@testable import Olaz

/// Text emoticons → emoji: the official shortcut set and its tokenizer rules (standalone, longest match, case-insensitive).
@Suite struct EmoticonTests {
    private func convert(_ s: String) -> String { Emoticon.replacing(in: s) }

    @Test func officialSetHasAllEightyNineShortcuts() {
        #expect(Emoticon.table.count == 89)
        #expect(Emoticon.table.keys.allSatisfy { $0 == $0.lowercased() })
    }

    @Test func convertsStandaloneShortcuts() {
        #expect(convert(":)") == "🙂")
        #expect(convert(":z") == "😴")
        #expect(convert("&-(") == "😥")
        #expect(convert(":((") == "😭")
        #expect(convert(":D") == "😁")
        #expect(convert(":-h") == "😡")
        #expect(convert(":-*") == "😘")
        #expect(convert(":')") == "😂")
        #expect(convert(":o") == "😮")
        #expect(convert("/-heart") == "❤️")
    }

    @Test func caseInsensitive() {
        #expect(convert(":Z") == convert(":z"))
        #expect(convert("/-HEART") == convert("/-heart"))
    }

    @Test func longestMatchWins() {
        #expect(convert(":))") == Emoticon.table[":))"])
        #expect(convert(":-((") == Emoticon.table[":-(("])
        #expect(convert(":((") == Emoticon.table[":(("])
    }

    @Test func insideSentence() {
        #expect(convert("hello :) world") == "hello 🙂 world")
        #expect(convert("a :z\nb :D") == "a 😴\nb 😁")
        #expect(convert("ok :) :o") == "ok 🙂 😮")
    }

    @Test func adjacentEmoticonsStayTogether() {
        #expect(convert(":):o") == "🙂😮")
    }

    @Test func leavesNonStandaloneAlone() {
        for text in ["10:30", "a:)", ":)a", "http://example.com", "https://x.vn/a:z", "word:d", "time 10:3x", "Re: hi",
                     "<3", "xin chào", "a:b", ":dd"] {
            #expect(convert(text) == text, "\(text)")
        }
    }

    @Test func unknownShortcutUntouched() {
        #expect(convert(":zz") == ":zz")
        #expect(convert("; )") == "; )")
    }

    @Test func attributedKeepsAttributesAndSkipsLinks() {
        var text = AttributedString("hi :) https://a.vn :z")
        text.foregroundColor = .red
        let out = Emoticon.replacing(in: text)
        #expect(String(out.characters) == "hi 🙂 https://a.vn 😴")
        #expect(out.runs.allSatisfy { $0.foregroundColor == .red })

        var linked = AttributedString(":)")
        linked.link = URL(string: "https://a.vn")
        #expect(String(Emoticon.replacing(in: linked).characters) == ":)")
    }

    @Test func plainTextUnchanged() {
        let text = AttributedString("no emoticon here")
        #expect(Emoticon.replacing(in: text) == text)
    }

    @Test func appKitTextReplacedKeepingLinks() {
        let text = NSMutableAttributedString(string: "hi :) https://a.vn :z")
        text.addAttribute(.link, value: URL(string: "https://a.vn")!, range: NSRange(location: 6, length: 12))
        Emoticon.replace(in: text)
        #expect(text.string == "hi 🙂 https://a.vn 😴")
        let link = (text.string as NSString).range(of: "https://a.vn")
        #expect(text.attribute(.link, at: link.location, effectiveRange: nil) != nil)

        let linked = NSMutableAttributedString(string: ":)", attributes: [.link: URL(string: "https://a.vn")!])
        Emoticon.replace(in: linked)
        #expect(linked.string == ":)")
    }
}
