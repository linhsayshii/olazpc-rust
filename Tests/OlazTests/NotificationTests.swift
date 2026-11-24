import Testing
import Foundation
import ImageIO
import Intents
import UniformTypeIdentifiers
import UserNotifications
@testable import Olaz

@Suite struct NotificationTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }

    private func date(_ string: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)!
    }

    // MARK: mute expiry

    @Test func muteDurationExpiry() {
        let now = date("2026-10-26T10:15:00+07:00")
        #expect(MuteDuration.oneHour.expiry(from: now, calendar: calendar) == now.addingTimeInterval(3600))
        #expect(MuteDuration.fourHours.expiry(from: now, calendar: calendar) == now.addingTimeInterval(4 * 3600))
        #expect(MuteDuration.untilReopened.expiry(from: now, calendar: calendar) == nil)
        // Past 8:00 → tomorrow 8:00.
        #expect(MuteDuration.until8AM.expiry(from: now, calendar: calendar) == date("2026-10-27T08:00:00+07:00"))
        // Before 8:00 → today 8:00.
        let early = date("2026-10-26T05:30:00+07:00")
        #expect(MuteDuration.until8AM.expiry(from: early, calendar: calendar) == date("2026-10-26T08:00:00+07:00"))
        // Exactly 8:00 → next day (official: `getTime() <= now` rolls over).
        let exact = date("2026-10-26T08:00:00+07:00")
        #expect(MuteDuration.until8AM.expiry(from: exact, calendar: calendar) == date("2026-10-27T08:00:00+07:00"))
    }

    @Test func muteDurationModesMatchOfficialMenu() {
        #expect(MuteDuration.allCases.map(\.rawValue) == [1, 2, 3, 4])
    }

    @Test func muteInfoActivity() {
        let now = date("2026-10-26T10:00:00+07:00")
        let start = now.timeIntervalSince1970
        let timed = MuteInfo(startTime: start - 600, duration: 3600)
        #expect(timed.isActive(at: now))
        #expect(timed.until == Date(timeIntervalSince1970: start + 3000))
        #expect(!MuteInfo(startTime: start - 7200, duration: 3600).isActive(at: now))
        let forever = MuteInfo(startTime: 1_685_096_585, duration: -1)
        #expect(forever.isIndefinite && forever.isActive(at: now) && forever.until == nil)
    }

    @Test func muteDescription() {
        let now = date("2026-10-26T10:00:00+07:00")
        let sameDay = MuteInfo(startTime: now.timeIntervalSince1970, duration: 3600)
        #expect(sameDay.description(now: now, calendar: calendar) == "Cho đến 11:00")
        let nextDay = MuteInfo(startTime: now.timeIntervalSince1970, duration: 22 * 3600)
        #expect(nextDay.description(now: now, calendar: calendar) == "Cho đến 08:00 ngày 27/10")
        #expect(MuteInfo(startTime: 0, duration: -1).description(now: now, calendar: calendar) == "Cho đến khi được mở lại")
    }

    // MARK: settings snapshot

    @Test func settingsSnapshot() {
        var state = NotificationSettingsState()
        #expect(!state.isLoaded)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        state.apply(settings: [
            "kind": "settings", "enabled": false, "sound": true, "hasSoundSetting": true,
            "mutes": [
                ["id": "123", "startTime": 1_799_990_000, "duration": 3600],     // expired
                ["id": "g456", "startTime": 1_799_999_000, "duration": 3600],    // active (timed)
                ["id": "789", "startTime": 1_685_096_585, "duration": -1],       // until reopened
                ["startTime": 1, "duration": 1],                                   // no id → ignored
            ],
        ])
        #expect(state.isLoaded && !state.enabled && state.sound && state.hasSoundSetting)
        #expect(state.mutes.count == 3)
        #expect(!state.isMuted("123", now: now))
        #expect(state.isMuted("g456", now: now))
        #expect(state.isMuted("789", now: now))
        #expect(!state.isMuted("000", now: now))
        #expect(state.activeMutes(now: now).map(\.id) == ["789", "g456"])
    }

    // MARK: IPC payload

    @Test func parsesElectronNotificationArguments() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString()
        let request = try #require(NativeNotificationRequest.parse([
            "Nhóm Gia đình", ["body": "Mẹ: ăn cơm chưa", "tag": "g12345", "silent": true, "icon": "data:image/png;base64,\(png)"],
        ]))
        #expect(request.title == "Nhóm Gia đình")
        #expect(request.body == "Mẹ: ăn cơm chưa")
        #expect(request.tag == "g12345")
        #expect(request.silent)
        #expect(request.icon == .inline(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])))
    }

    @Test func parsesIconKinds() {
        #expect(NativeNotificationRequest.parseIcon("https://s120-ava-talk.zadn.vn/a/b/c") == .remote(URL(string: "https://s120-ava-talk.zadn.vn/a/b/c")!))
        #expect(NativeNotificationRequest.parseIcon("assets/avatar_stranger_notif.5b53.png?v=1") == .bundled("assets/avatar_stranger_notif.5b53.png"))
        #expect(NativeNotificationRequest.parseIcon("") == nil)
        #expect(NativeNotificationRequest.parseIcon("data:image/png;base64,@@@") == nil)
        #expect(NativeNotificationRequest.parseIcon("file:///etc/passwd") == nil)
    }

    @Test func tagMayBeNumberAndDefaultsAreSafe() throws {
        let numeric = try #require(NativeNotificationRequest.parse(["Tên", ["body": "xin chào", "tag": NSNumber(value: 42)]]))
        #expect(numeric.tag == "42" && !numeric.silent && numeric.icon == nil)
        #expect(NativeNotificationRequest.parse([]) == nil)
        #expect(NativeNotificationRequest.parse(["", [:]]) == nil)
        let titleOnly = NativeNotificationRequest.parse(["Zalo"])
        #expect(titleOnly?.body == "" && titleOnly?.tag == "")
    }

    // MARK: policy

    @Test func previewToggle() {
        #expect(NotificationPolicy.body("Mẹ: xin chào", showsPreview: true) == "Mẹ: xin chào")
        #expect(NotificationPolicy.body("Mẹ: xin chào", showsPreview: false) == "Bạn có tin nhắn mới")
    }

    @Test func suppressesOnlyWhenWatchingThatConversation() {
        func suppress(active: Bool = true, visible: Bool = true, open: String? = "5", tag: String = "5", idle: TimeInterval = 4) -> Bool {
            NotificationPolicy.shouldSuppress(appIsActive: active, mainWindowVisible: visible, openConversation: open, tag: tag, userIdleSeconds: idle)
        }
        #expect(suppress())
        #expect(!suppress(active: false))
        #expect(!suppress(visible: false))
        #expect(!suppress(open: "6"))
        #expect(!suppress(open: nil))
        #expect(!suppress(tag: ""))
        #expect(!suppress(idle: 600))   // user stepped away: official idle rule still notifies
    }

    @Test func attachmentTypeSniffing() {
        #expect(NotificationPolicy.attachmentType(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D]))?.ext == "png")
        #expect(NotificationPolicy.attachmentType(for: Data([0xFF, 0xD8, 0xFF, 0xE0]))?.ext == "jpg")
        #expect(NotificationPolicy.attachmentType(for: Data("GIF89a".utf8))?.ext == "gif")
        #expect(NotificationPolicy.attachmentType(for: Data("RIFF....WEBP".utf8)) == nil)
        #expect(NotificationPolicy.attachmentType(for: Data()) == nil)
    }

    @Test func soundURLAllowList() {
        #expect(NotificationPolicy.isSoundURLAllowed(URL(string: "https://stc-chat.zdn.vn/sound/noti.mp3")!))
        #expect(!NotificationPolicy.isSoundURLAllowed(URL(string: "http://stc-chat.zdn.vn/sound/noti.mp3")!))
        #expect(!NotificationPolicy.isSoundURLAllowed(URL(string: "https://evil.example.com/sound/noti.mp3")!))
        #expect(!NotificationPolicy.isSoundURLAllowed(URL(string: "https://stc-chat.zdn.vn/other.mp3")!))
    }

    @Test func normalizedAvatarPNGDataConvertsJPEGAndNonSquareToSquarePNG() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil,
            width: 40,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let cgImg = try #require(ctx.makeImage())

        let jpegData = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImg, nil)
        #expect(CGImageDestinationFinalize(dest))

        let png = try #require(NotificationPolicy.normalizedAvatarPNGData(from: jpegData as Data, maxPixelSize: 64))
        #expect(NotificationPolicy.attachmentType(for: png)?.ext == "png")

        let pngSource = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let outImg = try #require(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))
        #expect(outImg.width == 20)
        #expect(outImg.height == 20)
        #expect(NotificationPolicy.normalizedAvatarPNGData(from: Data("not-an-image".utf8)) == nil)
    }

    @Test func monogramAvatarPNGDataProducesValidSquarePNG() throws {
        let png = try #require(NotificationPolicy.monogramAvatarPNGData(for: "Minh Anh", size: 96))
        #expect(NotificationPolicy.attachmentType(for: png)?.ext == "png")

        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 96)
        #expect(image.height == 96)
    }

    @Test func buildCommunicationIntentSetsSenderAndGroupMetadata() throws {
        let png = try #require(NotificationPolicy.monogramAvatarPNGData(for: "Lan", size: 64))
        let dmReq = NativeNotificationRequest(
            title: "Lan",
            body: "Xin chào",
            tag: "200",
            silent: false,
            icon: nil,
            senderId: "200",
            senderName: "Lan",
            isGroup: false
        )
        let dmIntent = NotificationPolicy.buildCommunicationIntent(for: dmReq, body: "Xin chào", avatarPNGData: png)
        #expect(dmIntent.sender?.displayName == "Lan")
        #expect(dmIntent.sender?.customIdentifier == "200")
        #expect(dmIntent.sender?.image != nil)
        #expect(dmIntent.conversationIdentifier == "200")
        #expect(dmIntent.speakableGroupName == nil)
        #expect(dmIntent.__image(forParameterNamed: "sender") != nil)
        #expect(dmIntent.keyImage() != nil)

        let updatedDM = try UNMutableNotificationContent().updating(from: dmIntent)
        #expect(updatedDM.title == "")

        let groupReq = NativeNotificationRequest(
            title: "Gia Đình",
            body: "Ăn cơm chưa",
            tag: "g999",
            silent: false,
            icon: nil,
            senderId: "201",
            senderName: "Mẹ",
            isGroup: true
        )
        let groupIntent = NotificationPolicy.buildCommunicationIntent(for: groupReq, body: "Ăn cơm chưa", avatarPNGData: png)
        #expect(groupIntent.speakableGroupName?.spokenPhrase == "Gia Đình")
        #expect(groupIntent.sender?.displayName == "Mẹ")
        #expect(groupIntent.conversationIdentifier == "g999")
        #expect(groupIntent.recipients?.count == 1)
        #expect(groupIntent.__image(forParameterNamed: "sender") != nil)
        #expect(groupIntent.__image(forParameterNamed: "speakableGroupName") != nil)
        #expect(groupIntent.keyImage() != nil)
    }

    @Test func badgedAvatarPutsAccountAvatarInBottomRightCorner() throws {
        let sender = try #require(Self.solidPNG(red: 0, green: 0, blue: 255))
        let badge = try #require(Self.solidPNG(red: 255, green: 0, blue: 0))
        let png = try #require(NotificationPolicy.badgedAvatarPNGData(sender: sender, badge: badge, size: 100))
        let pixels = try Self.rgba(png, size: 100)
        // Top-left corner lies outside the sender circle: transparent.
        #expect(pixels(2, 2).a == 0)
        // Center is the sender (blue); the bottom-right badge center (0.79, 0.79) is the account (red).
        #expect(pixels(50, 50) == (0, 0, 255, 255))
        #expect(pixels(79, 79) == (255, 0, 0, 255))
        // The white ring separates them.
        #expect(pixels(79, 59) == (255, 255, 255, 255))

        let plain = try #require(NotificationPolicy.badgedAvatarPNGData(sender: sender, badge: nil, size: 100))
        #expect(try Self.rgba(plain, size: 100)(79, 79) == (0, 0, 255, 255))
    }

    private static func solidPNG(red: UInt8, green: UInt8, blue: UInt8) -> Data? {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Pixel reader with a top-left origin (x right, y down), RGBA premultiplied.
    private static func rgba(_ png: Data, size: Int) throws -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer = [UInt8](repeating: 0, count: size * size * 4)
        let ctx = try #require(CGContext(data: &buffer, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let copy = buffer
        return { x, y in
            let i = (y * size + x) * 4
            return (copy[i], copy[i + 1], copy[i + 2], copy[i + 3])
        }
    }
}
