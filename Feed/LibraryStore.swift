import AVFoundation
import CryptoKit
import Foundation
import Network
import SwiftUI

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var preferences = Preferences()
    @Published var status = ""
    @Published var busy = false
    @Published private(set) var refreshing = false
    @Published private(set) var downloadStatus = ""
    @Published private(set) var wifiAvailable = false
    private var refreshTask: Task<Void, Never>?
    private var downloadedRemoteIDs = Set<String>()
    private let pathMonitor = NWPathMonitor()
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var writable = true

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("OfflineFeed", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let index = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: index.path) {
                clips = try decoder.decode([Clip].self, from: Data(contentsOf: index))
                clips.removeAll { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
            }
            let prefs = directory.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: prefs.path) {
                preferences = try decoder.decode(Preferences.self, from: Data(contentsOf: prefs))
            }
            let history = directory.appendingPathComponent("remote-history.json")
            if let data = try? Data(contentsOf: history), let ids = try? decoder.decode(Set<String>.self, from: data) { downloadedRemoteIDs = ids }
            downloadedRemoteIDs.formUnion(clips.compactMap(\.remoteID))
        } catch { writable = false; status = "Хранилище не удалось открыть. Не удаляй приложение: \(error.localizedDescription)" }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.wifiAvailable = connected }
        }
        pathMonitor.start(queue: DispatchQueue(label: "offline-feed-network"))
    }

    func url(for clip: Clip) -> URL { directory.appendingPathComponent(clip.filename) }

    private func save() throws {
        guard writable else { throw LibraryError.unavailable }
        try encoder.encode(clips).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }

    func updatePreferences(_ prefs: Preferences) {
        do {
            guard writable else { throw LibraryError.unavailable }
            try encoder.encode(prefs).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
            preferences = prefs
            status = "Интересы сохранены"
        } catch { status = error.localizedDescription }
    }

    func importPreferences(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000 else { throw LibraryError.invalid }
            updatePreferences(try decoder.decode(Preferences.self, from: data))
        } catch { status = "Не удалось прочитать профиль интересов" }
    }

    func importVideos(_ urls: [URL], creator: String, source: String, tags: [String]) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        var added = 0
        var skipped = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try await add(url, title: url.deletingPathExtension().lastPathComponent, creator: creator, source: source, tags: tags)
                added += 1
            } catch { skipped += 1; status = error.localizedDescription }
        }
        status = "Добавлено: \(added) · Пропущено: \(skipped)" + (skipped > 0 ? " (повтор, неверный файл или лимит)" : "")
    }

    private func add(_ input: URL, title: String, creator: String, source: String, tags: [String], remoteID: String? = nil, originURL: String? = nil, license: String? = nil) async throws {
        guard writable else { throw LibraryError.unavailable }
        let size = Int64(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard size > 0, FeedLogic.fits(existing: clips, incomingBytes: size) else { throw LibraryError.limit }
        let ext = input.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw LibraryError.invalid }
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw LibraryError.invalid }
        if remoteID != nil {
            guard (5...181).contains(duration), size <= Int64(duration * 345_000) else { throw LibraryError.invalid }
        }
        let id = try await Task.detached(priority: .utility) { try Self.fileDigest(input) }.value
        guard !clips.contains(where: { $0.id == id }) else { throw LibraryError.duplicate }
        let filename = id + "." + ext
        let dest = directory.appendingPathComponent(filename)
        guard FeedLogic.fits(existing: clips, incomingBytes: size) else { throw LibraryError.limit }
        try FileManager.default.copyItem(at: input, to: dest)
        let actual = Int64(try dest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard actual == size else { try? FileManager.default.removeItem(at: dest); throw LibraryError.invalid }
        let old = clips
        clips.append(Clip(id: id, filename: filename, title: title, creator: creator, source: source, tags: tags, bytes: actual, seconds: duration, remoteID: remoteID, originURL: originURL, license: license))
        do { try save() } catch { clips = old; try? FileManager.default.removeItem(at: dest); throw error }
    }

    func startRefresh(removeWatchedFirst: Bool) {
        guard !busy, writable, FeedLogic.remaining(clips) < FeedLogic.target else {
            if FeedLogic.remaining(clips) >= FeedLogic.target { downloadStatus = "Запас на 5 часов уже готов" }
            return
        }
        guard wifiAvailable else { downloadStatus = "Подключись к обычному Wi-Fi для загрузки"; return }
        if removeWatchedFirst { removeWatched() }
        guard FeedLogic.used(clips) < FeedLogic.limit else { downloadStatus = "Лимит 6 ГБ уже заполнен"; return }
        busy = true; refreshing = true
        downloadStatus = "Ищем разрешённые ролики по твоим темам…"
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRefresh()
        }
    }

    func stopRefresh() { refreshTask?.cancel(); downloadStatus = "Останавливаем загрузку…" }

    private func remember(_ id: String) {
        downloadedRemoteIDs.insert(id)
        try? encoder.encode(downloadedRemoteIDs).write(to: directory.appendingPathComponent("remote-history.json"), options: .atomic)
    }

    private func runRefresh() async {
        defer { busy = false; refreshing = false; refreshTask = nil }
        let catalog = PeerTubeCatalog()
        let topics = DownloadPolicy.searchTopics(preferences)
        var added = 0, failed = 0, considered = 0, searched = 0, attempted = 0
        var encountered = downloadedRemoteIDs
        var related: [CatalogCandidate] = [], discovery: [CatalogCandidate] = []
        // Two pages per topic, one at a time. Each download uses the publisher's official download endpoint.
        let savedPage = max(0, UserDefaults.standard.integer(forKey: "peerTubeSearchPage")) % 10
        for page in savedPage..<(savedPage + 2) {
            for topic in topics {
                if Task.isCancelled { downloadStatus = "Остановлено · сохранено \(added)"; return }
                guard wifiAvailable else { downloadStatus = "Wi-Fi отключён. Попробуй ещё раз при подключении."; return }
                attempted += 1
                downloadStatus = "Поиск: \(attempted) из \(topics.count * 2)"
                do {
                    let matches = try await catalog.search(topic, page: page)
                    for match in matches where !encountered.contains(match.id) {
                        if topic.discovery { discovery.append(match) } else { related.append(match) }
                    }
                    searched += 1
                } catch { failed += 1 }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        if searched > 0 { UserDefaults.standard.set((savedPage + 2) % 10, forKey: "peerTubeSearchPage") }
        let candidates = DownloadPolicy.mix(related, discovery)
        if candidates.isEmpty { downloadStatus = "Нет новых доступных роликов. Проверь Wi-Fi или повтори позже."; return }
        for item in candidates {
            if Task.isCancelled { break }
            if !wifiAvailable { downloadStatus = "Wi-Fi отключён · сохранено \(added)"; return }
            if FeedLogic.remaining(clips) >= FeedLogic.target { break }
            let remaining = FeedLogic.limit - FeedLogic.used(clips)
            if remaining < 100_000 { break }
            // Check actual device capacity as well as the app's own budget.
            let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? remaining
            let allowed = min(remaining, max(0, free - 100_000_000))
            if allowed < 100_000 { downloadStatus = "На iPhone недостаточно свободного места"; return }
            guard encountered.insert(item.id).inserted else { continue }
            considered += 1
            downloadStatus = "Загружено \(added) · проверено \(considered)/\(candidates.count) · \(Int(FeedLogic.remaining(clips) / 60)) мин"
            do {
                let video = try await catalog.available(item, remaining: allowed)
                let file = try await catalog.download(video, remaining: allowed)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                do {
                    try await add(file, title: video.title, creator: video.creator, source: "PeerTube", tags: video.tags, remoteID: video.id, originURL: video.origin, license: video.license)
                    remember(video.id)
                    added += 1
                } catch LibraryError.duplicate { remember(video.id) }
            } catch { failed += 1 }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let minutes = Int(FeedLogic.remaining(clips) / 60)
        if Task.isCancelled { downloadStatus = "Остановлено · сохранено \(added) · запас \(minutes) мин" }
        else if FeedLogic.remaining(clips) >= FeedLogic.target { downloadStatus = "Готово: запас на 5 часов · добавлено \(added)" }
        else if FeedLogic.used(clips) >= FeedLogic.limit - 100_000 { downloadStatus = "Лимит памяти достигнут · запас \(minutes) мин" }
        else { downloadStatus = "Добавлено \(added) · запас \(minutes) мин. Остальные доступные ролики закончились или не подошли (пропущено \(failed))." }
    }

    nonisolated private static func fileDigest(_ input: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func setWatched(_ id: String) { mutate(id) { $0.watched = true } }
    func like(_ id: String) {
        mutate(id) { $0.liked.toggle() }
        if let clip = clips.first(where: { $0.id == id }), clip.liked {
            var updated = preferences
            for tag in clip.tags where !updated.topics.contains(tag) { updated.topics.append(tag) }
            updatePreferences(updated)
        }
    }

    private func mutate(_ id: String, _ change: (inout Clip) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == id }), writable else { return }
        let old = clips[index]
        change(&clips[index])
        do { try save() } catch { clips[index] = old; status = error.localizedDescription }
    }

    func removeWatched() {
        guard writable, !busy else { return }
        let removed = clips.filter { $0.watched && !$0.liked }
        let old = clips
        clips.removeAll { $0.watched && !$0.liked }
        do {
            try save()
            for clip in removed { try? FileManager.default.removeItem(at: url(for: clip)) }
            status = "Удалено просмотренных: \(removed.count)"
        } catch { clips = old; status = error.localizedDescription }
    }
}

enum LibraryError: LocalizedError {
    case limit, invalid, duplicate, unavailable
    var errorDescription: String? {
        switch self {
        case .limit: return "Не хватает места в лимите 6 ГБ"
        case .invalid: return "Неподдерживаемое или повреждённое видео"
        case .duplicate: return "Это видео уже сохранено"
        case .unavailable: return "Хранилище недоступно"
        }
    }
}
