import Testing
import Foundation
import JavaScriptCore
@testable import Olaz
@Suite struct StickerModelTests {
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    @Test func stickersNeedIdsAndAWebUrlAndAreUnique() throws {
        let list = StickerEntry.list(json: try json(#"""
        [{"cateId":10,"id":1,"url":"https://cdn.example/a"},{"cateId":10,"id":1,"url":"https://cdn.example/dup"},
         {"cateId":0,"id":2,"url":"http://cdn.example/b"},{"cateId":10,"id":0,"url":"https://cdn.example/c"},
         {"cateId":-1,"id":3,"url":"https://cdn.example/d"},{"cateId":10,"id":4,"url":"file:///etc/passwd"},
         {"cateId":10,"id":5},{"id":6,"url":"https://cdn.example/e"},"x",null]
        """#))
        #expect(list.map(\.id) == ["10_1", "0_2"])
        #expect(list.first?.url.absoluteString == "https://cdn.example/a")
        #expect(StickerEntry.list(json: nil).isEmpty && StickerEntry.list(json: ["not", "rows"]).isEmpty)
    }

    @Test func listsAreCapped() throws {
        let rows = (1...800).map { #"{"cateId":1,"id":\#($0),"url":"https://cdn.example/\#($0)"}"# }.joined(separator: ",")
        #expect(StickerEntry.list(json: try json("[\(rows)]")).count == 500)
        #expect(StickerEntry.list(json: try json("[\(rows)]"), limit: 40).count == 40)
    }

    @Test func tabsKeepOrderAndTellUnavailableFromEmpty() throws {
        let tabs = try #require(StickerTab.list(json: try json(#"""
        [{"id":-2,"name":"Gần đây","icon":"","count":3},{"id":12556,"name":"Mèo","icon":"https://cdn.example/i","count":24},
         {"id":12556,"name":"dup","icon":"","count":1},{"id":-9,"name":"bad"},{"id":0,"name":"Emoji","icon":"javascript:alert(1)","count":-4}]
        """#)))
        #expect(tabs.map(\.id) == [-2, 12556, 0])
        #expect(tabs[0].isRecent && !tabs[1].isRecent)
        #expect(tabs[1].icon?.absoluteString == "https://cdn.example/i")
        #expect(tabs[2].icon == nil && tabs[2].count == 0)
        #expect(StickerTab.list(json: try json("[]"))?.isEmpty == true, "no sets is an answer")
        #expect(StickerTab.list(json: NSNull()) == nil && StickerTab.list(json: nil) == nil, "unavailable is not an empty list")
    }

    @Test func suggestSettingParsing() throws {
        let on = try #require(StickerSuggestSetting(json: try json(#"{"ok":true,"enabled":true,"debounce":250}"#)))
        #expect(on.enabled && on.debounce == 250)
        #expect(StickerSuggestSetting(json: try json(#"{"ok":true,"enabled":false,"debounce":99999}"#))?.debounce == 2000)
        #expect(StickerSuggestSetting(json: try json(#"{"ok":false,"enabled":true}"#)) == nil, "a setting that could not be read is unknown, not on")
        #expect(StickerSuggestSetting(json: nil) == nil)
    }

    @MainActor @Test func typingDelayNeverGoesBelowTheCoalescingFloor() throws {
        let state = StickerSuggestState()
        #expect(state.delay == StickerSuggestState.minimumDelay, "setting not loaded yet")
        state.apply(StickerSuggestSetting(json: try json(#"{"ok":true,"enabled":true,"debounce":0}"#)))
        #expect(state.delay == StickerSuggestState.minimumDelay, "the server config says 0 today")
        state.apply(StickerSuggestSetting(json: try json(#"{"ok":true,"enabled":true,"debounce":400}"#)))
        #expect(state.delay == 400)
        state.reset()
        #expect(state.setting == nil)
    }

    @Test func sendOutcomesUseTheCardActionStatuses() throws {
        #expect(CardActionOutcome(json: try json(#"{"status":"done"}"#)) == .done)
        guard case .locked = CardActionOutcome(json: try json(#"{"status":"locked"}"#)) else { Issue.record("locked"); return }
        guard case .failed = CardActionOutcome(json: try json(#"{"status":"busy"}"#)) else { Issue.record("busy"); return }
        guard case .failed = CardActionOutcome(json: try json(#"{"status":"not-found"}"#)) else { Issue.record("not-found"); return }
    }

    @Test func stickerAnimationsAreValidated() throws {
        let list = StickerEntry.list(json: try json(#"""
        [{"cateId":1,"id":1,"url":"https://cdn.example/a","anim":{"kind":"sprite","url":"https://cdn.example/s","frames":16,"ms":60}},
         {"cateId":1,"id":2,"url":"https://cdn.example/b","anim":{"kind":"sprite","url":"https://cdn.example/s","frames":1,"ms":60}},
         {"cateId":1,"id":3,"url":"https://cdn.example/c","anim":{"kind":"sprite","url":"file:///x","frames":8,"ms":60}},
         {"cateId":1,"id":4,"url":"https://cdn.example/d","anim":{"kind":"gif","url":"https://cdn.example/g.gif"}},
         {"cateId":1,"id":5,"url":"https://cdn.example/e","anim":{"kind":"sprite","url":"https://cdn.example/s","frames":8,"ms":1}}]
        """#))
        #expect(list[0].animation == .sprite(url: URL(string: "https://cdn.example/s")!, frames: 16, frameMs: 60))
        #expect(list[1].animation == nil && list[2].animation == nil)
        #expect(list[3].animation == .animated(url: URL(string: "https://cdn.example/g.gif")!))
        #expect(list[4].animation == .sprite(url: URL(string: "https://cdn.example/s")!, frames: 8, frameMs: 30))
        let webp = StickerEntry.list(json: try json(#"[{"cateId":1,"id":1,"url":"https://cdn.example/a","anim":{"kind":"webp","url":"https://cdn.example/w"}}]"#))
        #expect(webp.first?.animation == .animated(url: URL(string: "https://cdn.example/w")!), "an animated WebP plays like a GIF, never as a sprite sheet")
    }
}

/// The composer's suggestion strip: stale stickers never show, and a click takes the whole box first.
@Suite struct TypingStickerStateTests {
    private func sticker(_ id: Int) -> StickerEntry { StickerEntry(cateId: 1, stickerId: id, url: URL(string: "https://cdn.example/\(id)")!) }

    @Test func theStripShowsOnlyForTheTextItWasFoundFor() {
        var state = TypingStickerState()
        state.offer([sticker(1)], for: "chào")
        func visible(_ draft: String, mention: Bool = false, enabled: Bool? = true) -> Bool {
            state.isVisible(draft: draft, mentionListOpen: mention, settingEnabled: enabled)
        }
        #expect(visible("chào"))
        #expect(!visible("chào bạn"), "the draft moved on: the old stickers are stale")
        #expect(!visible("chà"))
        #expect(!visible("chào", mention: true))
        #expect(!visible("chào", enabled: false), "setting turned off")
        #expect(visible("chào", enabled: nil), "setting not read yet is not a no")
        state.offer([], for: "chào")
        #expect(!visible("chào"))
        state.offer([sticker(1)], for: "   ")
        #expect(!visible("   "), "blank draft")
    }

    @Test func dismissalHoldsUntilTheComposerResetsIt() {
        var state = TypingStickerState()
        state.offer([sticker(1)], for: "chào")
        state.dismissed = true
        #expect(!state.isVisible(draft: "chào", mentionListOpen: false, settingEnabled: true))
        state.dismissed = false   // the composer does this on every draft change
        #expect(state.isVisible(draft: "chào", mentionListOpen: false, settingEnabled: true))
    }

    @Test func aClickTakesTheWholeDraft() throws {
        var state = TypingStickerState()
        state.offer([sticker(1)], for: "chào")
        let draft = ComposerDraft(text: "chào", mentions: [Mention(uid: "9", pos: 0, len: 2)])
        let taken = state.take(draft)
        #expect(taken.draft == draft && taken.typed == "chào")
        #expect(state.stickers.isEmpty && state.suggestedFor == nil, "the strip is gone with the box")
    }

    @Test func aFailedSendGivesTheTextBackAfterWhatWasTypedMeanwhile() throws {
        var state = TypingStickerState()
        state.offer([sticker(1)], for: "chào @An")
        let taken = state.take(ComposerDraft(text: "chào @An", mentions: [Mention(uid: "9", pos: 5, len: 3)]))
        var store = FailedDraftStore()
        store.stash(taken.draft, for: "c1", silent: true)       // what the composer does when the send fails
        let backOrNil = store.take(for: "c1")
        let back = try #require(backOrNil)
        let merged = ComposerDraft(text: "xyz").appending(back)   // ChatView.restoreFailedDraft
        #expect(merged.text == "xyz\nchào @An")
        #expect(merged.mentions == [Mention(uid: "9", pos: 9, len: 3)], "mention offsets move with the text")
    }
}

/// Outcomes that must never re-arm a second send, and the draft hand-back after a failed strip send.
@Suite struct StickerSendOutcomeTests {
    private func sticker(_ id: Int) -> StickerEntry { StickerEntry(cateId: 1, stickerId: id, url: URL(string: "https://cdn.example/\(id)")!) }

    @Test func noAnswerIsPendingNotAFailure() throws {
        let page = try JSONSerialization.jsonObject(with: Data(#"{"status":"pending","text":"Có thể đã gửi"}"#.utf8))
        #expect(CardActionOutcome(json: page) == .pending("Có thể đã gửi"))
        #expect(CardActionOutcome.noAnswerText.contains("kiểm tra lại cuộc trò chuyện"), "the Swift-side cap says to look, not to retry")
        #expect(CardActionOutcome.pending("x").logName == "pending")
    }

    @Test func aPendingSendHoldsTheStripBackForThatTextOnly() {
        var state = TypingStickerState()
        state.offer([sticker(1)], for: "chào")
        _ = state.take(ComposerDraft(text: "chào"))
        state.hold("chào")
        state.clear()   // the draft is empty now: clearing keeps the hold
        state.offer([sticker(1)], for: "chào")
        #expect(state.stickers.isEmpty && state.suggestedFor == nil, "the cached suggestion for the same text does not come back")
        #expect(state.isHeld("chào"))
        state.offer([sticker(2)], for: "chào bạn")
        #expect(state.stickers.count == 1 && !state.isHeld("chào"), "other text is suggested for again")
    }

    @Test func aSilentStashGivesTheTextBackWithoutTheNotSentNotice() {
        var store = FailedDraftStore()
        store.stash(ComposerDraft(text: "chào"), for: "c1", silent: true)
        let silent = store.takeWithNotice(for: "c1")
        #expect(silent?.draft.text == "chào" && silent?.notice == false)
        // a normal failure keeps its notice, also when merged with a silent one
        store.stash(ComposerDraft(text: "a"), for: "c2", silent: true)
        store.stash(ComposerDraft(text: "b"), for: "c2")
        let merged = store.takeWithNotice(for: "c2")
        #expect(merged?.draft.text == "a\nb" && merged?.notice == true)
        store.stash(ComposerDraft(text: "y"), for: "c4", silent: true)
        _ = store.drain()
        store.stash(ComposerDraft(text: "z"), for: "c4")
        #expect(store.takeWithNotice(for: "c4")?.notice == true, "drain forgets the silent mark")
    }

    @Test func unsentDraftsAreForgottenAtLogout() throws {
        // `logOut()` clears cookies of the real app, so it is not run here: both reset points are checked in the source.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Olaz/ZaloRuntime/ZaloEngine.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.components(separatedBy: "failedDrafts = FailedDraftStore()").count - 1 >= 2, "logOut() and the .loggedOut handler")
    }
}

