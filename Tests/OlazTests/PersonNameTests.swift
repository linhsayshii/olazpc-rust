import Foundation
import Testing
@testable import Olaz

/// Official `getDName`: alias, else the Zalo name (never the phone-contacts `displayName` of a friend row), and
/// @mentions drawn as "@" + that name (`getMemberFriendlyName`).
@Suite struct PersonNameTests {
    @Test func friendRowPrefersZaloNameOverPhonebookDisplayName() {
        let row: [String: Any] = ["userId": "1", "displayName": "Tên danh bạ", "zaloName": "Tên Zalo"]
        #expect(ZaloWireParser.preferredName(row) == "Tên Zalo")
    }

    @Test func fallsBackWhenZaloNameMissingOrBlank() {
        #expect(ZaloWireParser.preferredName(["zaloName": "  ", "displayName": "A"]) == "A")
        #expect(ZaloWireParser.preferredName(["dName": "B"]) == "B")
        #expect(ZaloWireParser.preferredName(["zalo_name": "C", "display_name": "D"]) == "C")
        #expect(ZaloWireParser.preferredName([:]) == "")
    }

    @Test func mentionShowsAliasAndShiftsLaterRanges() {
        let text = "@Hoàng Tùng Dạ vâng @Lan ok"
        let mentions = [
            Mention(uid: "9760", pos: 0, len: 11, isAll: false),
            Mention(uid: "42", pos: 20, len: 4, isAll: false),
        ]
        let names = ["9760": "Thầy Tùng chôn lịch", "42": "Lan"]
        let out = ChatFormat.renamingMentions(text, mentions: mentions, name: { names[$0] })
        #expect(out.text == "@Thầy Tùng chôn lịch Dạ vâng @Lan ok")
        let ns = out.text as NSString
        #expect(ns.substring(with: NSRange(location: out.mentions[0].pos, length: out.mentions[0].len)) == "@Thầy Tùng chôn lịch")
        #expect(ns.substring(with: NSRange(location: out.mentions[1].pos, length: out.mentions[1].len)) == "@Lan")
    }

    @Test func unknownAllAndMalformedMentionsKeepSentText() {
        let all = ChatFormat.renamingMentions("@All họp", mentions: [Mention(uid: "-1", pos: 0, len: 4, isAll: true)], name: { _ in "X" })
        #expect(all.text == "@All họp")
        let unknown = ChatFormat.renamingMentions("@Ai đó", mentions: [Mention(uid: "7", pos: 0, len: 6, isAll: false)], name: { _ in nil })
        #expect(unknown.text == "@Ai đó")
        let outOfRange = ChatFormat.renamingMentions("@A", mentions: [Mention(uid: "7", pos: 0, len: 9, isAll: false)], name: { _ in "B" })
        #expect(outOfRange.text == "@A")
    }

    @MainActor
    @Test func listPreviewShowsMentionAlias() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-preview-alias-\(UUID())")
        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        engine.cachedAliases["9760"] = "Thầy Tùng chôn lịch"
        let msg = ChatMessage(
            id: "m1", conversationId: "g1", senderId: "u1", senderName: "Kim Liên",
            senderAvatar: nil, isMine: false, kind: .text, text: "@Hoàng Tùng Dạ vâng",
            date: Date(), status: .sent, quote: nil, reactions: [],
            isE2EE: false, mentions: [Mention(uid: "9760", pos: 0, len: 11, isAll: false)], cardButtons: [],
            suggestsStickers: false, menu: MessageMenu(json: [:])
        )
        engine.updateConversationOnMessage(msg, incrementUnread: false)
        #expect(engine.conversations.first(where: { $0.id == "g1" })?.preview?.text == "@Thầy Tùng chôn lịch Dạ vâng")
    }
}
