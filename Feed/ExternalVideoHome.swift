import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private let accent = Color(red: 1, green: 0.14, blue: 0.20)

struct ExternalVideoHome: View {
    @EnvironmentObject private var store: ExternalVideoStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var tab: Filter = .all
    @State private var picker = false
    @State private var player: ExternalVideo?
    @State private var showSettings = false
    @State private var confirmCleanup = false
    @State private var confirmHistory = false
    enum Filter: String, CaseIterable { case all = "Все", resume = "Продолжить", history = "История" }

    var visible: [ExternalVideo] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.videos.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.folder.localizedCaseInsensitiveContains(query) }
        switch tab {
        case .all: return matches
        case .resume: return matches.filter { video in
            guard let item = store.progress(video) else { return false }
            return ExternalCatalog.resumeTime(position: item.position, duration: item.duration) > 0
        }.sorted { (store.progress($0)?.lastViewed ?? .distantPast) > (store.progress($1)?.lastViewed ?? .distantPast) }
        case .history: return matches.filter { store.progress($0) != nil }.sorted { (store.progress($0)?.lastViewed ?? .distantPast) > (store.progress($1)?.lastViewed ?? .distantPast) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск видео", text: $search).autocorrectionDisabled()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }.padding(13).background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(Filter.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            Text(item.rawValue).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                                .foregroundStyle(tab == item ? .black : .white).background(tab == item ? Color.white : Color.white.opacity(0.09), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 14)
            }
            ScrollView {
                VStack(spacing: 20) {
                    driveCard
                    if store.scanning { HStack(spacing: 12) { ProgressView(); Text("Читаем папку…").foregroundStyle(.secondary) }.padding(32) }
                    else if visible.isEmpty { emptyState }
                    else {
                        LazyVStack(spacing: 23) {
                            ForEach(visible) { video in
                                Button { player = video } label: { ExternalVideoCard(video: video, progress: store.progress(video)) }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(.bottom, 32)
            }.refreshable { store.reload() }
            bottomBar
        }
        .background(Color(red: 0.055, green: 0.055, blue: 0.065).ignoresSafeArea())
        .onAppear { store.restore() }
        .onChange(of: scenePhase) { phase in if phase == .active && player == nil { store.reload() } }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): store.choose(url)
            case .failure: store.message = "Папку открыть не удалось. Попробуй выбрать её ещё раз."
            }
        }
        .fullScreenCover(item: $player) { video in ExternalWatchScreen(video: video, store: store) }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack { RoundedRectangle(cornerRadius: 8).fill(accent).frame(width: 38, height: 27); Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
            Text("YouTube").font(.system(size: 22, weight: .bold, design: .default)).tracking(-1)
            Text("OFFLINE").font(.system(size: 9, weight: .black)).tracking(1.2).foregroundStyle(accent).padding(6).background(accent.opacity(0.13), in: Capsule())
            Spacer()
            Button { store.reload() } label: { Image(systemName: "arrow.clockwise").font(.title3).frame(width: 36, height: 42) }.disabled(store.scanning)
            Button { showSettings = true } label: { Image(systemName: "gearshape").font(.title3).frame(width: 36, height: 42) }
        }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var driveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(store.folder == nil ? .secondary : accent).frame(width: 44, height: 44).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.folder?.lastPathComponent ?? "Подключи флешку").font(.headline).lineLimit(1)
                    Text(store.folder == nil ? "Видео остаются на накопителе" : "\(store.videos.count) видео · без копирования").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { picker = true } label: { Text(store.folder == nil ? "Открыть" : "Папка").font(.caption.bold()).padding(.horizontal, 14).padding(.vertical, 10).background(accent, in: Capsule()).foregroundStyle(.white) }.buttonStyle(.plain).disabled(store.scanning)
            }
            if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(.orange) }
        }.padding(14).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 17)).padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.videos.isEmpty ? "film.stack" : "magnifyingglass").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(store.videos.isEmpty ? "Твоя библиотека" : "Здесь пока пусто").font(.title3.bold())
            Text(store.videos.isEmpty ? "Подключи USB-накопитель и выбери папку с MP4. Интернет не нужен." : "Измени поиск или выбери другой раздел.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if store.videos.isEmpty { Button("Выбрать папку") { picker = true }.buttonStyle(.borderedProminent).tint(accent).disabled(store.scanning) }
        }.frame(maxWidth: .infinity).padding(32)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            bottomItem("Главная", icon: "house.fill", target: .all)
            bottomItem("Продолжить", icon: "play.rectangle", target: .resume)
            bottomItem("История", icon: "clock.arrow.circlepath", target: .history)
        }.padding(.top, 10).padding(.bottom, 4).background(Color.black.opacity(0.35))
    }

    private func bottomItem(_ title: String, icon: String, target: Filter) -> some View {
        Button { tab = target } label: { VStack(spacing: 5) { Image(systemName: icon).font(.system(size: 22)); Text(title).font(.caption2) }.frame(maxWidth: .infinity).foregroundStyle(tab == target ? accent : .secondary) }.buttonStyle(.plain)
    }

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("Хранилище") {
                    Text("Файлы читаются непосредственно с выбранного накопителя. Приложение не сохраняет копии видео.")
                    if store.hasLegacyFiles { Button("Очистить старые локальные видео", role: .destructive) { confirmCleanup = true } }
                }
                Section("История") { Button("Очистить историю просмотров", role: .destructive) { confirmHistory = true } }
            }.navigationTitle("Настройки").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showSettings = false } } }
            .confirmationDialog("Удалить старые ролики из памяти приложения? Флешка не будет затронута.", isPresented: $confirmCleanup, titleVisibility: .visible) { Button("Удалить", role: .destructive) { store.clearOldLocalVideos() } }
            .confirmationDialog("Очистить историю?", isPresented: $confirmHistory, titleVisibility: .visible) { Button("Очистить", role: .destructive) { store.clearHistory() } }
        }
    }
}

