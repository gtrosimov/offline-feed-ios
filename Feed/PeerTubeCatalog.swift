import Foundation

struct SearchTopic: Equatable {
    let query: String
    let tag: String
    let discovery: Bool
}

struct RemoteConstant: Decodable {
    let id: Int?
    let label: String?
}

struct RemoteFile: Decodable {
    let id: Int
    let resolution: RemoteConstant
    let size: Int64
    let fileDownloadUrl: String?
    let hasAudio: Bool?
    let hasVideo: Bool?
}

private struct RemotePlaylist: Decodable { let files: [RemoteFile]? }
private struct RemoteChannel: Decodable { let displayName: String?; let name: String? }
private struct RemoteLanguage: Decodable { let id: String? }

private struct RemoteVideo: Decodable {
    let uuid: String
    let url: String
    let name: String
    let duration: Double
    let nsfw: Bool?
    let licence: RemoteConstant?
    let privacy: RemoteConstant?
    let language: RemoteLanguage?
    let downloadEnabled: Bool?
    let channel: RemoteChannel?
    let account: RemoteChannel?
    let tags: [String]?
    let files: [RemoteFile]?
    let streamingPlaylists: [RemotePlaylist]?
}

private struct SearchResponse: Decodable { let total: Int; let data: [RemoteVideo] }

struct CatalogCandidate {
    let id: String
    let origin: URL
    let title: String
    let topic: SearchTopic
}

struct DownloadableVideo {
    let id: String
    let title: String
    let creator: String
    let origin: String
    let license: String
    let tags: [String]
    let fileURL: URL
    let estimatedBytes: Int64
}

enum DownloadPolicy {
    static func searchTopics(_ prefs: Preferences) -> [SearchTopic] {
        let input = (prefs.topics + prefs.tiktokInterests).map(FeedLogic.normalized).joined(separator: " ")
        let groups: [(String, [String], [String])] = [
            ("юмор", ["юмор", "скетч", "комеди"], ["юмор", "comedy sketch", "funny clips"]),
            ("мемы", ["мем", "нарез", "реакц"], ["мемы", "funny memes"]),
            ("шахматы", ["шахмат", "chess"], ["шахматы", "chess"]),
            ("vibe coding", ["vibe coding", "вайб", "программ", "coding"], ["vibe coding", "creative coding", "программирование"]),
            ("нейросети", ["нейросет", "ai", "искусственн"], ["AI creative tools", "нейросети"]),
            ("фитнес и тренеры", ["фитнес", "тренер", "спорт"], ["фитнес", "fitness tips"]),
            ("интересные факты", ["факт", "интересн", "науч"], ["interesting facts", "научпоп"])
        ]
        var result: [SearchTopic] = []
        for (tag, keys, queries) in groups where keys.contains(where: { input.contains($0) }) {
            result.append(contentsOf: queries.map { SearchTopic(query: $0, tag: tag, discovery: false) })
        }
        if result.isEmpty { result = [SearchTopic(query: "юмор", tag: "юмор", discovery: false), SearchTopic(query: "interesting facts", tag: "интересные факты", discovery: false)] }
        let discoveries = [("funny animals", "животные"), ("science demonstration", "наука"), ("creative projects", "хобби"), ("travel short video", "путешествия"), ("amazing inventions", "технологии")]
        result.append(contentsOf: discoveries.map { SearchTopic(query: $0.0, tag: $0.1, discovery: true) })
        return result
    }

    static func permitted(downloadEnabled: Bool, license: Int?, privacy: Int?, nsfw: Bool?, seconds: Double) -> Bool {
        downloadEnabled && (1...7).contains(license ?? 0) && privacy == 1 && nsfw == false && seconds.isFinite && (5...180).contains(seconds)
    }

    static func publicURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(), host.count <= 253,
              host.contains("."), host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }),
              host.split(separator: ".").last?.first?.isLetter == true,
              ![".local", ".lan", ".internal", ".home", ".localhost", ".onion", ".test", ".invalid"].contains(where: { host.hasSuffix($0) }) else { return nil }
        return url
    }

    static func chooseFile(_ files: [RemoteFile], remaining: Int64, seconds: Double) -> RemoteFile? {
        guard remaining > 0, seconds.isFinite, seconds > 0, seconds <= 180 else { return nil }
        let bitrateLimit = Int64(seconds * 330_000)
        return files.filter { file in
            guard file.hasAudio == true, file.hasVideo == true, let resolution = file.resolution.id,
                  (240...720).contains(resolution), file.size > 0, file.size <= min(remaining, bitrateLimit),
                  let address = file.fileDownloadUrl, let url = publicURL(address), url.pathExtension.lowercased() == "mp4" else { return false }
            return true
        }.sorted { a, b in
            // 480p is a useful compromise; use a smaller file if there is no such rendition.
            let aDistance = abs((a.resolution.id ?? 0) - 480), bDistance = abs((b.resolution.id ?? 0) - 480)
            return aDistance == bDistance ? a.size < b.size : aDistance < bDistance
        }.first
    }

    static func validTransfer(bytes: Int64, limit: Int64) -> Bool { bytes > 0 && bytes <= limit }

    static func safeTitle(_ title: String) -> Bool {
        let name = title.lowercased()
        return !["porn", "nsfw", "gore", "casino", "казино", "порно", "18+", "суицид", "жестокое убийство", "ставки на спорт"].contains(where: { name.contains($0) })
    }

    static func mix(_ related: [CatalogCandidate], _ discovery: [CatalogCandidate]) -> [CatalogCandidate] {
        var a = related.shuffled(), b = discovery.shuffled(), seen = Set<String>(), result: [CatalogCandidate] = []
        while !a.isEmpty || !b.isEmpty {
            let next = result.count % 5 == 4 ? (b.popLast() ?? a.popLast()) : (a.popLast() ?? b.popLast())
            if let next, seen.insert(next.id).inserted { result.append(next) }
        }
        return result
    }
}

