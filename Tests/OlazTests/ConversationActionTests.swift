import Testing
import Foundation
@testable import Olaz

@Suite @MainActor struct ConversationActionTests {
    private func state(_ flags: [String: ConversationActionFlags] = [:], left: [String: ConversationLeaveType] = [:],
                       hidden: Bool = true, markUnread: Bool = true) -> ConversationActionsState {
        var s = ConversationActionsState()
        s.loaded = true
        s.hiddenKnown = true
        s.flags = flags
        s.left = left
        s.hiddenEnabled = hidden
        s.markUnreadEnabled = markUnread
        return s
    }

    private func plan(_ id: String = "c1", _ preset: ConversationMenuPreset = .thread, state s: ConversationActionsState,
                      unread: Int = 0, muted: Bool = false) -> ConversationMenuPlan {
        ConversationMenuPlan.make(id: id, preset: preset, state: s, unread: unread, muted: muted)
    }

    // MARK: snapshot parsing

    @Test func parsesSnapshot() {
        var s = ConversationActionsState()
        s.apply(json: [
            "flags": ["a": 1 | 2, "b": 8 | 16, "c": 0],
            "left": ["g9": "disband"],
            "hidden": ["enabled": true, "hasPin": true, "ids": ["h1"]],
            "markUnread": true,
        ])
        #expect(s.loaded && s.hiddenKnown)
        #expect(s.flags(for: "a") == [.pinned, .archived])
        #expect(s.flags(for: "b") == [.cannotPin, .cannotArchive])
        #expect(s.flags(for: "c").isEmpty && s.flags(for: "zzz").isEmpty)
        #expect(s.left["g9"] == .disband)
        #expect(s.hiddenEnabled && s.hasHiddenPIN && s.markUnreadEnabled)
        #expect(s.isHidden("h1") && s.isPinned("a"))
    }

    // MARK: hidden state published before the rest (item: fail closed)

    @Test func hiddenPartArrivesBeforeTheFullSnapshot() {
        var s = ConversationActionsState()
        #expect(!s.hiddenKnown && !s.loaded)
        // Nothing is known: not even a "hidden" id.
        #expect(!s.isHidden("h1"))
        s.apply(json: ["hidden": ["enabled": true, "hasPin": false, "ids": ["h1", "g2"]]])
        #expect(s.hiddenKnown && !s.loaded)
        #expect(s.isHidden("h1") && s.isHidden("g2") && !s.isHidden("c1"))
        // The full snapshot later keeps what the early part said.
        s.apply(json: ["flags": ["c1": 8], "left": [String: Any](), "hidden": ["enabled": true, "hasPin": true, "ids": ["h1"]]])
        #expect(s.loaded && s.hasHiddenPIN && !s.isHidden("g2"))
    }

    @Test func hiddenFlagAloneHidesAConversation() {
        var s = ConversationActionsState()
        s.apply(json: ["flags": ["x": 4], "hidden": ["enabled": true, "hasPin": true, "ids": [String]()]])
        #expect(s.isHidden("x"))
    }

    // MARK: menu plan (official `ae.render`)

    @Test func plainConversationOffersEverythingInOrder() {
        let p = plan(state: state())
        #expect(p.pin == .pin && p.archive == .moveToOther && p.read == .markUnread && p.mute == .mute && p.hide == .hide)
        #expect(p.canDelete && p.showsLabel)
    }

    @Test func aliasEntryAppearsOnOneToOneThreadAndHeaderMenusOnly() {
        let s = state(
            ["cloud": [.cannotDelete], "g_left": []],
            left: ["g_left": .kick]
        )

        let threadFriend = ConversationMenuPlan.make(id: "3000101", preset: .thread, state: s, unread: 0, muted: false, canEditAlias: true)
        #expect(threadFriend.canEditAlias && !threadFriend.isEmpty)

        let headerFriend = ConversationMenuPlan.make(id: "3000101", preset: .chatBox, state: s, unread: 0, muted: false, canEditAlias: true)
        #expect(headerFriend.canEditAlias && !headerFriend.isEmpty)

        // Groups / strangers / self pass canEditAlias: false.
        let headerGroup = ConversationMenuPlan.make(id: "g500101", preset: .chatBox, state: s, unread: 0, muted: false, canEditAlias: false)
        #expect(!headerGroup.canEditAlias)

        // Defense in depth: My Cloud (cannotDelete) and left groups never offer alias editing even if requested.
        let cloud = ConversationMenuPlan.make(id: "cloud", preset: .thread, state: s, unread: 0, muted: false, canEditAlias: true)
        #expect(!cloud.canEditAlias)

        let leftGroup = ConversationMenuPlan.make(id: "g_left", preset: .thread, state: s, unread: 0, muted: false, canEditAlias: true)
        #expect(!leftGroup.canEditAlias && leftGroup.canDelete)
    }


