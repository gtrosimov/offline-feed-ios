import Foundation

struct Clip: Codable, Identifiable, Equatable {
    let id: String
    let filename: String
    var title: String
    var creator: String
    var source: String
    var tags: [String]
    let bytes: Int64
    let seconds: Double
    var watched: Bool = false
    var liked: Bool = false
    var remoteID: String? = nil
    var originURL: String? = nil
    var license: String? = nil
    var language: String? = nil
}

struct Preferences: Codable, Equatable {
    var instagramCreators: [String] = []
    var tiktokInterests: [String] = []
    var topics: [String] = []
    var discoveryTopics: [String] = []
}

enum FeedCategory: Equatable { case favorite, related, discovery }

enum FeedLogic {
    static let limit: Int64 = 6_000_000_000
    static let target: Double = 18_000

    static func used(_ clips: [Clip]) -> Int64 {
        clips.reduce(0) { min(limit, $0 + min(limit, max(0, $1.bytes))) }
    }

    static func fits(existing: [Clip], incomingBytes: Int64) -> Bool {
        incomingBytes >= 0 && incomingBytes <= limit - used(existing)
    }

    static func remaining(_ clips: [Clip]) -> Double {
        clips.filter { !$0.watched }.reduce(0) { $0 + max(0, $1.seconds) }
    }

    static func isRussianSocial(_ clip: Clip) -> Bool {
        ["instagram", "tiktok"].contains(normalized(clip.source)) && clip.language?.lowercased() == "ru"
    }

    static func socialRemaining(_ clips: [Clip]) -> Double { remaining(clips.filter(isRussianSocial)) }

    static func socialQueue(_ clips: [Clip], _ prefs: Preferences) -> [Clip] { queue(clips.filter(isRussianSocial), prefs) }

    static func normalized(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
    }

    static func category(_ clip: Clip, _ prefs: Preferences) -> FeedCategory {
        let author = normalized(clip.creator)
        if !author.isEmpty && prefs.instagramCreators.map(normalized).contains(author) { return .favorite }
        let interests = Set((prefs.topics + prefs.tiktokInterests).map(normalized))
        if clip.tags.map(normalized).contains(where: { interests.contains($0) }) { return .related }
        return .discovery
    }

    static func queue(_ clips: [Clip], _ prefs: Preferences) -> [Clip] {
        var ids = Set<String>()
        let pool = clips.filter { !$0.watched && ids.insert($0.id).inserted }.shuffled()
        var favorite = pool.filter { category($0, prefs) == .favorite }
        var related = pool.filter { category($0, prefs) == .related }
        var discovery = pool.filter { category($0, prefs) == .discovery }
        let pattern: [FeedCategory] = [.related,.favorite,.related,.favorite,.discovery,.related,.favorite,.related,.favorite,.discovery,.related,.favorite,.related,.favorite,.discovery,.related,.favorite,.related,.related,.discovery]
        var result: [Clip] = []
        while !favorite.isEmpty || !related.isEmpty || !discovery.isEmpty {
            let desired = pattern[result.count % pattern.count]
            var next: Clip?
            switch desired {
            case .favorite: next = favorite.popLast()
            case .related: next = related.popLast()
            case .discovery: next = discovery.popLast()
            }
            if next == nil { next = related.popLast() ?? favorite.popLast() ?? discovery.popLast() }
            if let next { result.append(next) }
        }
        return result
    }
}
