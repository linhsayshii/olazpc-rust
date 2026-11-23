import Foundation
import OlazCore

/// Typed bridge between the Rust core's `ChatMessageRecord` and `ChatMessage` (ADR-011): a field-by-field copy, no JSON.
/// Equivalent to `ChatMessage(json:)` over the canonical stored JSON (the Rust parser already applied the same
/// filtering); URLs go through `URL(string:)` exactly as `ChatMessage.Kind(json:)` does.
extension ChatMessage {
    init(record r: ChatMessageRecord) {
        func url(_ s: String?) -> URL? { s.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        self.init(
            id: r.id,
            conversationId: r.conversationId,
            senderId: r.senderId,
            senderName: r.senderName,
            senderAvatar: url(r.senderAvatar),
            isMine: r.isMine,
            kind: Kind(record: r.kind),
            text: r.text,
            date: Date(timeIntervalSince1970: Double(r.dateMs) / 1000),
            status: Status(record: r.status),
            quote: r.quote.map { Quote(senderName: $0.senderName, text: $0.text) },
            reactions: r.reactions.map { x in
                var counts: [String: Int] = [:]
                counts.reserveCapacity(x.userCounts.count)
                for u in x.userCounts { counts[u.uid] = Int(u.count) }
                return Reaction(
                    icon: ReactionIcon(type: x.icon.kind, key: x.icon.key, emoji: x.icon.emoji, image: x.icon.image),
                    count: Int(x.count), includesMe: x.includesMe, names: x.names, people: Int(x.people), userCounts: counts)
            },
            isE2EE: r.isE2ee,
            mentions: r.mentions.map { Mention(uid: $0.uid, pos: Int($0.pos), len: Int($0.len), isAll: $0.isAll) },
            cardButtons: r.cardButtons.map { CardButton(ref: $0.reference, label: $0.label, enabled: $0.enabled, help: $0.help) },
            suggestsStickers: r.suggestsStickers,
            menu: MessageMenu(record: r.menu),
            fallbackURLs: r.fallbackUrls.compactMap { URL(string: $0) },
            clientId: r.clientId
        )
    }
}

extension ChatMessage.Status {
    init(record: StatusRecord) {
        switch record {
        case .sending: self = .sending
        case .sent: self = .sent
        case .delivered: self = .delivered
        case .seen: self = .seen
        case .failed: self = .failed
        }
    }

    var record: StatusRecord {
        switch self {
        case .sending: .sending
        case .sent: .sent
        case .delivered: .delivered
        case .seen: .seen
        case .failed: .failed
        }
    }
}

extension MessageMenu {
    init(record m: MenuRecord) {
        self.init()
        switch m.forward {
        case .hidden: forward = .hidden
        case .available: forward = .available
        case .blocked: forward = .blocked
        }
        recall = m.recall
        delete = m.delete.map { $0 == .plain ? .plain : .forMe }
        pin = m.pin
        star = m.star.map { s in
            switch s {
            case .star: .star
            case .unstar: .unstar
            case .blocked: .blocked
            }
        }
        starred = m.starred
        pinned = m.pinned
        isProtected = m.isProtected
    }