    @Test func pinStates() {
        #expect(plan(state: state(["c1": .pinned])).pin == .unpin)
        // Unpin stays offered when "cannot pin" is set (e.g. its last message is gone).
        #expect(plan(state: state(["c1": [.pinned, .cannotPin]])).pin == .unpin)
        #expect(plan(state: state(["c1": .cannotPin])).pin == nil)
        // "Khác" while pinning there is off: neither item.
        #expect(plan(state: state(["c1": [.archived, .noPinMenu, .pinned]])).pin == nil)
    }

    @Test func archiveItem() {
        #expect(plan(state: state(["c1": .archived])).archive == .moveToFocus)
        #expect(plan(state: state(["c1": .cannotArchive])).archive == nil)
    }

    @Test func readItem() {
        let s = state()
        #expect(plan(state: s, unread: 3).read == .markRead)
        #expect(plan(state: state(["c1": .unreadMark])).read == .markRead)
        #expect(plan(state: s).read == .markUnread)
        #expect(plan(state: state(markUnread: false)).read == nil)
        // Not for hidden chats and not for My Cloud.
        #expect(plan(state: state(["c1": .hidden]), unread: 2).read == nil)
        #expect(plan("me", state: state(["me": .cannotDelete]), unread: 2).read == nil)
    }

    @Test func muteItem() {
        #expect(plan(state: state(["c1": .cannotMute])).mute == nil)
        // A muted conversation can always be un-muted.
        #expect(plan(state: state(["c1": .cannotMute]), muted: true).mute == .unmute)
        #expect(plan(state: state(), muted: true).mute == .unmute)
    }

    @Test func hideItem() {
        #expect(plan(state: state(["c1": .cannotHide])).hide == nil)
        #expect(plan(state: state(["c1": .hidden])).hide == .unhide)
        // Official: an OA / My Cloud gets no hide item, a hidden one still gets unhide.
        #expect(plan(state: state(["c1": [.hidden, .cannotHide]])).hide == .unhide)
        #expect(plan(state: state(hidden: false)).hide == nil)
    }

    @Test func myCloudCannotBeDeleted() {
        let p = plan("me", state: state(["me": [.cannotDelete, .cannotMute, .cannotHide]]))
        #expect(!p.canDelete && p.mute == nil && p.hide == nil)
    }

    @Test func leftGroupOffersOnlyDelete() {
        let s = state(["g1": []], left: ["g1": .kick])
        let thread = plan("g1", state: s)
        #expect(thread.canDelete && thread.pin == nil && thread.archive == nil && thread.mute == nil && thread.hide == nil && !thread.showsLabel)
        #expect(plan("g1", .chatBox, state: s).isEmpty)
    }

    @Test func chatBoxPresetHasNoArchiveReadOrDelete() {
        let p = plan("c1", .chatBox, state: state(), unread: 4)
        #expect(p.archive == nil && p.read == nil && !p.canDelete)
        #expect(p.pin == .pin && p.mute == .mute && p.hide == .hide && p.showsLabel)
    }

    // MARK: hidden-chat lock (the bypass belongs to the one conversation opened with the PIN)

    @Test func unlockIsScopedToOneConversation() {
        let engine = ZaloEngine()
        engine.conversationActions.apply(json: ["hidden": ["enabled": true, "hasPin": true, "ids": ["h1", "h2"]]])
        #expect(engine.isConversationLocked("h1") && engine.isConversationLocked("h2") && !engine.isConversationLocked("c1"))
        // A PIN search lists the hidden chats but opens none of them.
        engine.conversationUI.setPinSearch(["h1", "h2"])
        #expect(engine.isConversationLocked("h1") && engine.isConversationLocked("h2"))
        // Opening one result unlocks that one only.
        #expect(engine.unlockFromPINSearch("h1"))
        #expect(!engine.isConversationLocked("h1") && engine.isConversationLocked("h2"))
        // A conversation that was not in the search results can't be unlocked this way.
        #expect(!engine.unlockFromPINSearch("h3"))
        // Moving on to another conversation drops it.
        engine.conversationUI.dropUnlock()
        #expect(engine.isConversationLocked("h1"))
    }

