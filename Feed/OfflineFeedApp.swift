import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main struct OfflineFeedApp: App {
    @StateObject private var library = ExternalVideoStore()
    var body: some Scene {
        WindowGroup { ExternalVideoHome().environmentObject(library).preferredColorScheme(.dark) }
    }
}

struct FeedScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var queue: [Clip] = []
    @State private var index = 0
    @State private var settings = false

    private var current: Clip? { queue.indices.contains(index) ? queue[index] : nil }
    private var liveClip: Clip? { current.flatMap { item in library.clips.first { $0.id == item.id } } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let clip = liveClip {
                ReelPager(clips: queue, index: index, active: scenePhase == .active && !settings, videoURL: { library.url(for: $0) }, onIndexChanged: { next in
                    if next > index, let old = current { library.setWatched(old.id) }
                    index = next
                }, onFinished: { library.setWatched($0) }).ignoresSafeArea()
                LinearGradient(colors: [.clear,.black.opacity(0.85)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false).ignoresSafeArea()
                VStack {
                    header
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(clip.creator.isEmpty ? "Моя подборка" : "@" + clip.creator).font(.headline).lineLimit(1)
                            Text(clip.title).font(.subheadline).lineLimit(2)
                            Text([clip.source, clip.tags.joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                        }.allowsHitTesting(false)
                        Spacer()
                        VStack(spacing: 22) {
                            action(clip.liked ? "heart.fill" : "heart", "Нравится", color: clip.liked ? .pink : .white) { library.like(clip.id) }
                            action("chevron.down.circle", "Дальше") { advance(1) }
                            action("chevron.up.circle", "Назад") { advance(-1) }
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
            } else {
                VStack(spacing: 22) {
                    header
                    Spacer()
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 70, weight: .light)).foregroundStyle(.cyan)
                    Text(library.clips.contains(where: FeedLogic.isRussianSocial) ? "Подборка закончилась" : "Твоя лента ждёт").font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text("Добавь русскоязычные Reels и TikTok из своих сохранённых видео.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 20)
                    Button { settings = true } label: { Label("Открыть источники", systemImage: "arrow.down.circle.fill").font(.headline).padding(16).frame(maxWidth: 300).background(.pink, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white) }.buttonStyle(.plain)
                    Spacer()
                    Text("Всё на iPhone · интернет не нужен").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 20)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: library.busy) { busy in if !busy && current == nil && !settings { reload() } }
        .onChange(of: library.clips.count) { _ in if current == nil && !settings { reload() } }
        .sheet(isPresented: $settings, onDismiss: { reload() }) { LibraryScreen().environmentObject(library) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ЛЕНТА").font(.system(size: 26, weight: .black, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("ОФЛАЙН · " + timeText(FeedLogic.socialRemaining(library.clips))).font(.caption2.bold()).foregroundStyle(.green)
                }
            }.allowsHitTesting(false)
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 22, weight: .semibold)).frame(width: 46, height: 46).background(.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Библиотека и настройки")
        }.padding(.horizontal, 20).padding(.top, 6)
    }

    private func action(_ symbol: String, _ name: String, color: Color = .white, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(color); Text(name).font(.caption2).foregroundStyle(.white) }
        }.buttonStyle(.plain)
    }

    private func reload() { queue = FeedLogic.socialQueue(library.clips, library.preferences); index = 0 }
    private func advance(_ amount: Int) {
        if amount > 0, let clip = current { library.setWatched(clip.id) }
        index = max(0, min(queue.count, index + amount))
    }
}

func timeText(_ seconds: Double) -> String {
    let minutes = max(0, Int(seconds / 60))
    return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
}

