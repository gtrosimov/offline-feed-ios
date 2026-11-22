import Foundation

enum PlaybackPolicy {
    static func isSpeedEdge(x: Double, width: Double) -> Bool { width > 0 && x >= width * 0.72 && x <= width }
    static func rate(playing: Bool, holding: Bool) -> Float { playing ? (holding ? 2 : 1) : 0 }
}

enum SocialSource {
    static let instagram = URL(string: "https://www.instagram.com/reels/")!
    static let tiktok = URL(string: "https://www.tiktok.com/foryou")!

    static func instagramProfile(_ name: String) -> URL? {
        let handle = FeedLogic.normalized(name)
        guard !handle.isEmpty, handle.count <= 30, !handle.hasPrefix("."), !handle.hasSuffix("."), !handle.contains(".."),
              handle.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._").contains($0) }) else { return nil }
        return URL(string: "https://www.instagram.com/\(handle)/reels/")
    }
}