    @Test func newUnlockReplacesTheOldOne() {
        let engine = ZaloEngine()
        engine.conversationActions.apply(json: ["hidden": ["enabled": true, "hasPin": true, "ids": ["h1", "h2"]]])
        engine.unlockHiddenConversation("h1")
        engine.unlockHiddenConversation("h2")
        #expect(engine.isConversationLocked("h1") && !engine.isConversationLocked("h2"))
    }

    @Test func relockClearsUnlockAndSearch() {
        let engine = ZaloEngine()
        engine.conversationActions.apply(json: ["hidden": ["enabled": true, "hasPin": true, "ids": ["h1"]]])
        engine.conversationUI.setPinSearch(["h1"])
        _ = engine.unlockFromPINSearch("h1")
        engine.conversationUI.relock()
        #expect(engine.isConversationLocked("h1") && engine.conversationUI.pinSearchIds.isEmpty)
    }

    @Test func hidingRemovesTheUnlock() {
        let ui = ConversationActionUI()
        ui.unlock("c1")
        ui.remove(["c1"])
        #expect(!ui.isUnlocked("c1") && ui.removal?.ids == ["c1"])
    }

    @Test func logoutResetsEverything() {
        let engine = ZaloEngine()
        engine.conversationActions.apply(json: ["flags": ["a": 1], "hidden": ["enabled": true, "hasPin": true, "ids": ["h1"]]])
        engine.conversationPrompt = .hide(id: "a")
        engine.unlockHiddenConversation("h1")
        engine.conversationUI.show(.success, "x")
        engine.conversationUI.remove(["h1"])
        engine.resetConversationActions()
        #expect(engine.conversationActions == ConversationActionsState())
        #expect(engine.conversationPrompt == nil)
        #expect(engine.conversationUI.unlockedId == nil && engine.conversationUI.toast == nil && engine.conversationUI.removal == nil)
    }

    @Test func resettingThePINRemovesEveryFormerlyHiddenChat() {
        let ui = ConversationActionUI()
        ui.unlock("h1")
        // What `resetHiddenChatPIN` does after the page confirmed: remove all former hidden ids, relock.
        ui.remove(["h1", "h2", "g3"])
        ui.relock()
        #expect(ui.removal?.ids == ["h1", "h2", "g3"] && ui.unlockedId == nil)
    }

    @Test func lateOutcomeIsReportedOnce() {
        let engine = ZaloEngine()
        let late: [String: Any] = ["seq": 1, "ok": true, "text": "Đã chuyển sang mục Khác", "neutral": true, "removedId": ""]
        engine.handleConversationActions(state: ["convActions": ["hidden": ["enabled": false, "hasPin": false, "ids": [String]()], "late": late]])
        #expect(engine.conversationUI.toast?.kind == .neutral && engine.conversationActions.lateSeq == 1)
        let seq = engine.conversationUI.toast?.seq
        engine.handleConversationActions(state: ["convActions": ["late": late]])
        #expect(engine.conversationUI.toast?.seq == seq)
        let deleted: [String: Any] = ["seq": 2, "ok": true, "text": "", "removedId": "c9"]
        engine.handleConversationActions(state: ["convActions": ["late": deleted]])
        #expect(engine.conversationUI.removal?.ids == ["c9"])
    }

    @Test func contactsAndMutesHideHiddenChats() {
        let engine = ZaloEngine()
        #expect(engine.visibleFriends.isEmpty)   // unknown hidden state: nothing leaks
        engine.conversationActions.apply(json: ["hidden": ["enabled": true, "hasPin": true, "ids": ["h1"]]])
        #expect(engine.visibleFriends.isEmpty && engine.visibleGroups.isEmpty)
    }

    // MARK: results

    @Test func actionResultParsing() {
        let ok = ConversationActionResult(json: ["ok": true, "text": "Ghim hội thoại thành công"])
        #expect(ok.ok && ok.text == "Ghim hội thoại thành công" && !ok.full)
        let full = ConversationActionResult(json: ["ok": false, "full": true, "text": ""])
        #expect(!full.ok && full.full)
        let bad = ConversationActionResult(json: ["ok": false, "badPin": true, "text": "x"])
        #expect(bad.badPIN)
        let stale = ConversationActionResult(json: ["ok": false, "pinExists": true, "text": ""])
        #expect(stale.pinExists && !stale.ok)
        #expect(ConversationActionResult(json: ["ok": true, "neutral": true, "text": "x"]).neutral)
        #expect(!ConversationActionResult(json: nil).ok)
        #expect(!ConversationActionResult(json: ["text": "no ok field"]).ok)
    }