struct LibraryScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var creator = ""
    @State private var source = "Instagram"
    @State private var tags = ""
    @State private var interests = ""
    @State private var authors = ""
    @State private var importMode: ImportMode = .video
    @State private var showImporter = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importingPhotos = false
    @State private var confirmRemove = false
    @State private var confirmPeerTubeRemoval = false
    @State private var russianConfirmed = false
    enum ImportMode: String, Identifiable { case video, profile; var id: String { rawValue } }
    private var occupied: Int64 { FeedLogic.used(library.clips) }
    private func parts(_ string: String) -> [String] { string.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("ЗАПАС НА ОТКЛЮЧЕНИЕ").font(.caption.bold()).foregroundStyle(.cyan)
                        Text(timeText(FeedLogic.socialRemaining(library.clips))).font(.system(size: 37, weight: .bold, design: .rounded))
                        ProgressView(value: min(1, Double(occupied) / Double(FeedLogic.limit))).tint(.cyan)
                        HStack { Text(String(format: "%.2f ГБ / 6 ГБ", Double(occupied) / 1e9)); Spacer(); Text("\(library.clips.filter(FeedLogic.isRussianSocial).count) видео") }.font(.caption).foregroundStyle(.secondary)
                    }.panel()
                    VStack(alignment: .leading, spacing: 13) {
                        HStack { Text("Instagram и TikTok").font(.title3.bold()); Spacer(); Image(systemName: "globe").foregroundStyle(.pink) }
                        Text("Открой свою настоящую ленту. Если у ролика есть штатная кнопка скачивания, сохрани его на iPhone, затем добавь через «Фото» ниже. Прямое автоматическое скачивание рекомендаций не поддерживается официальными API.").font(.footnote).foregroundStyle(.secondary)
                        ProgressView(value: min(1, FeedLogic.socialRemaining(library.clips) / FeedLogic.target)).tint(.pink)
                        HStack {
                            Link(destination: SocialSource.instagram) { Label("Reels", systemImage: "camera.fill").frame(maxWidth: .infinity).padding(12).background(.pink.opacity(0.85), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white) }
                            Link(destination: SocialSource.tiktok) { Label("TikTok", systemImage: "music.note").frame(maxWidth: .infinity).padding(12).background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white) }
                        }.font(.headline)
                        if !library.preferences.instagramCreators.isEmpty {
                            Text("Твои любимые авторы").font(.caption.bold()).foregroundStyle(.secondary)
                            ForEach(Array(library.preferences.instagramCreators.enumerated()), id: \.offset) { _, author in
                                if let url = SocialSource.instagramProfile(author) {
                                    Link(destination: url) { HStack { Text(author); Spacer(); Image(systemName: "arrow.up.right") }.font(.subheadline) }
                                } else {
                                    HStack { Text(author).font(.subheadline); Spacer(); Text("Уточни @ник").font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }.panel()
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Добавить ролики").font(.title3.bold())
                        Text("Выбери разрешённые к скачиванию русскоязычные ролики из «Фото» или «Файлов». Можно добавить сразу много видео одного источника.").font(.footnote).foregroundStyle(.secondary)
                        Picker("Источник", selection: $source) { Text("Instagram").tag("Instagram"); Text("TikTok").tag("TikTok") }.pickerStyle(.segmented)
                        TextField("Автор (необязательно)", text: $creator).textFieldStyle(.roundedBorder)
                        TextField("Темы через запятую", text: $tags).textFieldStyle(.roundedBorder)
                        Toggle("Все выбранные ролики на русском", isOn: $russianConfirmed).tint(.pink)
                        PhotosPicker(selection: $photos, maxSelectionCount: 200, matching: .videos) {
                            Label("Из Фото", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity).padding(14).background(.cyan, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black).font(.headline)
                        }.buttonStyle(.plain).disabled(library.busy || importingPhotos || !russianConfirmed)
                        Button { importMode = .video; showImporter = true } label: { Label("Из Файлов", systemImage: "folder").frame(maxWidth: .infinity).padding(10) }.buttonStyle(.bordered).disabled(library.busy || importingPhotos || !russianConfirmed)
                        if library.busy || importingPhotos { ProgressView() }
                        if !library.status.isEmpty { Text(library.status).font(.caption).foregroundStyle(.secondary) }
                    }.panel()
                    VStack(alignment: .leading, spacing: 13) {
                        Text("Мои рекомендации").font(.title3.bold())
                        HStack(spacing: 5) { Rectangle().fill(.pink).frame(height: 6); Rectangle().fill(.cyan).frame(height: 6); Rectangle().fill(.purple).frame(height: 6) }.clipShape(Capsule())
                        Text("35% авторы · 45% похожее · 20% новое").font(.caption).foregroundStyle(.secondary)
                        Text("Любимые авторы").font(.caption.bold()); TextEditor(text: $authors).frame(height: 82).padding(6).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.13)))
                        Text("Интересы").font(.caption.bold()); TextEditor(text: $interests).frame(height: 82).padding(6).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.13)))
                        Button("Сохранить интересы") { var updated = library.preferences; updated.instagramCreators = parts(authors); updated.topics = parts(interests); library.updatePreferences(updated) }.buttonStyle(.borderedProminent).tint(.cyan)
                        Button { importMode = .profile; showImporter = true } label: { Label("Импорт профиля интересов (.json)", systemImage: "person.crop.circle.badge.plus") }.font(.footnote)
                    }.panel()
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Удалить просмотренные (кроме любимых)", systemImage: "trash") }.buttonStyle(.bordered).disabled(library.busy)
                    if library.clips.contains(where: { FeedLogic.normalized($0.source) == "peertube" }) {
                        Button(role: .destructive) { confirmPeerTubeRemoval = true } label: { Label("Удалить старые видео PeerTube", systemImage: "trash") }.buttonStyle(.bordered).disabled(library.busy)
                        Text("Ролики из старого каталога скрыты из ленты; удаление освобождает место.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Сохранённые ролики из библиотеки доступны офлайн. Пароли и аккаунты не запрашиваются.").font(.footnote).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationTitle("Библиотека").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .onAppear { fillPreferences() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importMode == .profile ? [.json] : [.movie, .mpeg4Movie, .quickTimeMovie], allowsMultipleSelection: true) { result in
                let mode = importMode
                switch result {
                case .success(let urls):
                    if mode == .profile, let url = urls.first { library.importPreferences(url); fillPreferences() }
                    else { let c = creator, s = source, t = parts(tags), ru = russianConfirmed; Task { await library.importVideos(urls, creator: c, source: s, tags: t, confirmedRussian: ru) } }
                case .failure(let error): library.status = error.localizedDescription
                }
            }
            .onChange(of: photos) { items in
                guard !items.isEmpty, !importingPhotos else { return }
                importingPhotos = true
                let author = creator, origin = source, labels = parts(tags), ru = russianConfirmed
                Task { @MainActor in
                    var total = 0
                    for item in items {
                        if let movie = try? await item.loadTransferable(type: ImportedMovie.self) {
                            let oldCount = library.clips.count
                            await library.importVideos([movie.url], creator: author, source: origin, tags: labels, confirmedRussian: ru)
                            try? FileManager.default.removeItem(at: movie.url)
                            total += max(0, library.clips.count - oldCount)
                        }
                    }
                    library.status = "Добавлено из Фото: \(total) из \(items.count)"
                    photos = []; importingPhotos = false
                }
            }
            .confirmationDialog("Удалить просмотренные ролики?", isPresented: $confirmRemove, titleVisibility: .visible) { Button("Удалить", role: .destructive) { library.removeWatched() } }
            .confirmationDialog("Удалить только старые видео PeerTube?", isPresented: $confirmPeerTubeRemoval, titleVisibility: .visible) { Button("Удалить", role: .destructive) { library.removeOldPeerTube() } }
        }
    }
    private func fillPreferences() { authors = library.preferences.instagramCreators.joined(separator: ", "); interests = library.preferences.topics.joined(separator: ", ") }
}

struct ImportedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie, importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: path)
            return ImportedMovie(url: path)
        })
    }
}

private extension View {
    func panel() -> some View { padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18)) }
}
