import Foundation
import Testing
@testable import Olaz

@Suite("GIF")
struct GifTests {
    @Test func parsesOfficialRows() {
        let items = GifItem.list(from: ["data": ["has_more": true, "data_list": [
            ["id": "abc", "original": ["url": "https://g/o.gif", "width": 480, "height": 270],
             "preview": ["url": "https://g/p.gif", "width": 100, "height": 56], "normal": ["url": "https://g/n.gif"]],
            ["id": "bad"],
        ]]])
        #expect(items.count == 1)
        #expect(items.first?.url.absoluteString == "https://g/o.gif")
        #expect(items.first?.thumb.absoluteString == "https://g/p.gif")
        #expect(items.first?.width == 480 && items.first?.height == 270)
    }
}
