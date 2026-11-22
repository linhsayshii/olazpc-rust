import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Olaz

@MainActor
struct GroupComposeModelTests {
    @Test func limitsParseTheAdapterAnswer() {
        let limits = GroupCreateLimits(json: ["status": "ok", "maxMembers": 50, "maxNameLength": 30, "nameRegex": "x", "blocked": ["9"],
                                              "officialAccounts": ["8"]])
        #expect(limits?.maxMembers == 50)
        #expect(limits?.maxNameLength == 30)
        #expect(limits?.namePattern == "x")
        #expect(limits?.blocked == ["9"])
        #expect(limits?.officialAccounts == ["8"])
        #expect(GroupCreateLimits(json: ["status": "not-ready"]) == nil)
    }

    @Test func nameRulesFollowTheOfficialInput() {
        let limits = GroupCreateLimits()
        #expect(limits.isValidName("Gia đình 2026"))
        #expect(limits.isValidName(""))
        for bad in ["a`b", "~", "x!", "@team", "#1", "100%", "a*b", "a^b", "$"] { #expect(!limits.isValidName(bad), "\(bad)") }
        #expect(limits.clampedName(String(repeating: "á", count: 60)).utf16.count == 50)
        // An emoji is two UTF-16 units and is never split.
        #expect(limits.clampedName(String(repeating: "a", count: 49) + "😀") == String(repeating: "a", count: 49))
    }

    @Test func selectionRefusesBlockedAndOverLimitPicks() {
        var limits = GroupCreateLimits()
        limits.maxMembers = 2
        limits.blocked = ["b"]
        var selection = GroupComposeSelection()
        #expect(selection.toggle("a", limits: limits) == .added)
        #expect(!selection.canConfirm)
        #expect(selection.toggle("b", limits: limits) == .blocked)
        #expect(selection.toggle("c", limits: limits) == .added)
        #expect(selection.canConfirm)
        #expect(selection.toggle("d", limits: limits) == .overLimit)
        #expect(selection.toggle("a", limits: limits) == .removed)
        #expect(selection.ids == ["c"])
        selection.keep { $0 != "c" }
        #expect(selection.ids.isEmpty)
    }

    @Test func rosterListsRecentFriendChatsThenEveryFriend() {
        func friend(_ id: String, _ name: String, zalo: String = "") -> ContactsState.Friend {
            let key = ZaloEngine.contactFold(name)
            let first = key.first.map { String($0).uppercased() } ?? "#"
            let section = first.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) } ? first : "#"
            return .init(id: id, name: name, zaloName: zalo, avatar: nil, lastActive: nil, online: false, section: section, sortKey: key)
        }
        func chat(_ id: String, group: Bool = false, minutesAgo: Double) -> ZaloEngine.ConversationSummary {
            .init(id: id, isGroup: group, name: id, avatar: nil, pinned: false, members: 0, unread: 0,
                  preview: .init(text: "", date: Date(timeIntervalSinceNow: -minutesAgo * 60), fromMe: false))
        }
        let friends = [friend("1", "Đức"), friend("2", "an"), friend("3", "Bảo", zalo: "Bao Zalo"), friend("4", "123"),
                       friend("5", "Châu"), friend("6", "Em"), friend("7", "Giang")]
        let chats = [chat("g1", group: true, minutesAgo: 1), chat("me", minutesAgo: 2), chat("9", minutesAgo: 3), chat("3", minutesAgo: 9),
                     chat("1", minutesAgo: 4), chat("2", minutesAgo: 5), chat("5", minutesAgo: 6), chat("6", minutesAgo: 7), chat("7", minutesAgo: 8)]
        let roster = GroupComposeRoster(friends: friends, conversations: chats, selfId: "me")
        // Groups, My Cloud and non-friends are skipped; the 5 latest by message time.
        #expect(roster.recent.map(\.id) == ["1", "2", "5", "6", "7"])
        // Official accounts are friends too, but never "recent".
        let withoutOA = GroupComposeRoster(friends: friends, conversations: chats, selfId: "me", officialAccounts: ["2"])
        #expect(withoutOA.recent.map(\.id) == ["1", "5", "6", "7", "3"])
        #expect(withoutOA.friends.count == 7)
        #expect(roster.friends.map(\.name) == ["an", "Bảo", "Châu", "Đức", "Em", "Giang", "123"])
        #expect(roster.sections.map(\.title) == ["A", "B", "C", "D", "E", "G", "#"])
        #expect(roster.matching("duc").map(\.id) == ["1"])
        #expect(roster.matching("bao zalo").map(\.id) == ["3"])
        #expect(roster.matching("  ").count == 7)
    }

    @Test func outcomesMapTheAdapterAnswers() {
        #expect(GroupCreateOutcome(json: ["status": "created", "convId": "g1", "failed": ["2"]]) == .created(id: "g1", failed: ["2"]))
        #expect(GroupCreateOutcome(json: ["status": "exists", "convId": "g1", "text": "t"]) == .exists(id: "g1", text: "t"))
        #expect(GroupCreateOutcome(json: ["status": "created"]) == .failed(title: nil, message: GroupCreateOutcome.defaultFailure))
        #expect(GroupCreateOutcome(json: ["status": "invalid", "text": "x"]) == .invalid("x"))
        #expect(GroupCreateOutcome(json: ["status": "invalid", "text": "x", "dropped": ["4"]]) == .invalid("x", dropped: ["4"]))
        #expect(GroupCreateOutcome(json: ["status": "failed", "title": "T", "text": "m"]) == .failed(title: "T", message: "m"))
        #expect(GroupCreateOutcome(json: ["status": "failed", "text": "m", "close": true]) == .failed(title: nil, message: "m", closes: true))
        #expect(GroupCreateOutcome(json: ["status": "busy", "text": "b"]) == .failed(title: nil, message: "b"))
        #expect(GroupCreateOutcome(json: ["status": "pending"]) == .pending(GroupCreateOutcome.noAnswerText))
        #expect(GroupCreateOutcome(json: ["status": "not-ready"]) == .failed(title: nil, message: GroupCreateOutcome.notReadyText))
        #expect(GroupCreateOutcome(json: nil) == .failed(title: nil, message: GroupCreateOutcome.defaultFailure))
    }

    @Test func notAddedNoticeNamesAtMostThree() {
        #expect(ZaloEngine.notAddedText(["An"]) == "Chưa thêm được An vào nhóm.")
        #expect(ZaloEngine.notAddedText(["A", "B", "C", "D", "E"]) == "Chưa thêm được A, B, C và 2 người khác vào nhóm.")
    }

    private func noise(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var seed: UInt32 = 7
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                seed = seed &* 1_103_515_245 &+ 12345
                context.setFillColor(CGColor(red: CGFloat(seed >> 24 & 255) / 255, green: CGFloat(seed >> 16 & 255) / 255, blue: CGFloat(seed >> 8 & 255) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return context.makeImage()!
    }

    @Test func avatarIsTheCentreSquareWithinTheOfficialBounds() throws {
        let wide = try GroupAvatarImage.make(from: noise(width: 500, height: 300)).get()
        #expect(wide.side == 300)
        let big = try GroupAvatarImage.make(from: noise(width: 3000, height: 2000)).get()
        #expect(big.side == GroupAvatarImage.maxSide)
        #expect(big.jpeg.count <= GroupAvatarImage.maxBytes)
        #expect(big.jpeg.starts(with: [0xFF, 0xD8]))
        #expect(GroupAvatarImage.make(from: noise(width: 239, height: 800)) == .failure(.tooSmall))
    }

    private func jpegFile(_ image: CGImage, quality: Double = 0.9) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-avatar-\(UUID().uuidString).jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private func flat(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The official size rule is about the picked file (7 KB minimum), not the re-encoded photo.
    @Test func pickedFileSizeDecidesNotTheReencodedPhoto() throws {
        let tiny = try jpegFile(flat(width: 300, height: 300))
        defer { try? FileManager.default.removeItem(at: tiny) }
        #expect(try tiny.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 < GroupAvatarImage.minFileBytes)
        #expect(GroupAvatarImage.make(from: tiny) == .failure(.tooLight))
        // A flat image is fine when it comes from a big enough file, even if its re-encoded square is small.
        #expect((try? GroupAvatarImage.make(from: flat(width: 300, height: 300)).get())?.side == 300)
        let photo = try jpegFile(noise(width: 2000, height: 1500))
        defer { try? FileManager.default.removeItem(at: photo) }
        let made = try GroupAvatarImage.make(from: photo).get()
        #expect(made.side == GroupAvatarImage.maxSide)
        #expect(made.jpeg.count <= GroupAvatarImage.maxBytes)
    }
}
