import Testing
import Foundation
@testable import Olaz

// Shared media of a conversation ("Kho lưu trữ"): the pure list logic, page decoding, the paging model, and the real
// `media-store-adapter.js` (plus the `resolveMedia` fallback of `chat-adapter.js`) in JavaScriptCore against a fake official media service.
// Every fixture is synthetic: no real names, ids or URLs.

private func message(_ id: String, _ kind: ChatMessage.Kind, at seconds: Double, status: ChatMessage.Status = .sent, mine: Bool = false) -> ChatMessage {
    ChatMessage(id: id, conversationId: "c1", senderId: "u1", senderName: "Test User", senderAvatar: nil, isMine: mine, kind: kind, text: "",
                date: Date(timeIntervalSince1970: seconds), status: status, quote: nil, reactions: [], isE2EE: false)
}

private func photo(_ id: String, at seconds: Double, status: ChatMessage.Status = .sent) -> ChatMessage {
    message(id, .photo(url: URL(string: "https://cdn.example.test/p/\(id).jpg"), width: 10, height: 10), at: seconds, status: status)
}

private func file(_ id: String, at seconds: Double) -> ChatMessage {
    message(id, .file(name: "tep-\(id).pdf", size: 1024, url: URL(string: "https://cdn.example.test/f/\(id)")), at: seconds)
}