    @Test func pinBoardParsing() {
        let board = PinBoard(json: ["tab": 0, "limit": 5, "total": 5, "need": 1, "items": ["a", "b", "c", "d", "e"]])
        #expect(board != nil)
        #expect(board?.items.count == 5)
        // Confirm needs at least one removal (official `isChanged`).
        #expect(board?.freesSlot(removing: 0) == false)
        #expect(board?.freesSlot(removing: 1) == true)
        #expect(PinBoard(json: ["limit": 0]) == nil && PinBoard(json: nil) == nil)
    }

    // MARK: mute status line

    @Test func muteStatusText() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let soon = MuteInfo(startTime: now.timeIntervalSince1970, duration: 1800)
        #expect(soon.statusText(now: now, calendar: cal).hasPrefix("Đang tắt đến "))
        #expect(!soon.statusText(now: now, calendar: cal).contains("Cho đến"))
        #expect(MuteInfo(startTime: 0, duration: -1).statusText(now: now, calendar: cal) == "Đang tắt cho đến khi được mở lại")
        #expect(MuteDuration.until8AM.title == "Cho đến 8:00 AM")
    }

    // MARK: hidden-chat flow (official SCREEN_POPUP_HIDDEN_CHAT)

    @Test func hideWithoutPINStartsWithIntroduction() {
        var flow = HiddenChatFlow(kind: .hide("c1"), hasPIN: false)
        #expect(flow.screen == .introduce && flow.title == "Ẩn trò chuyện")
        flow.startSettingPIN()
        #expect(flow.screen == .createPIN && flow.takesPIN)
        #expect(flow.submit(pin: "1234") == .none)
        #expect(flow.screen == .confirmPIN)
        // Mismatch stays on the confirmation with the official error.
        #expect(flow.submit(pin: "4321") == .none)
        #expect(flow.screen == .confirmPIN && flow.error == "Mã PIN không đúng. Vui lòng thử lại.")
        #expect(flow.submit(pin: "1234") == .hideWithNewPIN(pin: "1234"))
        #expect(flow.succeeded() && flow.screen == .hideSuccess)
    }

    @Test func hideWithPINAsksForIt() {
        var flow = HiddenChatFlow(kind: .hide("c1"), hasPIN: true)
        #expect(flow.screen == .enterPIN && flow.title == "Nhập mã PIN để ẩn trò chuyện")
        #expect(flow.submit(pin: "0000") == .hide(pin: "0000"))
        flow.fail(HiddenChatFlow.wrongPIN)
        #expect(flow.error == HiddenChatFlow.wrongPIN)
    }

    @Test func stalePINNeverOverwritesTheExistingOne() {
        // Hide flow built while the app believed there was no PIN, but the page says one exists: ask for it.
        var flow = HiddenChatFlow(kind: .hide("c1"), hasPIN: false)
        flow.startSettingPIN()
        _ = flow.submit(pin: "1234")
        #expect(flow.submit(pin: "1234") == .hideWithNewPIN(pin: "1234"))
        flow.pinAlreadyExists()
        #expect(flow.screen == .enterPIN && flow.error == nil)
        // From Settings there is no hide: it says to use "Đổi mã PIN".
        var settings = HiddenChatFlow(kind: .setPIN, hasPIN: false)
        _ = settings.submit(pin: "1234")
        _ = settings.submit(pin: "1234")
        settings.pinAlreadyExists()
        #expect(settings.error == HiddenChatFlow.pinAlreadySet)
    }

    @Test func unhideRespectsBypass() {
        #expect(HiddenChatFlow(kind: .unhide("c1", requiresPIN: true), hasPIN: true).screen == .enterPIN)
        #expect(HiddenChatFlow(kind: .unhide("c1", requiresPIN: false), hasPIN: true).screen == .unhideConfirm)
        var flow = HiddenChatFlow(kind: .unhide("c1", requiresPIN: true), hasPIN: true)
        #expect(flow.submit(pin: "1111") == .unhide(pin: "1111"))
    }

    @Test func openingAHiddenChatVerifiesThePIN() {
        var flow = HiddenChatFlow(kind: .open("c1"), hasPIN: true)
        #expect(flow.title == "Nhập mã PIN để mở trò chuyện")
        #expect(flow.submit(pin: "2222") == .verifyToOpen(pin: "2222"))
    }

    @Test func changePINFlow() {
        var flow = HiddenChatFlow(kind: .changePIN, hasPIN: true)
        #expect(flow.screen == .oldPIN)
        #expect(flow.submit(pin: "1234") == .verifyOld(pin: "1234"))
        flow.oldPINVerified()
        #expect(flow.screen == .newPIN)
        #expect(flow.submit(pin: "5678") == .none && flow.screen == .repeatPIN)
        #expect(flow.submit(pin: "0000") == .none && flow.error != nil)
        flow.back()
        #expect(flow.screen == .newPIN && flow.error == nil)
        _ = flow.submit(pin: "5678")
        #expect(flow.submit(pin: "5678") == .setPIN(pin: "5678", changed: true))
        #expect(flow.succeeded() && flow.screen == .changeSuccess)
    }

    @Test func settingFirstPINFromSettings() {
        var flow = HiddenChatFlow(kind: .setPIN, hasPIN: false)
        #expect(flow.screen == .createPIN)
        _ = flow.submit(pin: "9999")
        #expect(flow.submit(pin: "9999") == .setPIN(pin: "9999", changed: false))
        #expect(flow.succeeded() && flow.screen == .setPINSuccess)
        #expect(HiddenChatFlow(kind: .resetPIN, hasPIN: true).screen == .resetConfirm)
    }
}