    var record: MenuRecord {
        MenuRecord(
            forward: { switch forward { case .hidden: .hidden; case .available: .available; case .blocked: .blocked } }(),
            recall: recall,
            delete: delete.map { $0 == .plain ? .plain : .forMe },
            pin: pin,
            star: star.map { s in switch s { case .star: .star; case .unstar: .unstar; case .blocked: .blocked } },
            starred: starred, pinned: pinned, isProtected: isProtected)
    }
}

extension ChatMessage.Kind {
    init(record k: KindRecord) {
        func url(_ s: String?) -> URL? { s.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        switch k {
        case .text: self = .text
        case .photo(let u, let w, let h): self = .photo(url: url(u), width: Int(w), height: Int(h))
        case .sticker(let u): self = .sticker(url: url(u))
        case .gif(let u): self = .gif(url: url(u))
        case .video(let t, let d, let u): self = .video(thumbnail: url(t), duration: Int(d), url: url(u))
        case .voice(let u, let d): self = .voice(url: url(u), duration: Int(d))
        case .file(let n, let s, let u): self = .file(name: n, size: s, url: url(u))
        case .link(let title, let u, let t, let d, let s):
            self = .link(title: title, url: WebLink.sanitized(url(u)), thumbnail: url(t), description: d, source: s)
        case .contactCard(let c):
            self = .contactCard(ChatMessage.ContactCard(
                name: c.name, uid: c.uid, avatar: url(c.avatar), phone: c.phone, qr: url(c.qr), oaLink: c.oaLink,
                isOfficialAccount: c.isOfficialAccount))
        case .location(let l):
            var info = ChatMessage.LocationInfo(title: l.title, address: l.address, thumbnail: url(l.thumbnail))
            if let c = l.coordinate { info.coordinate = .init(latitude: c.latitude, longitude: c.longitude) }
            self = .location(info)
        case .call(let video, let missed, let d, let title, let detail):
            self = .call(video: video, missed: missed, duration: Int(d), title: title, detail: detail)
        case .ecard(let e):
            var card = ChatMessage.ECard()
            switch e.style {
            case .banner: card.style = .banner
            case .friend: card.style = .friend
            case .birthday: card.style = .birthday
            case .reminder: card.style = .reminder
            }
            card.image = url(e.image)
            card.thumb = url(e.thumb)
            card.title = e.title
            card.description = e.description
            card.actions = e.actions
            card.avatars = e.avatars.compactMap { url($0) }
            card.reminderTitle = e.reminderTitle
            card.reminderStart = e.reminderStartMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            card.reminderRepeat = e.reminderRepeat
            self = .ecard(card)
        case .oaMessage(let parts):
            self = .oaMessage(parts.map {
                ChatMessage.OAPart(
                    isHeader: $0.isHeader, title: $0.title, description: $0.description, thumb: url($0.thumb),
                    url: WebLink.sanitized(url($0.url)), help: $0.help)
            })
        case .poll(let p):
            self = .poll(ChatMessage.PollInfo(
                question: p.question, header: p.header, anonymous: p.anonymous, pollId: p.pollId, conversationId: p.conversationId))
        case .stickerSet(let t, let th): self = .stickerSet(title: t, thumbnail: url(th))
        case .zinstant(let t, let x, let th): self = .zinstant(title: t, text: x, thumbnail: url(th))
        case .notice(let s, let t): self = .notice(symbol: s, text: t)
        case .placeholder(let s, let t): self = .placeholder(symbol: s, text: t)
        case .system: self = .system
        case .recalled: self = .recalled
        case .unsupported(let raw): self = .unsupported(type: raw)
        }
    }

    var record: KindRecord {
        func s(_ u: URL?) -> String? { u?.absoluteString }
        switch self {
        case .text: return .text
        case .photo(let u, let w, let h): return .photo(url: s(u), width: Int64(w), height: Int64(h))
        case .sticker(let u): return .sticker(url: s(u))
        case .gif(let u): return .gif(url: s(u))
        case .video(let t, let d, let u): return .video(thumbnail: s(t), duration: Int64(d), url: s(u))
        case .voice(let u, let d): return .voice(url: s(u), duration: Int64(d))
        case .file(let n, let sz, let u): return .file(name: n, size: sz, url: s(u))
        case .link(let title, let u, let t, let d, let src):
            return .link(title: title, url: s(u), thumbnail: s(t), description: d, source: src)
        case .contactCard(let c):
            return .contactCard(card: ContactCardRecord(
                name: c.name, uid: c.uid, avatar: s(c.avatar), phone: c.phone, qr: s(c.qr), oaLink: c.oaLink,
                isOfficialAccount: c.isOfficialAccount))
        case .location(let l):
            return .location(info: LocationRecord(
                title: l.title, address: l.address,
                coordinate: l.coordinate.map { CoordinateRecord(latitude: $0.latitude, longitude: $0.longitude) },
                thumbnail: s(l.thumbnail)))
        case .call(let video, let missed, let d, let title, let detail):
            return .call(video: video, missed: missed, duration: Int64(d), title: title, detail: detail)
        case .ecard(let e):
            let style: ECardStyleRecord
            switch e.style {
            case .banner: style = .banner
            case .friend: style = .friend
            case .birthday: style = .birthday
            case .reminder: style = .reminder
            }
            return .ecard(card: ECardRecord(
                style: style, image: s(e.image), thumb: s(e.thumb), title: e.title, description: e.description,
                actions: e.actions, avatars: e.avatars.map(\.absoluteString), reminderTitle: e.reminderTitle,
                reminderStartMs: e.reminderStart.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                reminderRepeat: e.reminderRepeat))
        case .oaMessage(let parts):
            return .oaMessage(parts: parts.map {
                OaPartRecord(isHeader: $0.isHeader, title: $0.title, description: $0.description, thumb: s($0.thumb), url: s($0.url), help: $0.help)
            })
        case .poll(let p):
            return .poll(poll: PollRecord(
                question: p.question, header: p.header, anonymous: p.anonymous, pollId: p.pollId, conversationId: p.conversationId))
        case .stickerSet(let t, let th): return .stickerSet(title: t, thumbnail: s(th))
        case .zinstant(let t, let x, let th): return .zinstant(title: t, text: x, thumbnail: s(th))
        case .notice(let sym, let t): return .notice(symbol: sym, text: t)
        case .placeholder(let sym, let t): return .placeholder(symbol: sym, text: t)
        case .system: return .system
        case .recalled: return .recalled
        case .unsupported(let raw): return .unsupported(rawType: raw)
        }
    }
}

extension ChatMessageRecord {
    /// Swift -> core direction (for `CoreStore.saveChatMessages`).
    init(message m: ChatMessage) {
        self.init(
            id: m.id, conversationId: m.conversationId, senderId: m.senderId, senderName: m.senderName,
            senderAvatar: m.senderAvatar?.absoluteString, isMine: m.isMine, kind: m.kind.record, text: m.text,
            dateMs: Int64((m.date.timeIntervalSince1970 * 1000).rounded()), status: m.status.record,
            quote: m.quote.map { QuoteRecord(senderName: $0.senderName, text: $0.text) },
            reactions: m.reactions.map { r in
                ReactionRecord(
                    icon: ReactionIconRecord(kind: r.icon.type, key: r.icon.key, emoji: r.icon.emoji, image: r.icon.image),
                    count: Int64(r.count), includesMe: r.includesMe, names: r.names, people: Int64(r.people),
                    userCounts: r.userCounts.sorted { $0.key < $1.key }.map { UserCountRecord(uid: $0.key, count: Int64($0.value)) })
            },
            isE2ee: m.isE2EE,
            mentions: m.mentions.map { MessageMention(uid: $0.uid, pos: Int64($0.pos), len: Int64($0.len), isAll: $0.isAll) },
            cardButtons: m.cardButtons.map { CardButtonRecord(reference: $0.ref, label: $0.label, enabled: $0.enabled, help: $0.help) },
            suggestsStickers: m.suggestsStickers, menu: m.menu.record, fallbackUrls: m.fallbackURLs.map(\.absoluteString),
            clientId: m.clientId)
    }
}
