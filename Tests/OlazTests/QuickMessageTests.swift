import Foundation
import Testing
@testable import Olaz

@Suite("Tin nhắn nhanh")
struct QuickMessageTests {
    @Test func listAndMatches() {
        let items = QuickMessage.list(from: ["items": [
            ["id": 11, "keyword": "chao", "message": ["title": "Xin chào bạn", "params": ""]],
            ["id": 12, "keyword": "camon", "message": ["title": "Cảm ơn nhé"]],
            ["id": 13, "keyword": "", "message": ["title": "x"]],
        ]])
        #expect(items.map(\.id) == ["11", "12"])
        #expect(items.first?.text == "Xin chào bạn")
        #expect(QuickMessage.matches("/ch", in: items).map(\.keyword) == ["chao"])
        #expect(QuickMessage.matches("/", in: items).count == 2)
        #expect(QuickMessage.matches("chao", in: items).isEmpty)
        let p = QuickMessage.payload(keyword: " hi ", text: "Hello")
        #expect(p["keyword"] as? String == "hi")
        #expect((p["message"] as? [String: Any])?["title"] as? String == "Hello")
    }
}
