import XCTest
@testable import OfflineFeed

final class ExternalCatalogTests: XCTestCase {
    func testScanFindsNestedVideosButNotOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Series"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("First.MP4"))
        try Data([2]).write(to: root.appendingPathComponent("Series/Second.mp4"))
        try Data([3]).write(to: root.appendingPathComponent("not-video.txt"))
        let result = try ExternalCatalog.scan(root)
        XCTAssertEqual(Set(result.map(\.title)), ["First", "Second"])
        XCTAssertTrue(result.allSatisfy { $0.url.path.hasPrefix(root.path + "/") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("First.MP4")), Data([1]))
    }

    func testResumeIsClampedAndFinishedVideosRestart() {
        XCTAssertEqual(ExternalCatalog.resumeTime(position: 65, duration: 100), 65)
        XCTAssertEqual(ExternalCatalog.resumeTime(position: 99, duration: 100), 0)
        XCTAssertEqual(ExternalCatalog.resumeTime(position: -1, duration: 100), 0)
    }
}