private struct VideoPreview {
    let image: UIImage?
    let duration: Double?
}

private final class PreviewBox: NSObject {
    let preview: VideoPreview
    init(_ preview: VideoPreview) { self.preview = preview }
}

private enum PreviewCache {
    static let cache: NSCache<NSString, PreviewBox> = { let result = NSCache<NSString, PreviewBox>(); result.totalCostLimit = 32 * 1024 * 1024; result.countLimit = 128; return result }()
    static func load(_ video: ExternalVideo) async -> VideoPreview {
        if let cached = cache.object(forKey: video.id as NSString) { return cached.preview }
        let result = await Task.detached(priority: .utility) { () -> VideoPreview in
            let asset = AVURLAsset(url: video.url)
            let duration = (try? await asset.load(.duration))?.seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            let image = try? generator.copyCGImage(at: CMTime(seconds: min(8, max(0, (duration ?? 0) * 0.05)), preferredTimescale: 600), actualTime: nil)
            return VideoPreview(image: image.map { UIImage(cgImage: $0) }, duration: duration?.isFinite == true ? duration : nil)
        }.value
        if let image = result.image { cache.setObject(PreviewBox(result), forKey: video.id as NSString, cost: Int(image.size.width * image.size.height * 4)) }
        return result
    }
}

private struct ExternalVideoCard: View {
    let video: ExternalVideo
    let progress: WatchProgress?
    @State private var preview: VideoPreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Color.white.opacity(0.07)
                if let image = preview?.image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).background(.black) }
                else { Image(systemName: "play.rectangle").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                if let duration = preview?.duration ?? progress?.duration { Text(formatDuration(duration)).font(.caption2.monospacedDigit().bold()).padding(6).background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 5)).padding(8) }
                if let progress, progress.fraction > 0 { GeometryReader { geo in VStack { Spacer(); Rectangle().fill(accent).frame(width: geo.size.width * progress.fraction, height: 3).frame(maxWidth: .infinity, alignment: .leading) } } }
            }.aspectRatio(16/9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)).clipped()
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "film").font(.headline).frame(width: 35, height: 35).background(Color.white.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.white)
                    Text((video.folder.isEmpty ? "Локальное видео" : video.folder) + " · " + ByteCountFormatter.string(fromByteCount: video.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary).padding(.top, 5)
            }.padding(.horizontal, 2)
        }.padding(.horizontal, 16).task(id: video.id) { preview = await PreviewCache.load(video) }
    }
}

private func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let time = Int(seconds), h = time / 3600, m = (time % 3600) / 60, s = time % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
