import Testing
import Foundation
@testable import Olaz

@Suite struct PhotoSaveNameTests {
    @Test func extensionFromMagicBytes() {
        #expect(PhotoSaveName.fileExtension(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), sourceURL: nil) == "jpg")
        #expect(PhotoSaveName.fileExtension(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D]), sourceURL: nil) == "png")
        #expect(PhotoSaveName.fileExtension(data: Data("GIF89a".utf8), sourceURL: nil) == "gif")
        let webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8)
        #expect(PhotoSaveName.fileExtension(data: webp, sourceURL: nil) == "webp")
    }

    @Test func extensionFallsBackToURLThenJpg() {
        let url = URL(string: "https://cdn.example/a/b.PNG")
        #expect(PhotoSaveName.fileExtension(data: Data([1, 2, 3]), sourceURL: url) == "png")
        #expect(PhotoSaveName.fileExtension(data: Data(), sourceURL: URL(string: "https://cdn.example/x")) == "jpg")
    }

    @Test func nameUsesBytesNotURL() {
        let date = Date(timeIntervalSince1970: 0)
        let name = PhotoSaveName.make(date: date, data: Data([0xFF, 0xD8, 0xFF]), sourceURL: URL(string: "https://x/y.png"))
        #expect(name.hasPrefix("Zalo_") && name.hasSuffix(".jpg"))
    }
}
