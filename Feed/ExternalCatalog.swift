import Foundation

struct ExternalVideo: Identifiable, Equatable, Hashable {
    let id: String
    let url: URL
    let title: String
    let folder: String
    let bytes: Int64
}

enum ExternalCatalog {
    static func scan(_ root: URL) throws -> [ExternalVideo] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let prefix = root.standardizedFileURL.path + "/"
        var result: [ExternalVideo] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()), url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let bytes = Int64(values.fileSize ?? 0)
            guard bytes > 0 else { continue }
            let modified = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            let folder = (relative as NSString).deletingLastPathComponent
            result.append(ExternalVideo(id: "\(root.lastPathComponent)|\(relative)|\(bytes)|\(modified)", url: url, title: url.deletingPathExtension().lastPathComponent, folder: folder, bytes: bytes))
        }
        if let scanError { throw scanError }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func resumeTime(position: Double, duration: Double) -> Double {
        guard position.isFinite, duration.isFinite, duration > 0, position > 0, position < duration - min(5, duration * 0.05) else { return 0 }
        return position
    }
}

struct WatchProgress: Codable {
    var position: Double
    var duration: Double
    var lastViewed: Date
    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
}
