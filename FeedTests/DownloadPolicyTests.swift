import XCTest
@testable import OfflineFeed

final class DownloadPolicyTests: XCTestCase {
    func testSearchDoesNotExposeCreatorsOrArbitraryProfileText() {
        let prefs = Preferences(instagramCreators: ["private_account_123"], tiktokInterests: ["secret phrase"], topics: ["шахматы", "secret phrase"], discoveryTopics: ["another secret"])
        let topics = DownloadPolicy.searchTopics(prefs)
        XCTAssertTrue(topics.contains { $0.query == "chess" })
        XCTAssertFalse(topics.contains { $0.query.contains("secret") || $0.query.contains("private_account") })
        XCTAssertTrue(topics.contains { $0.discovery })
    }

    func testOnlyExplicitlyPermittedPublicSafeVideoAccepted() {
        XCTAssertTrue(DownloadPolicy.permitted(downloadEnabled: true, license: 4, privacy: 1, nsfw: false, seconds: 90))
        XCTAssertFalse(DownloadPolicy.permitted(downloadEnabled: false, license: 4, privacy: 1, nsfw: false, seconds: 90))
        XCTAssertFalse(DownloadPolicy.permitted(downloadEnabled: true, license: 9, privacy: 1, nsfw: false, seconds: 90))
        XCTAssertFalse(DownloadPolicy.permitted(downloadEnabled: true, license: 4, privacy: 2, nsfw: false, seconds: 90))
        XCTAssertFalse(DownloadPolicy.permitted(downloadEnabled: true, license: 4, privacy: 1, nsfw: true, seconds: 90))
        XCTAssertFalse(DownloadPolicy.permitted(downloadEnabled: true, license: 4, privacy: 1, nsfw: false, seconds: 181))
    }

    func testRejectMalformedOrPrivateNetworkURLs() {
        for raw in ["http://example.com/a.mp4", "https://127.0.0.1/a.mp4", "https://localhost/a", "https://something.local/a", "https://user:secret@example.com/a", "https://example.com:8080/a"] {
            XCTAssertNil(DownloadPolicy.publicURL(raw), raw)
        }
        XCTAssertNotNil(DownloadPolicy.publicURL("https://example.com/video.mp4"))
    }

    func testSelectsCompactFileWithinRemainingStorage() {
        let options = [
            RemoteFile(id: 1, resolution: .init(id: 1080, label: "1080p"), size: 60_000_000, fileDownloadUrl: "https://example.com/large.mp4", hasAudio: true, hasVideo: true),
            RemoteFile(id: 2, resolution: .init(id: 480, label: "480p"), size: 12_000_000, fileDownloadUrl: "https://example.com/small.mp4", hasAudio: true, hasVideo: true),
            RemoteFile(id: 3, resolution: .init(id: 360, label: "360p"), size: 9_000_000, fileDownloadUrl: "https://example.com/muted.mp4", hasAudio: false, hasVideo: true)
        ]
        XCTAssertEqual(DownloadPolicy.chooseFile(options, remaining: 20_000_000, seconds: 90)?.id, 2)
        XCTAssertNil(DownloadPolicy.chooseFile(options, remaining: 5_000_000, seconds: 90))
    }

    func testRejectOversizedTransferAndContinuesBelowCap() {
        XCTAssertTrue(DownloadPolicy.validTransfer(bytes: 12_000_000, limit: 12_000_000))
        XCTAssertFalse(DownloadPolicy.validTransfer(bytes: 12_000_001, limit: 12_000_000))
        XCTAssertFalse(DownloadPolicy.validTransfer(bytes: -1, limit: 12_000_000))
    }

    func testOldLibraryRecordsRemainReadableWithoutRemoteMetadata() throws {
        let json = #"{"id":"old","filename":"old.mp4","title":"Old","creator":"","source":"Instagram","tags":[],"bytes":100,"seconds":20,"watched":false,"liked":true}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.id, "old")
        XCTAssertTrue(clip.liked)
        XCTAssertNil(clip.remoteID)
        XCTAssertNil(clip.originURL)
    }
}
