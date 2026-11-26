import Foundation
import OlazCore

// Friends, groups, friend requests, add friend — thin `@Observable` mirror over `olaz-core` (U9).

struct ContactsState: Equatable {
    struct Friend: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let zaloName: String
        let avatar: URL?
        /// Last activity reported by the official profile, nil when unknown.
        let lastActive: Date?
        let online: Bool
        /// Upper-case Latin initial used for the alphabetical sections ("#" when not a letter).
        let section: String
        /// Diacritic-folded lowercase name for sorting and searching.
        let sortKey: String
    }

    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let avatar: URL?
        let members: Int
        let sortKey: String
    }

    struct FriendRequest: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let avatar: URL?
        let message: String
        /// nil when the official client has no timestamp for the request.
        let date: Date?
    }

    struct FoundUser: Equatable, Sendable {
        let id: String
        let name: String
        let zaloName: String
        let avatar: URL?
        let bio: String
        let isFriend: Bool
        let isSelf: Bool
        /// I already sent this person a request.
        var requested: Bool
        /// This person already sent me a request.
        let requesting: Bool
        /// Official default greeting for "find by phone" (editable by the user).
        let defaultMessage: String
        let maxMessage: Int
    }

    struct Search: Equatable, Sendable {
        enum Status: String, Sendable { case idle, searching, found, error }
        var status: Status = .idle
        var error: String?
        var user: FoundUser?
    }

    /// Result of the latest accept / decline / cancel / send action.
    struct Notice: Equatable, Sendable {
        let seq: Int
        let ok: Bool
        let text: String
    }

    var friends: [Friend] = []
    var groups: [Group] = []
    var received: [FriendRequest] = []
    var sent: [FriendRequest] = []
    /// Pending received friend requests (rail badge).
    var pendingRequestCount = 0
    var loadingRequests = false
    var search = Search()
    var notice: Notice?
    /// True once the official friend list has been read at least once.
    var friendsLoaded = false
    var groupsLoaded = false
}

extension ZaloEngine {
    // MARK: Actions (delegated to `olaz-core`)

    func refreshContacts() {
        trackContactsTask { [weak self] in
            await self?.performContactsSync()
        }
    }

    func performContactsSync() async {
        guard let core = await ensureCoreEngine() else { return }
        if let v = try? await core.performContactsSync() {
            await waitForMirrorVersion(v)
        }
    }

    func acceptFriendRequest(_ id: String) {
        trackContactsTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.acceptFriendRequestAndWait(uid: id) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    func declineFriendRequest(_ id: String) {
        trackContactsTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.declineFriendRequestAndWait(uid: id) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    func cancelFriendRequest(_ id: String) {
        trackContactsTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.cancelFriendRequestAndWait(uid: id) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    func findFriend(byPhone phone: String) {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        trackContactsTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.findFriendByPhoneAndWait(phone: trimmed) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    func resetFriendSearch() {
        if let core = coreLifecycle.core {
            core.resetFriendSearch()
            trackContactsTask { [weak self] in
                guard let self else { return }
                if let v = try? await core.settle() {
                    await self.waitForMirrorVersion(v)
                }
            }
        }
        if contacts.search != ContactsState.Search() {
            isApplyingCoreMirror = true
            contacts.search = ContactsState.Search()
            isApplyingCoreMirror = false
        }
    }

    func sendFriendRequest(to id: String, message: String) {
        trackContactsTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.sendFriendRequestAndWait(uid: id, message: message) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    /// Opens the 1-1 or group conversation with `id` (the shell observes `navigationRequest`).
    func openContactConversation(_ id: String) { navigationRequest = id }

    // MARK: State

    func handleContacts(state: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state),
              let jsonText = String(data: data, encoding: .utf8) else {
            return
        }
        if let core = coreLifecycle.core {
            core.handleContactsState(stateJson: jsonText)
            trackContactsTask { [weak self] in
                guard let self else { return }
                if let v = try? await core.settle() {
                    await self.waitForMirrorVersion(v)
                }
            }
            return
        }
        guard let json = state["contacts"] as? [String: Any] else { return }
        if let count = (json["pendingRequestCount"] as? NSNumber)?.intValue {
            contacts.pendingRequestCount = max(0, count)
        }
    }

    /// Lower-cased, diacritic-folded text (Vietnamese đ/Đ included) delegated to `olaz-core`.
    nonisolated static func contactFold(_ text: String) -> String {
        contactFoldFfi(text: text)
    }

    /// Name an @mention of `uid` shows (official `getMemberFriendlyName` -> `getDName`: alias, else the Zalo name);
    /// nil keeps the text as sent (me, everyone, or nobody known).
    func mentionDisplayName(_ uid: String) -> String? {
        if let core = coreLifecycle.core {
            return core.mentionDisplayName(uid: uid)
        }
        let clean = ZaloWireParser.stripUserPrefix(uid)
        let cleanMy = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let sanitizedMy = ZaloWireParser.sanitizeProfileUid(cleanMy) ?? cleanMy
        let sanitizedClean = ZaloWireParser.sanitizeProfileUid(clean) ?? clean
        guard !clean.isEmpty, clean != "-1",
              cleanMy.isEmpty || (clean != cleanMy && sanitizedClean != sanitizedMy),
              let name = lookupPersonInfo(clean)?.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != clean, name != "Bạn", name != ReactionDetail.unknownName else { return nil }
        return name
    }
}