private func link(_ id: String, at seconds: Double, url: String? = "https://site.example.test/a") -> ChatMessage {
    message(id, .link(title: "Link \(id)", url: url.flatMap(URL.init(string:)), thumbnail: nil), at: seconds)
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

// MARK: - List logic

@Suite struct SharedMediaListTests {
    @Test func kindsTakeTheirOwnMessages() {
        #expect(SharedMediaKind.images.accepts(photo("a", at: 1).kind))
        #expect(SharedMediaKind.images.accepts(.video(thumbnail: nil, duration: 3)))
        #expect(!SharedMediaKind.images.accepts(file("f", at: 1).kind))
        #expect(SharedMediaKind.files.accepts(file("f", at: 1).kind))
        #expect(SharedMediaKind.links.accepts(link("l", at: 1).kind))
        // A link card whose address cannot be opened is not a shared link.
        #expect(!SharedMediaKind.links.accepts(link("l", at: 1, url: nil).kind))
        #expect(!SharedMediaKind.links.accepts(.text))
    }

    @Test func mergeKeepsOneCopyPerIdNewestFirst() {
        let stored = [photo("1", at: 100), photo("2", at: 300), file("f", at: 999), photo("3", at: 200)]
        // "2" is also loaded (the loaded copy wins), "4" was just sent and the store does not know it yet.
        var loaded2 = photo("2", at: 300)
        loaded2.senderName = "Loaded"
        let loaded = [photo("0", at: 50), loaded2, photo("4", at: 400, status: .sending), file("g", at: 10)]
        let merged = SharedMediaList.merged(stored: stored, loaded: loaded, kind: .images)
        #expect(merged.map(\.id) == ["4", "2", "3", "1", "0"])
        #expect(merged.first { $0.id == "2" }?.senderName == "Loaded")
        #expect(SharedMediaList.merged(stored: stored, loaded: loaded, kind: .files).map(\.id) == ["f", "g"])
    }

    @Test func aFailedSendIsNotSharedContent() {
        let merged = SharedMediaList.merged(stored: [], loaded: [photo("ok", at: 1), photo("bad", at: 2, status: .failed)], kind: .images)
        #expect(merged.map(\.id) == ["ok"])
    }

    @Test func equalTimesOrderByIdWhateverTheInputOrder() {
        let a = [photo("99", at: 5), photo("100", at: 5), photo("101", at: 5)]
        let expected = ["101", "100", "99"]
        #expect(SharedMediaList.newestFirst(a).map(\.id) == expected)
        #expect(SharedMediaList.newestFirst(a.reversed()).map(\.id) == expected)
    }

    @Test func previewHoldsTheLatestFewOfEachList() {
        let photos = (1...20).map { photo("p\($0)", at: Double($0)) }
        let shown = SharedMediaList.preview(.images, stored: photos, loaded: [])
        #expect(shown.count == 9 && shown.first?.id == "p20" && shown.last?.id == "p12")
        let files = (1...10).map { file("f\($0)", at: Double($0)) }
        #expect(SharedMediaList.preview(.files, stored: files, loaded: []).count == 4)
        let links = (1...10).map { link("l\($0)", at: Double($0)) }
        #expect(SharedMediaList.preview(.links, stored: [], loaded: links).map(\.id) == ["l10", "l9", "l8", "l7"])
    }

    @Test func monthsGroupConsecutiveItemsAndTitleThem() {
        // 2026-10-27, 2026-10-01, 2026-09-30 (UTC), 2025-10-15.
        let items = [photo("a", at: 1_793_059_200), photo("b", at: 1_790_812_800), photo("c", at: 1_790_726_400), photo("d", at: 1_760_486_400)]
        let months = SharedMediaList.months(items, calendar: utc)
        #expect(months.map(\.title) == ["Tháng 10, 2026", "Tháng 9, 2026", "Tháng 10, 2025"])
        #expect(months.map { $0.items.map(\.id) } == [["a", "b"], ["c"], ["d"]])
        #expect(Set(months.map(\.id)).count == 3, "the same month of another year is a different section")
        #expect(SharedMediaList.months([], calendar: utc).isEmpty)
    }

    @Test func gridKeepsThreeColumnsAtTheDefaultWidthAndGrowsWhenWider() {
        let narrow = SharedMediaGrid.layout(width: 268)
        #expect(narrow.columns == 3 && narrow.side * 3 + SharedMediaGrid.gap * 2 <= 268)
        let narrowest = SharedMediaGrid.layout(width: 228)
        #expect(narrowest.columns == 3)
        let wide = SharedMediaGrid.layout(width: 408)
        #expect(wide.columns == 4 && wide.side * 4 + SharedMediaGrid.gap * 3 <= 408)
        #expect(SharedMediaGrid.layout(width: 0).columns == 3)
    }

    /// The tile width comes from the scroll view's own width with room kept for a classic scroll bar, so it is the same whether the bar is
    /// showing or not (a width read from the content flipped the bar on and off until AppKit crashed).
    @MainActor @Test func gridWidthDoesNotDependOnTheScrollBar() {
        let width = SharedMediaGrid.contentWidth(outer: 300, inset: 16)
        #expect(width == 300 - 32 - SharedMediaGrid.scrollerReserve)
        #expect(SharedMediaGrid.contentWidth(outer: 10, inset: 16) == 0)
    }
}

// MARK: - Page decoding

@Suite struct SharedMediaPageTests {
    private func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }

    @Test func decodesAPageShapedLikeTheAdapterEmitsIt() throws {
        let page = try #require(SharedMediaPage(json: try json("""
        {"items":[
          {"id":"5001","conversationId":"u2","senderId":"me1","senderName":"Test Me","senderAvatar":"","isMine":true,
           "kind":{"type":"photo","url":"https://cdn.example.test/p/n1.jpg","width":1280,"height":960},"text":"[Hình ảnh]",
           "date":1760000000000,"status":"sent","quote":null,"reactions":[],"mentions":[],"isE2EE":false},
          {"id":"1000000000000000020","conversationId":"u2","senderId":"u2","senderName":"Test Friend","senderAvatar":"https://cdn.example.test/a.jpg","isMine":false,
           "kind":{"type":"video","thumbnail":"https://cdn.example.test/p/t2.jpg","url":"https://cdn.example.test/p/v2.mp4","duration":13},"text":"[Video]",
           "date":1760000100000,"status":"sent","quote":null,"reactions":[],"mentions":[],"isE2EE":false},
          {"id":"f1","conversationId":"u2","senderId":"u2","senderName":"","senderAvatar":"","isMine":false,
           "kind":{"type":"file","name":"tai-lieu.pdf","size":2048,"url":"https://cdn.example.test/f/1"},"text":"[Tệp]","date":1760000200000,"status":"sent"},
          {"id":"l1","kind":{"type":"link","title":"Trang thử","url":"https://site.example.test/x","thumbnail":"","description":"Mô tả","source":"site.example.test"},"date":1760000300000},
          {"kind":{"type":"photo"}}
        ],"cursor":"1000000000000000020","more":true}
        """), conversationId: "u2"))
        #expect(page.items.map(\.id) == ["5001", "1000000000000000020", "f1", "l1"], "an entry without an id is dropped")
        #expect(page.cursor == "1000000000000000020" && page.more)
        #expect(page.items[0].isMine && page.items[0].kind == .photo(url: URL(string: "https://cdn.example.test/p/n1.jpg"), width: 1280, height: 960))
        #expect(page.items[0].date == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(page.items[1].kind == .video(thumbnail: URL(string: "https://cdn.example.test/p/t2.jpg"), duration: 13, url: URL(string: "https://cdn.example.test/p/v2.mp4")))
        #expect(page.items[2].kind == .file(name: "tai-lieu.pdf", size: 2048, url: URL(string: "https://cdn.example.test/f/1")))
        #expect(page.items[3].kind == .link(title: "Trang thử", url: URL(string: "https://site.example.test/x"), thumbnail: nil, description: "Mô tả", source: "site.example.test"))
        #expect(page.items[3].conversationId == "u2", "the conversation falls back to the one asked for")
    }

    @Test func nullOrMalformedIsNotAPage() throws {
        #expect(SharedMediaPage(json: nil, conversationId: "u2") == nil)
        #expect(SharedMediaPage(json: NSNull(), conversationId: "u2") == nil)
        #expect(SharedMediaPage(json: try json(#"{"cursor":"1"}"#), conversationId: "u2") == nil)
        // An empty page is an answer: nothing (more) shared.
        let end = try #require(SharedMediaPage(json: try json(#"{"items":[],"cursor":null,"more":false}"#), conversationId: "u2"))
        #expect(end.items.isEmpty && end.cursor == nil && !end.more)
    }
}

// MARK: - Paging model

@MainActor private final class FakeSource: SharedMediaSource {
    var pages: [SharedMediaKind: [SharedMediaPage?]] = [:]
    private(set) var calls: [(kind: SharedMediaKind, cursor: String?)] = []

    func sharedMedia(in conversationId: String, kind: SharedMediaKind, after cursor: String?, limit: Int) async -> SharedMediaPage? {
        calls.append((kind, cursor))
        guard var queue = pages[kind], !queue.isEmpty else { return SharedMediaPage(items: [], cursor: nil, more: false) }
        let next = queue.removeFirst()
        pages[kind] = queue
        return next
    }
}

@MainActor @Suite struct SharedMediaModelTests {
    @Test func feedStopsWhenAPageBringsNothingNew() {
        var feed = SharedMediaFeed()
        #expect(feed.isPending)
        feed.append(SharedMediaPage(items: [photo("3", at: 3), photo("2", at: 2)], cursor: "2", more: true))
        #expect(feed.loaded && !feed.isPending && feed.more && feed.cursor == "2")
        feed.append(SharedMediaPage(items: [photo("1", at: 1)], cursor: "1", more: true))
        #expect(feed.items.map(\.id) == ["3", "2", "1"] && feed.more && feed.cursor == "1")
        // The same ids again (a cursor that did not move): the end, whatever the page claims.
        feed.append(SharedMediaPage(items: [photo("1", at: 1)], cursor: "1", more: true))
        #expect(feed.items.count == 3 && !feed.more)
    }

    @Test func aFirstPageOfNothingIsAnAnswer() {
        var feed = SharedMediaFeed()
        feed.append(SharedMediaPage(items: [], cursor: nil, more: false))
        #expect(feed.loaded && !feed.isPending && feed.items.isEmpty && !feed.more)
    }

    @Test func reloadingTheFirstPageKeepsHowDeepTheListWasRead() {
        var feed = SharedMediaFeed()
        feed.append(SharedMediaPage(items: [photo("3", at: 3), photo("2", at: 2)], cursor: "2", more: true))
        feed.append(SharedMediaPage(items: [photo("1", at: 1)], cursor: "1", more: true))
        feed.merge(firstPage: SharedMediaPage(items: [photo("4", at: 4), photo("3", at: 3)], cursor: "3", more: true))
        #expect(feed.items.map(\.id) == ["4", "3", "2", "1"])
        #expect(feed.cursor == "1" && feed.more)
    }

    @Test func overviewReadsEveryListAndTheFullPageContinuesFromThere() async {
        let source = FakeSource()
        source.pages[.images] = [
            SharedMediaPage(items: [photo("3", at: 3), photo("2", at: 2)], cursor: "2", more: true),
            SharedMediaPage(items: [photo("1", at: 1)], cursor: "1", more: true),
            SharedMediaPage(items: [], cursor: nil, more: false),
        ]
        source.pages[.files] = [SharedMediaPage(items: [file("f1", at: 1)], cursor: "f1", more: true)]
        let model = SharedMediaModel(conversationId: "c1")
        #expect(!model.hasLoaded && model.feed(.images).isPending)
        await model.refresh(using: source)
        #expect(model.hasLoaded)
        #expect(model.feed(.images).items.map(\.id) == ["3", "2"])
        #expect(model.feed(.files).items.map(\.id) == ["f1"])
        #expect(model.feed(.links).loaded && model.feed(.links).items.isEmpty)

        await model.loadMore(.images, using: source)
        #expect(model.feed(.images).items.map(\.id) == ["3", "2", "1"])
        #expect(source.calls.last?.kind == .images && source.calls.last?.cursor == "2", "the next page starts after the oldest id read")
        // An empty page ends the list; asking again does nothing.
        await model.loadMore(.images, using: source)
        #expect(!model.feed(.images).more)
        let asked = source.calls.count
        await model.loadMore(.images, using: source)
        #expect(source.calls.count == asked)
    }

    @Test func aFailedFirstReadCanBeRetriedAndAFailedPageKeepsTheItems() async {
        let source = FakeSource()
        source.pages[.images] = [nil, SharedMediaPage(items: [photo("2", at: 2)], cursor: "2", more: true), nil,
                                 SharedMediaPage(items: [photo("1", at: 1)], cursor: "1", more: false)]
        let model = SharedMediaModel(conversationId: "c1")
        await model.refresh(using: source)
        #expect(model.feed(.images).phase == .failed && !model.feed(.images).isPending, "the overview falls back to the loaded messages")
        await model.retry(.images, using: source)
        #expect(model.feed(.images).phase == .idle && model.feed(.images).items.map(\.id) == ["2"])
        // The next page fails: the items stay, nothing is retried by itself, the retry button asks the same page again.
        await model.loadMore(.images, using: source)
        #expect(model.feed(.images).phase == .failed && model.feed(.images).items.map(\.id) == ["2"])
        await model.loadMore(.images, using: source)
        #expect(model.feed(.images).phase == .failed, "a scroll event does not retry on its own")
        await model.retry(.images, using: source)
        #expect(model.feed(.images).items.map(\.id) == ["2", "1"] && !model.feed(.images).more)
    }

    @Test func aQuietReloadAddsNewItemsWithoutShowingProgress() async {
        let source = FakeSource()
        source.pages[.images] = [SharedMediaPage(items: [photo("1", at: 1)], cursor: "1", more: true),
                                 SharedMediaPage(items: [photo("2", at: 2), photo("1", at: 1)], cursor: "1", more: true)]
        let model = SharedMediaModel(conversationId: "c1")
        await model.refresh(using: source)
        await model.refresh(using: source)
        #expect(model.feed(.images).items.map(\.id) == ["2", "1"] && model.feed(.images).phase == .idle)
        // A reload that fails changes nothing.
        source.pages[.images] = [nil]
        await model.refresh(using: source)
        #expect(model.feed(.images).items.map(\.id) == ["2", "1"] && model.feed(.images).phase == .idle)
    }

    @Test func aTabIsReadOnceWhenOpened() async {
        let source = FakeSource()
        source.pages[.links] = [SharedMediaPage(items: [link("l1", at: 1)], cursor: "l1", more: true)]
        let model = SharedMediaModel(conversationId: "c1")
        await model.loadIfNeeded(.links, using: source)
        await model.loadIfNeeded(.links, using: source)
        #expect(source.calls.count == 1 && model.feed(.links).items.map(\.id) == ["l1"])
    }
}

// MARK: - Recalled / deleted media, the loaded window, the flat rows, the caches

@Suite struct SharedMediaDeletionTests {
    private func recalled(_ id: String, at seconds: Double) -> ChatMessage { message(id, .recalled, at: seconds) }

    @Test func aLoadedMessageThatNoLongerQualifiesDropsTheStoredItem() {
        let stored = [photo("1", at: 100), photo("2", at: 200), file("f", at: 150)]
        // "2" was recalled (the loaded copy is now a recalled notice), "1" is an ordinary text now, "f" is unrelated to photos.
        let loaded = [recalled("2", at: 200), message("1", .text, at: 100), photo("3", at: 300)]
        #expect(SharedMediaList.merged(stored: stored, loaded: loaded, kind: .images).map(\.id) == ["3"])
        #expect(SharedMediaList.merged(stored: stored, loaded: [recalled("f", at: 150)], kind: .files).isEmpty)
        // A copy that failed to send drops it as well; an unrelated loaded text does nothing.
        #expect(SharedMediaList.merged(stored: stored, loaded: [photo("1", at: 100, status: .failed), message("x", .text, at: 1)], kind: .images).map(\.id) == ["2"])
        // The overview's top few follow the same rule.
        #expect(SharedMediaList.preview(.images, stored: stored, loaded: loaded).map(\.id) == ["3"])
    }

    @Test func loadedMessagesOlderThanTheStoreHasReadAreLeftOut() {
        let stored = [photo("5", at: 500), photo("4", at: 400)]
        let loaded = [photo("6", at: 600), photo("4", at: 400), photo("3", at: 300), photo("1", at: 100)]
        let merged = SharedMediaList.merged(stored: stored, loaded: loaded, kind: .images, loadedSince: Date(timeIntervalSince1970: 400))
        #expect(merged.map(\.id) == ["6", "5", "4"])
        // No limit: all of them.
        #expect(SharedMediaList.merged(stored: stored, loaded: loaded, kind: .images).map(\.id) == ["6", "5", "4", "3", "1"])
        // … but an out-of-window loaded copy still drops a stored item with its id.
        #expect(SharedMediaList.merged(stored: stored, loaded: [recalled("4", at: 400)], kind: .images, loadedSince: Date(timeIntervalSince1970: 450)).map(\.id) == ["5"])
    }

    @Test func theFeedKnowsWhichLoadedMessagesCount() {
        var feed = SharedMediaFeed()
        #expect(feed.loadedSince == nil, "nothing read yet: the loaded messages are all there is")
        feed.append(SharedMediaPage(items: [photo("3", at: 300), photo("2", at: 200)], cursor: "2", more: true))
        #expect(feed.loadedSince == Date(timeIntervalSince1970: 200))
        feed.append(SharedMediaPage(items: [photo("1", at: 100)], cursor: "1", more: false))
        #expect(feed.loadedSince == nil, "the end of the store: every loaded message counts")
        var failed = SharedMediaFeed()
        failed.phase = .failed
        #expect(failed.loadedSince == nil && failed.didFail && !failed.isPending)
    }

    @Test func reloadingRemovesWhatTheNewestWindowNoLongerHas() {
        var feed = SharedMediaFeed()
        feed.append(SharedMediaPage(items: (6...9).map { photo("\($0)", at: Double($0)) }.reversed(), cursor: "6", more: true))
        feed.append(SharedMediaPage(items: (1...5).map { photo("\($0)", at: Double($0)) }.reversed(), cursor: "1", more: true))
        // 8 was deleted; 5 and 6 were cut off by the page (older than its oldest item 7) and stay.
        let before = feed.revision
        feed.merge(firstPage: SharedMediaPage(items: [photo("9", at: 9), photo("7", at: 7)], cursor: "7", more: true))
        #expect(feed.items.map(\.id) == ["9", "7", "6", "5", "4", "3", "2", "1"])
        #expect(feed.cursor == "1" && feed.more, "how deep the list was read is kept")
        #expect(feed.revision > before)
        // Nothing changed: the revision stays (derived lists are not rebuilt).
        let same = feed.revision
        feed.merge(firstPage: SharedMediaPage(items: [photo("9", at: 9), photo("7", at: 7)], cursor: "7", more: true))
        #expect(feed.revision == same)
    }

    @Test func aBurstSharingTheBoundaryTimeIsNotLostToThePageLimit() {
        // Ten photos of one send share a time; the page limit cut the burst: ids 10…6 are in the page, 5…1 are older ids of the same burst.
        func burst(_ ids: [Int]) -> [ChatMessage] { ids.map { photo("\(1000 + $0)", at: 50) } }
        var feed = SharedMediaFeed()
        feed.append(SharedMediaPage(items: burst(Array(1...10)) + [photo("500", at: 10)], cursor: "500", more: true))
        feed.merge(firstPage: SharedMediaPage(items: [photo("2000", at: 60)] + burst(Array(6...10)), cursor: "1006", more: true))
        #expect(Set(feed.items.map(\.id)) == Set(["2000", "1006", "1007", "1008", "1009", "1010", "1001", "1002", "1003", "1004", "1005", "500"]))
        // A member of the burst that sorts above the page's oldest item and is missing from the page was deleted.
        feed.merge(firstPage: SharedMediaPage(items: [photo("2000", at: 60), photo("1010", at: 50), photo("1008", at: 50), photo("1006", at: 50)], cursor: "1006", more: true))
        #expect(!feed.items.map(\.id).contains("1009") && !feed.items.map(\.id).contains("1007"))
        #expect(feed.items.map(\.id).contains("1005"), "older ids of the burst stay")
    }

    @Test func aPageWithNothingLeftEmptiesTheListAndAnEmptyListTakesThePagesCursor() {
        var gone = SharedMediaFeed()
        gone.append(SharedMediaPage(items: [photo("2", at: 2), photo("1", at: 1)], cursor: "1", more: true))
        gone.merge(firstPage: SharedMediaPage(items: [], cursor: nil, more: false))
        #expect(gone.items.isEmpty && !gone.more)

        // The inspector opened before the sync filled the database: the first page was empty, a later one is not.
        var late = SharedMediaFeed()
        late.append(SharedMediaPage(items: [], cursor: nil, more: false))
        #expect(!late.more)
        late.merge(firstPage: SharedMediaPage(items: [photo("3", at: 3), photo("2", at: 2)], cursor: "2", more: true))
        #expect(late.items.map(\.id) == ["3", "2"] && late.cursor == "2" && late.more)

        // A page that shares nothing with what is held (everything held is older): its cursor takes over, held older items stay.
        var apart = SharedMediaFeed()
        apart.append(SharedMediaPage(items: [photo("2", at: 20), photo("1", at: 10)], cursor: "1", more: false))
        apart.merge(firstPage: SharedMediaPage(items: [photo("9", at: 90), photo("8", at: 80)], cursor: "8", more: true))
        #expect(apart.items.map(\.id) == ["9", "8", "2", "1"] && apart.cursor == "8" && apart.more)
    }
}

@Suite struct SharedMediaDerivedTests {
    @Test func previewEqualsTheFirstOfTheFullMerge() {
        // Deterministic pseudo-random lists with overlaps, ties and non-qualifying loaded copies.
        var seed: UInt64 = 12345
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<40 {
            let stored = (0..<60).map { _ in photo("s\(next(80))", at: Double(next(30))) }
            // Loaded messages have unique ids (the chat list merges by id); some overlap the stored ones.
            var ids = Array(0..<80)
            for i in ids.indices.reversed() { ids.swapAt(i, next(i + 1)) }
            var loaded: [ChatMessage] = ids[0..<30].map { photo("s\($0)", at: Double(next(30))) }
            loaded += ids[30..<40].map { message("s\($0)", next(2) == 0 ? .text : .recalled, at: Double(next(30))) }
            let unique = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { $1 }).values.map { $0 }
            let full = SharedMediaList.merged(stored: unique, loaded: loaded, kind: .images)
            #expect(SharedMediaList.preview(.images, stored: unique, loaded: loaded).map(\.id) == Array(full.prefix(9)).map(\.id))
        }
    }

    @Test func rowsFlattenMonthsIntoHeadersAndItems() {
        let items = [photo("a", at: 1_793_059_200), photo("b", at: 1_790_812_800), photo("c", at: 1_790_726_400)]
        let rows = SharedMediaList.rows(SharedMediaList.months(items, calendar: utc))
        #expect(rows.map(\.id) == ["month-2026-10", "a", "b", "month-2026-9", "c"])
        #expect(rows[0].content == .header("Tháng 10, 2026") && rows[0].firstMonth && !rows[3].firstMonth)
        #expect(rows[1].firstInMonth && !rows[1].lastInMonth && !rows[2].firstInMonth && rows[2].lastInMonth)
        #expect(rows[4].firstInMonth && rows[4].lastInMonth, "a month of one row is both ends")
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @MainActor @Test func derivedListsAreRebuiltOnlyWhenTheirInputsChange() async {
        let source = FakeSource()
        source.pages[.images] = [SharedMediaPage(items: [photo("2", at: 2), photo("1", at: 1)], cursor: "1", more: true)]
        let model = SharedMediaModel(conversationId: "c1")
        await model.refresh(using: source)
        let loaded = [photo("3", at: 3), message("t", .text, at: 4)]
        let first = model.preview(.images, loaded: loaded)
        #expect(first.map(\.id) == ["3", "2", "1"])
        let listing = model.listing(.images, loaded: loaded)
        #expect(listing.items.map(\.id) == ["3", "2", "1"] && listing.rows.count == listing.months.count + 3)
        let builds = model.derivedBuilds
        // Same inputs, even with the status (not the list) changing: served from the cache.
        for _ in 0..<5 { _ = model.preview(.images, loaded: loaded); _ = model.listing(.images, loaded: loaded) }
        #expect(model.derivedBuilds == builds)
        // New loaded messages rebuild; so does a feed change; an unchanged reload does not.
        #expect(model.preview(.images, loaded: loaded + [photo("5", at: 5)]).map(\.id) == ["5", "3", "2", "1"])
        let afterLoaded = model.derivedBuilds
        #expect(afterLoaded == builds + 1)
        source.pages[.images] = [SharedMediaPage(items: [photo("2", at: 2), photo("1", at: 1)], cursor: "1", more: true)]
        await model.refresh(using: source)
        _ = model.preview(.images, loaded: loaded + [photo("5", at: 5)])
        #expect(model.derivedBuilds == afterLoaded, "a reload that changed nothing keeps the caches")
        source.pages[.images] = [SharedMediaPage(items: [photo("9", at: 9), photo("2", at: 2)], cursor: "2", more: true)]
        await model.refresh(using: source)
        #expect(model.preview(.images, loaded: loaded + [photo("5", at: 5)]).map(\.id).first == "9")
        #expect(model.derivedBuilds == afterLoaded + 1)
    }

    @MainActor @Test func aFirstPageThatWasEmptyDoesNotStopTheListForGood() async {
        let source = FakeSource()
        source.pages[.images] = [SharedMediaPage(items: [], cursor: nil, more: false),
                                 SharedMediaPage(items: [photo("3", at: 3), photo("2", at: 2)], cursor: "2", more: true),
                                 SharedMediaPage(items: [photo("1", at: 1)], cursor: "1", more: true)]
        let model = SharedMediaModel(conversationId: "c1")
        await model.refresh(using: source)
        #expect(model.feed(.images).loaded && model.feed(.images).items.isEmpty && !model.feed(.images).more)
        await model.refresh(using: source)
        #expect(model.feed(.images).more && model.feed(.images).cursor == "2")
        await model.loadMore(.images, using: source)
        #expect(model.feed(.images).items.map(\.id) == ["3", "2", "1"])
    }
}
