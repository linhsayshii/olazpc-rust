import AppKit
import Foundation
import Testing
@testable import Olaz

@Suite("Định dạng tin nhắn")
struct RichTextTests {
    nonisolated(unsafe) private static let rtf: [String: Any] = [
        "msgId": "8601", "cliMsgId": "1801", "uidFrom": "peer", "idTo": "me", "msgType": "webchat", "ts": 1,
        "content": ["action": "rtf", "title": "Đậm nghiêng", "description": "", "href": "", "thumb": "", "type": "", "childnumber": 0,
                    "params": #"{"styles":[{"start":0,"len":3,"st":"b"},{"start":4,"len":7,"st":"i,c_db342e"},{"start":0,"len":0,"st":"u"}],"ver":0}"#]
    ]

    /// Same as Rust `rtf_styles_parse_and_round_trip`: styles from `params.styles`, kept through the store.
    @Test func swiftParserReadsRtfStyles() throws {
        let evt = ZaloWireParser.parseWireMessage(Self.rtf, myUid: "me")
        guard case .message(let msg, let stored) = evt else { Issue.record("expected message"); return }
        #expect(msg.kind == .text)
        #expect(msg.text == "Đậm nghiêng")
        #expect(msg.textStyles == [TextStyle(start: 0, len: 3, st: "b"), TextStyle(start: 4, len: 7, st: "i,c_db342e")])
        let decoded = try #require(ZaloWireParser.decodeStoredMessage(stored))
        #expect(decoded.textStyles == msg.textStyles)
    }

    @Test func formatTokensRoundTrip() {
        let f = TextFormat(tokens: ["b", "i", "u", "s", "c_15a85f", "f_18", "lst_2"])
        #expect(f.bold && f.italic && f.underline && f.strike)
        #expect(f.color == "15a85f" && f.size == 18 && f.list == 2)
        #expect(f.tokens == ["lst_2", "b", "i", "u", "f_18", "s", "c_15a85f"])
        #expect(TextStyle.textProperties([TextStyle(start: 0, len: 3, st: "b")]) == #"{"styles":[{"len":3,"st":"b","start":0}],"ver":0}"#)
        #expect(TextStyle.textProperties([]) == nil)
    }

    @Test func segmentsMergeOverlappingStyles() {
        let layout = ChatFormat.richLayout("abcdef", styles: [
            TextStyle(start: 0, len: 4, st: "b"), TextStyle(start: 2, len: 4, st: "i"),
        ])
        #expect(layout.text == "abcdef")
        let parts = layout.segments.map { ($0.range.location, $0.range.length, $0.format.bold, $0.format.italic) }
        #expect(parts.count == 3)
        #expect(parts[0] == (0, 2, true, false))
        #expect(parts[1] == (2, 2, true, true))
        #expect(parts[2] == (4, 2, false, true))
    }

    @Test func listLinesGetMarkersAndOffsetsShift() {
        // "Mua\nRau\nThịt" with lines 1–2 numbered and the last bold.
        let text = "Mua\nRau\nThịt"
        let layout = ChatFormat.richLayout(text, styles: [
            TextStyle(start: 0, len: 7, st: "lst_2"), TextStyle(start: 8, len: 4, st: "b"),
        ])
        #expect(layout.text == "1. Mua\n2. Rau\nThịt")
        #expect(layout.map(8) == 14)
        let bold = layout.segments.first { $0.format.bold }
        #expect(bold?.range == NSRange(location: 14, length: 4))
        let bullets = ChatFormat.richLayout("a\nb", styles: [TextStyle(start: 0, len: 3, st: "lst_1")])
        #expect(bullets.text == "• a\n• b")
    }

    @MainActor @Test func composerRunsBecomeStyles() {
        let storage = NSMutableAttributedString(string: "xin chào bạn", attributes: ComposerTextView.baseAttributes)
        var bold = TextFormat(); bold.bold = true
        var red = TextFormat(); red.color = "db342e"
        storage.setAttributes(ComposerTextView.attributes(for: bold), range: NSRange(location: 0, length: 3))
        storage.setAttributes(ComposerTextView.attributes(for: red), range: NSRange(location: 9, length: 3))
        #expect(ComposerTextView.styles(of: storage) == [
            TextStyle(start: 0, len: 3, st: "b"), TextStyle(start: 9, len: 3, st: "c_db342e"),
        ])
    }
}
