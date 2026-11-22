import AVFoundation
import CryptoKit
import Foundation
import SwiftUI

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var preferences = Preferences()
    @Published var status = ""
    @Published var busy = false
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
        } catch { writable = false; status = "Хранилище не удалось открыть. Не удаляй приложение: \(error.localizedDescription)" }
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

    func importVideos(_ urls: [URL], creator: String, source: String, tags: [String], confirmedRussian: Bool) async {
        guard !busy else { return }
        guard confirmedRussian, ["instagram", "tiktok"].contains(FeedLogic.normalized(source)) else { status = "Выбери русскоязычные видео из Instagram или TikTok"; return }
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

    private func add(_ input: URL, title: String, creator: String, source: String, tags: [String]) async throws {
        guard writable else { throw LibraryError.unavailable }
        let size = Int64(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard size > 0, FeedLogic.fits(existing: clips, incomingBytes: size) else { throw LibraryError.limit }
        let ext = input.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw LibraryError.invalid }
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw LibraryError.invalid }
        let id = try await Task.detached(priority: .utility) { try Self.fileDigest(input) }.value
        if let existing = clips.firstIndex(where: { $0.id == id }) {
            if !FeedLogic.isRussianSocial(clips[existing]) {
                let old = clips[existing]
                clips[existing].source = source; clips[existing].creator = creator; clips[existing].tags = tags; clips[existing].language = "ru"
                clips[existing].remoteID = nil; clips[existing].originURL = nil; clips[existing].license = nil
                clips[existing].watched = false
                do { try save(); return } catch { clips[existing] = old; throw error }
            }
            throw LibraryError.duplicate
        }
        let filename = id + "." + ext
        let dest = directory.appendingPathComponent(filename)
        guard FeedLogic.fits(existing: clips, incomingBytes: size) else { throw LibraryError.limit }
        try FileManager.default.copyItem(at: input, to: dest)
        let actual = Int64(try dest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard actual == size else { try? FileManager.default.removeItem(at: dest); throw LibraryError.invalid }
        let old = clips
        clips.append(Clip(id: id, filename: filename, title: title, creator: creator, source: source, tags: tags, bytes: actual, seconds: duration, language: "ru"))
        do { try save() } catch { clips = old; try? FileManager.default.removeItem(at: dest); throw error }
    }

    func removeOldPeerTube() { removeClips { FeedLogic.normalized($0.source) == "peertube" } }

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
        removeClips { $0.watched && !$0.liked }
    }

    private func removeClips(where predicate: (Clip) -> Bool) {
        guard writable, !busy else { return }
        let removed = clips.filter(predicate)
        let old = clips
        clips.removeAll(where: predicate)
        do {
            try save()
            for clip in removed { try? FileManager.default.removeItem(at: url(for: clip)) }
            status = "Удалено роликов: \(removed.count)"
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
