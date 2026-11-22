import XCTest
@testable import OfflineFeed

final class FeedLogicTests: XCTestCase {
    private func clip(_ id: String, _ size: Int64 = 100, _ seconds: Double = 30, tags: [String] = [], creator: String = "", seen: Bool = false) -> Clip {
        Clip(id: id, filename: id + ".mp4", title: id, creator: creator, source: "", tags: tags, bytes: size, seconds: seconds, watched: seen)
    }

    func testLimitIsStrictAndIncludesExistingVideos() {
        XCTAssertTrue(FeedLogic.fits(existing: [clip("a", 5_999_999_999)], incomingBytes: 1))
        XCTAssertFalse(FeedLogic.fits(existing: [clip("a", 5_999_999_999)], incomingBytes: 2))
        XCTAssertFalse(FeedLogic.fits(existing: [], incomingBytes: -1))
    }

    func testUnwatchedDurationExcludesWatchedClips() {
        XCTAssertEqual(FeedLogic.remaining([clip("a", 1, 90), clip("b", 1, 30, seen: true)]), 90)
    }

    func testFavoriteCreatorAndTopicAreRecognizedSeparately() {
        let prefs = Preferences(instagramCreators: ["example_creator"], tiktokInterests: [], topics: ["музыка"], discoveryTopics: [])
        XCTAssertEqual(FeedLogic.category(clip("a", tags: ["мемы"], creator: "@Example_Creator"), prefs), .favorite)
        XCTAssertEqual(FeedLogic.category(clip("b", tags: ["Музыка"]), prefs), .related)
        XCTAssertEqual(FeedLogic.category(clip("c", tags: ["архитектура"]), prefs), .discovery)
    }

    func testMixReservesEveryFifthClipForDiscoveryWhenAvailable() {
        let prefs = Preferences(instagramCreators: ["a"], tiktokInterests: [], topics: ["шахматы"], discoveryTopics: [])
        let clips = (0..<20).map { clip("f\($0)", creator: "a") } + (0..<20).map { clip("r\($0)", tags: ["шахматы"]) } + (0..<20).map { clip("d\($0)") }
        let result = FeedLogic.queue(clips, prefs).prefix(20)
        XCTAssertEqual(result.filter { FeedLogic.category($0, prefs) == .favorite }.count, 7)
        XCTAssertEqual(result.filter { FeedLogic.category($0, prefs) == .related }.count, 9)
        XCTAssertEqual(result.filter { FeedLogic.category($0, prefs) == .discovery }.count, 4)
        XCTAssertEqual(Set(result.map(\.id)).count, 20)
    }

    func testQueueNeverRepeatsOrIncludesWatched() {
        let result = FeedLogic.queue([clip("a"), clip("a"), clip("b", seen: true), clip("c")], Preferences())
        XCTAssertEqual(Set(result.map(\.id)), ["a", "c"])
        XCTAssertEqual(result.count, 2)
    }
}