private final class HTTPSGuard: NSObject, URLSessionDownloadDelegate {
    let limit: Int64
    init(limit: Int64 = 2_000_000) { self.limit = limit }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, DownloadPolicy.publicURL(url.absoluteString) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

final class PeerTubeCatalog {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 90
        config.httpAdditionalHeaders = ["User-Agent": "OfflineFeed/1.1 (personal offline video player)"]
        session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }

    private func getJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        guard DownloadPolicy.publicURL(url.absoluteString) != nil else { throw CatalogError.invalid }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: HTTPSGuard())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, DownloadPolicy.publicURL(finalURL.absoluteString) != nil,
              response.expectedContentLength <= 2_000_000 else { throw CatalogError.invalid }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw CatalogError.invalid }
            data.append(byte)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func search(_ topic: SearchTopic, page: Int) async throws -> [CatalogCandidate] {
        var components = URLComponents(string: "https://search.joinpeertube.org/api/v1/search/videos")!
        components.queryItems = [URLQueryItem(name: "search", value: topic.query), URLQueryItem(name: "nsfw", value: "false"), URLQueryItem(name: "durationMax", value: "180"), URLQueryItem(name: "count", value: "50"), URLQueryItem(name: "start", value: String(page * 50))]
        guard let url = components.url else { throw CatalogError.invalid }
        let result = try await getJSON(url, as: SearchResponse.self)
        return result.data.compactMap { item in
            guard let origin = DownloadPolicy.publicURL(item.url), UUID(uuidString: item.uuid) != nil,
                  item.nsfw == false, (1...7).contains(item.licence?.id ?? 0), (5...180).contains(item.duration),
                  DownloadPolicy.safeTitle(item.name) else { return nil }
            // Unknown and non-English/Russian spoken content is excluded; language-free clips are allowed.
            if let language = item.language?.id, !["ru", "en", "zxx"].contains(language) { return nil }
            return CatalogCandidate(id: item.uuid, origin: origin, title: item.name, topic: topic)
        }
    }

    func available(_ candidate: CatalogCandidate, remaining: Int64) async throws -> DownloadableVideo {
        guard var components = URLComponents(url: candidate.origin, resolvingAgainstBaseURL: false) else { throw CatalogError.invalid }
        components.path = "/api/v1/videos/" + candidate.id; components.query = nil; components.fragment = nil
        guard let address = components.url else { throw CatalogError.invalid }
        let video = try await getJSON(address, as: RemoteVideo.self)
        guard video.uuid == candidate.id, DownloadPolicy.permitted(downloadEnabled: video.downloadEnabled == true, license: video.licence?.id, privacy: video.privacy?.id, nsfw: video.nsfw, seconds: video.duration),
              DownloadPolicy.safeTitle(video.name), let origin = DownloadPolicy.publicURL(video.url), let license = video.licence?.label else { throw CatalogError.unavailable }
        if let language = video.language?.id, !["ru", "en", "zxx"].contains(language) { throw CatalogError.unavailable }
        let files = (video.files ?? []) + (video.streamingPlaylists ?? []).flatMap { $0.files ?? [] }
        guard let file = DownloadPolicy.chooseFile(files, remaining: remaining, seconds: video.duration),
              let raw = file.fileDownloadUrl, let url = DownloadPolicy.publicURL(raw) else { throw CatalogError.unavailable }
        let creator = video.channel?.displayName ?? video.account?.displayName ?? video.channel?.name ?? "PeerTube"
        return DownloadableVideo(id: candidate.id, title: video.name, creator: creator, origin: origin.absoluteString, license: license, tags: [candidate.topic.tag], fileURL: url, estimatedBytes: file.size)
    }

    func download(_ video: DownloadableVideo, remaining: Int64) async throws -> URL {
        let cap = min(remaining, max(video.estimatedBytes + 1_000_000, video.estimatedBytes))
        guard DownloadPolicy.validTransfer(bytes: video.estimatedBytes, limit: cap), DownloadPolicy.publicURL(video.fileURL.absoluteString) != nil else { throw CatalogError.invalid }
        let (temporary, response) = try await session.download(for: URLRequest(url: video.fileURL), delegate: HTTPSGuard(limit: cap))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, DownloadPolicy.publicURL(final.absoluteString) != nil,
              DownloadPolicy.validTransfer(bytes: Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), limit: cap) else { throw CatalogError.invalid }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try FileManager.default.moveItem(at: temporary, to: local)
        return local
    }
}

enum CatalogError: LocalizedError {
    case invalid, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: return "Некорректный ответ каталога"
        case .unavailable: return "Ролик недоступен для скачивания"
        }
    }
}