// MARK: - Hidden-state gating in the real adapter (JavaScriptCore, fake official modules)

import JavaScriptCore

@Suite @MainActor struct HiddenLockTimingTests {
    @Test func stallIsDeclaredAfterTheLimit() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(!HiddenStateGuard.isStalled(waitingSince: nil, now: start))
        #expect(!HiddenStateGuard.isStalled(waitingSince: start, now: start.addingTimeInterval(HiddenStateGuard.stallLimit - 1)))
        #expect(HiddenStateGuard.isStalled(waitingSince: start, now: start.addingTimeInterval(HiddenStateGuard.stallLimit)))
        #expect(HiddenStateGuard.stalledMessage == "Không đọc được trạng thái trò chuyện ẩn — đang thử lại")
    }

    @Test func stalledStateKeepsEverythingLocked() {
        let engine = ZaloEngine()
        // Never published: nothing is known, nothing is visible, nothing is counted.
        #expect(!engine.conversationActions.hiddenKnown)
        #expect(engine.visibleFriends.isEmpty && engine.visibleGroups.isEmpty && engine.visibleConversations.isEmpty)
    }

    @Test func relockOnlyAfterARealAbsence() {
        // The ZaloCall helper taking focus is a short focus loss.
        #expect(!HiddenStateGuard.shouldRelock(inactiveFor: 5))
        #expect(!HiddenStateGuard.shouldRelock(inactiveFor: 59.9))
        #expect(HiddenStateGuard.shouldRelock(inactiveFor: 60))
    }

    @Test func newPageEpochRestartsTheLateSequence() {
        let engine = ZaloEngine()
        func late(epoch: Int, seq: Int, text: String) -> [String: Any] {
            ["convActions": ["epoch": epoch, "hidden": ["enabled": false, "hasPin": false, "ids": [String]()],
                             "late": ["seq": seq, "ok": true, "text": text, "removedId": ""]]]
        }
        engine.handleConversationActions(state: late(epoch: 100, seq: 1, text: "một"))
        #expect(engine.conversationUI.toast?.text == "một")
        // The same epoch and seq again (a replay): ignored.
        engine.handleConversationActions(state: late(epoch: 100, seq: 1, text: "lặp"))
        #expect(engine.conversationUI.toast?.text == "một")
        // The page reloaded: its seq starts at 1 again but the epoch differs.
        engine.handleConversationActions(state: late(epoch: 200, seq: 1, text: "hai"))
        #expect(engine.conversationUI.toast?.text == "hai")
    }

    @Test func lockedChatRefusesBannerReplies() {
        #expect(NotificationPolicy.refusesReply(hiddenStateKnown: false, conversationLocked: false))
        #expect(NotificationPolicy.refusesReply(hiddenStateKnown: true, conversationLocked: true))
        #expect(!NotificationPolicy.refusesReply(hiddenStateKnown: true, conversationLocked: false))
    }

    @Test func newlyHiddenChatsLoseTheirBanners() {
        #expect(NotificationPolicy.newlyHidden(old: ["a"], new: ["a", "b", "g1"]) == ["b", "g1"])
        #expect(NotificationPolicy.newlyHidden(old: ["a"], new: []).isEmpty)
    }
}
