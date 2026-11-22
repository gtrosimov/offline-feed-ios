import XCTest
@testable import OfflineFeed

final class SocialPlaybackTests: XCTestCase {
    private func clip(_ id: String, _ source: String, _ language: String?, watched: Bool = false) -> Clip {
        var result = Clip(id: id, filename: id + ".mp4", title: id, creator: "", source: source, tags: [], bytes: 100, seconds: 30, watched: watched)
        result.language = language
        return result
    }

    func testRussianSocialFeedExcludesEnglishPeerTubeAndUnverified() {
        let clips = [clip("a", "Instagram", "ru"), clip("b", "TikTok", "ru"), clip("c", "Instagram", "en"), clip("d", "PeerTube", "ru"), clip("e", "TikTok", nil), clip("f", "TikTok", "ru", watched: true)]
        XCTAssertEqual(Set(FeedLogic.socialQueue(clips, Preferences()).map(\.id)), ["a", "b"])
        XCTAssertEqual(FeedLogic.socialRemaining(clips), 60)
    }

    func testHoldIsOnlyOnRightEdge() {
        XCTAssertTrue(PlaybackPolicy.isSpeedEdge(x: 300, width: 390))
        XCTAssertTrue(PlaybackPolicy.isSpeedEdge(x: 389, width: 390))
        XCTAssertFalse(PlaybackPolicy.isSpeedEdge(x: 200, width: 390))
        XCTAssertFalse(PlaybackPolicy.isSpeedEdge(x: 0, width: 0))
    }

    func testTemporarySpeedResetsAndPausedStateIsRespected() {
        XCTAssertEqual(PlaybackPolicy.rate(playing: true, holding: true), 2)
        XCTAssertEqual(PlaybackPolicy.rate(playing: true, holding: false), 1)
        XCTAssertEqual(PlaybackPolicy.rate(playing: false, holding: true), 0)
    }

    func testCreatorLinkRequiresAnActualHandle() {
        XCTAssertEqual(SocialSource.instagramProfile("@some.creator")?.absoluteString, "https://www.instagram.com/some.creator/reels/")
        XCTAssertNil(SocialSource.instagramProfile("Словесное имя"))
        XCTAssertNil(SocialSource.instagramProfile("../../test"))
    }

    func testLegacyLibraryRecordsRemainReadableButDoNotEnterNewFeed() throws {
        let json = #"{"id":"old","filename":"old.mp4","title":"Old","creator":"","source":"Instagram","tags":[],"bytes":100,"seconds":20,"watched":false,"liked":true}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.id, "old")
        XCTAssertTrue(clip.liked)
        XCTAssertNil(clip.language)
        XCTAssertFalse(FeedLogic.isRussianSocial(clip))
    }
}
