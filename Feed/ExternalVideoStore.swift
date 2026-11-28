import Foundation
import SwiftUI

@MainActor final class ExternalVideoStore: ObservableObject {
    @Published private(set) var videos: [ExternalVideo] = []
    @Published private(set) var history: [String: WatchProgress] = [:]
    @Published private(set) var folder: URL?
    @Published private(set) var scanning = false
    @Published var message = ""
    @Published private(set) var hasLegacyFiles = false
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "externalVideoFolder.v2"
    private let historyKey = "externalVideoHistory.v2"
    private var scope: URL?
    private var scanTask: Task<Void, Never>?
    private var legacyURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineFeed", isDirectory: true) }

    init() {
        if let data = defaults.data(forKey: historyKey), let restored = try? JSONDecoder().decode([String: WatchProgress].self, from: data) { history = restored }
        hasLegacyFiles = FileManager.default.fileExists(atPath: legacyURL.path)
    }

    func restore() {
        guard folder == nil, !scanning, let data = defaults.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            try attach(url, saveBookmark: stale)
        } catch { message = "Подключи флешку и выбери папку снова." }
    }

    func choose(_ url: URL) {
        guard !scanning else { return }
        do { try attach(url, saveBookmark: true) }
        catch { message = "Не удалось открыть папку. Проверь подключение накопителя и разрешение в «Файлах»." }
    }

    private func attach(_ url: URL, saveBookmark: Bool) throws {
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        if let old = scope { old.stopAccessingSecurityScopedResource() }
        scope = url; folder = url; videos = []; message = ""
        if saveBookmark {
            if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { defaults.set(data, forKey: bookmarkKey) }
            else { defaults.removeObject(forKey: bookmarkKey); message = "Папка открыта, но при следующем запуске её потребуется выбрать снова." }
        }
        reload()
    }

    func reload() {
        guard !scanning else { return }
        guard let root = scope else { restore(); return }
        scanning = true
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[ExternalVideo], Error> in
                var coordinationError: NSError?
                var result: Result<[ExternalVideo], Error> = .failure(CocoaError(.fileReadUnknown))
                NSFileCoordinator().coordinate(readingItemAt: root, options: .withoutChanges, error: &coordinationError) { coordinated in
                    result = Result { try ExternalCatalog.scan(coordinated) }
                }
                if let coordinationError { return .failure(coordinationError) }
                return result
            }.value
            guard let self else { return }
            self.scanning = false
            switch result {
            case .success(let files): self.videos = files; self.message = files.isEmpty ? "В выбранной папке нет MP4, MOV или M4V." : ""
            case .failure: self.videos = []; self.message = "Накопитель недоступен. Подключи его и обнови список или выбери папку снова."
            }
        }
    }

    func progress(_ video: ExternalVideo) -> WatchProgress? { history[video.id] }

    func record(_ video: ExternalVideo, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0, position >= 0 else { return }
        history[video.id] = WatchProgress(position: min(position, duration), duration: duration, lastViewed: .now)
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: historyKey) }
    }

    func clearHistory() { history = [:]; defaults.removeObject(forKey: historyKey) }

    func clearOldLocalVideos() {
        do {
            if FileManager.default.fileExists(atPath: legacyURL.path) { try FileManager.default.removeItem(at: legacyURL) }
            hasLegacyFiles = false
        } catch { message = "Не удалось удалить старые локальные видео." }
    }

    deinit { scope?.stopAccessingSecurityScopedResource() }
}
