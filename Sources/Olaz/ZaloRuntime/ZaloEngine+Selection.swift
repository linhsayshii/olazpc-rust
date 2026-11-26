import Foundation
import OlazCore

/// "Chọn nhiều tin nhắn" (official `STR_SELECT`): the messages picked in one conversation, in the order they were picked.
struct MessageSelection: Equatable {
    var conversationId: String
    var ids: [String] = []
    /// The last row clicked without SHIFT: a SHIFT click selects every row between it and the clicked one.
    var anchor: String?

    /// Official limit of the multi-select bar (`max_select_msg`).
    static let limit = 100

    func contains(_ id: String) -> Bool { ids.contains(id) }
}

extension ChatMessage {
    /// Messages that take part in "Chọn nhiều tin nhắn": not info lines, poll events or pending sends.
    var isSelectable: Bool {
        !kind.isStandalone && status != .sending
    }
}

extension ZaloEngine {
    func beginSelection(_ message: ChatMessage) {
        var selection = MessageSelection(conversationId: message.conversationId)
        if message.isSelectable {
            selection.ids = [message.id]
            selection.anchor = message.id
        }
        messageSelection = selection
    }

    func endSelection() {
        messageSelection = nil
    }

    /// A click on a row while selecting. With `range`, selects every selectable message from the anchor to `id`.
    func toggleSelection(_ id: String, range: Bool = false) {
        guard var selection = messageSelection,
              let list = messages[selection.conversationId],
              let target = list.firstIndex(where: { $0.id == id }), list[target].isSelectable else { return }
        if range, let anchor = selection.anchor, let from = list.firstIndex(where: { $0.id == anchor }) {
            let span = list[min(from, target)...max(from, target)].filter(\.isSelectable).map(\.id)
            for item in span where !selection.ids.contains(item) && selection.ids.count < MessageSelection.limit {
                selection.ids.append(item)
            }
        } else if let at = selection.ids.firstIndex(of: id) {
            selection.ids.remove(at: at)
            selection.anchor = id
        } else {
            guard selection.ids.count < MessageSelection.limit else {
                showActionCard("Bạn chỉ có thể chọn tối đa \(MessageSelection.limit) tin nhắn", in: selection.conversationId)
                return
            }
            selection.ids.append(id)
            selection.anchor = id
        }
        messageSelection = selection
    }

    /// The selected messages still in the conversation, oldest first.
    func selectedMessages() -> [ChatMessage] {
        guard let selection = messageSelection, let list = messages[selection.conversationId] else { return [] }
        let ids = Set(selection.ids)
        return list.filter { ids.contains($0.id) }
    }

    /// "Thu hồi" is offered only when every selected message is the user's own, recallable and under 24 hours old.
    func selectionCanRecall(_ list: [ChatMessage]) -> Bool {
        let now = Date(timeIntervalSince1970: Double(nowMs()) / 1000.0)
        return !list.isEmpty && list.allSatisfy {
            $0.isMine && $0.menu.recall && $0.kind != .recalled && now.timeIntervalSince($0.date) < 86_400
        }
    }

    func selectionCanForward(_ list: [ChatMessage]) -> Bool {
        !list.isEmpty && list.allSatisfy { $0.menu.forward == .available }
    }

    func forwardSelection() {
        let list = selectedMessages()
        guard let first = list.first else { return }
        if let core = coreLifecycle.core {
            core.forwardSelection(messages: list.map(ChatMessageRecord.init(message:)))
            return
        }
        guard selectionCanForward(list) else {
            showActionCard("Có tin nhắn không thể chia sẻ", in: first.conversationId)
            return
        }
        forwardRequest = ForwardRequest(conversationId: first.conversationId, message: first, more: Array(list.dropFirst()))
    }

    func recallSelection() {
        let list = selectedMessages()
        guard let first = list.first, selectionCanRecall(list) else { return }
        let confirm = MessageActionConfirm(
            conversationId: first.conversationId,
            action: .recallMany(list),
            title: "Thu hồi tin nhắn",
            message: "Thu hồi các tin nhắn đã chọn cho tất cả mọi người?",
            ok: "Thu hồi",
            destructive: true
        )
        if let core = coreLifecycle.core {
            if openConversationId == confirm.conversationId, messageConfirm == nil {
                mirroredMessageConfirmCoreId = nil
                messageConfirm = confirm
            }
            core.recallMany(
                convId: first.conversationId,
                msgIds: list.map(\.id),
                confirm: true,
                nowMs: nowMs()
            )
            return
        }
        ask(confirm)
    }

    func deleteSelection() {
        let list = selectedMessages()
        guard let first = list.first else { return }
        let confirm = MessageActionConfirm(
            conversationId: first.conversationId,
            action: .deleteMany(list),
            title: "Xóa tin nhắn",
            message: "Xóa các tin nhắn đã chọn chỉ ở phía bạn?",
            ok: "Xóa chỉ ở phía tôi",
            destructive: true
        )
        if let core = coreLifecycle.core {
            if openConversationId == confirm.conversationId, messageConfirm == nil {
                mirroredMessageConfirmCoreId = nil
                messageConfirm = confirm
            }
            core.deleteMany(
                convId: first.conversationId,
                msgIds: list.map(\.id),
                confirm: true,
                nowMs: nowMs()
            )
            return
        }
        ask(confirm)
    }

    func recallMessages(_ list: [ChatMessage]) {
        endSelection()
        if let core = coreLifecycle.core {
            guard let convId = list.first?.conversationId else { return }
            let tsMs = nowMs()
            let ids = list.map(\.id)
            trackMessageActionTask { [weak self] in
                guard let self else { return }
                if let v = try? await core.recallManyAsync(convId: convId, msgIds: ids, nowMs: tsMs) {
                    await self.waitForMirrorVersion(v)
                }
            }
            return
        }
        trackMessageActionTask { [weak self] in
            guard let self else { return }
            for message in list { await self.performRecall(message) }
        }
    }
}
