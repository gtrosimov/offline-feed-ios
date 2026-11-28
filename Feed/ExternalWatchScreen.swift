import AVFoundation
import AVKit
import SwiftUI

@MainActor private final class ExternalPlaybackSession: ObservableObject {
    let player: AVPlayer
    let video: ExternalVideo
    private let store: ExternalVideoStore
    @Published var speed: Float = 1
    @Published var duration: Double = 0
    @Published var errorMessage = ""
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var active = false

    init(video: ExternalVideo, store: ExternalVideoStore) {
        self.video = video; self.store = store
        player = AVPlayer(url: video.url)
    }

    func start() async {
        guard !active else { return }; active = true
        guard let item = player.currentItem else { errorMessage = "Файл недоступен"; return }
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            if item.status == .failed { Task { @MainActor [weak self] in self?.errorMessage = "Видео не удалось открыть. Проверь подключение флешки и формат файла." } }
        }
        do {
            let value = try await item.asset.load(.duration).seconds
            let playable = try await item.asset.load(.isPlayable)
            guard active, !Task.isCancelled else { return }
            guard playable, value.isFinite, value > 0 else { errorMessage = "Формат видео не поддерживается iPhone."; return }
            duration = value
            let position = ExternalCatalog.resumeTime(position: store.progress(video)?.position ?? 0, duration: value)
            if position > 0 { await player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
            guard active else { return }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.saveProgress() }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in if let self { self.store.record(self.video, position: self.duration, duration: self.duration) } }
            }
            player.playImmediately(atRate: speed)
        } catch { if active { errorMessage = "Не удалось прочитать файл с накопителя." } }
    }

    func setSpeed(_ value: Float) {
        speed = value; player.defaultRate = value
        if player.rate != 0 { player.playImmediately(atRate: value) }
    }

    func saveProgress() {
        guard duration > 0 else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { store.record(video, position: seconds, duration: duration) }
    }

    func stop() {
        active = false; saveProgress(); player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}

struct ExternalWatchScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback: ExternalPlaybackSession
    let video: ExternalVideo

    init(video: ExternalVideo, store: ExternalVideoStore) {
        self.video = video; _playback = StateObject(wrappedValue: ExternalPlaybackSession(video: video, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Label("Назад", systemImage: "chevron.left").font(.subheadline.weight(.semibold)) }
                Spacer()
                Menu {
                    ForEach([Float(0.5),0.75,1,1.25,1.5,1.75,2], id: \.self) { speed in
                        Button { playback.setSpeed(speed) } label: { if speed == playback.speed { Label("\(speed, specifier: "%g")×", systemImage: "checkmark") } else { Text("\(speed, specifier: "%g")×") } }
                    }
                } label: { Label("\(playback.speed, specifier: "%g")×", systemImage: "speedometer").font(.subheadline.weight(.semibold)) }
            }.padding(16).foregroundStyle(.white)
            ZStack {
                Color.black
                NativeExternalPlayer(player: playback.player)
                if !playback.errorMessage.isEmpty { VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(.largeTitle); Text(playback.errorMessage).multilineTextAlignment(.center); Button("Закрыть") { dismiss() }.buttonStyle(.borderedProminent) }.padding(24).background(.black.opacity(0.9)) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(video.title).font(.title3.bold()).lineLimit(3)
                HStack(spacing: 8) { Image(systemName: "externaldrive.fill").foregroundStyle(.red); Text("С флешки · офлайн").font(.caption).foregroundStyle(.secondary); Spacer() }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.background(Color.black.ignoresSafeArea())
        .task { await playback.start() }
        .onDisappear { playback.stop() }
        .onChange(of: scenePhase) { phase in if phase != .active { playback.saveProgress(); playback.player.pause() } }
    }
}

private struct NativeExternalPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player; controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        controller.videoGravity = .resizeAspect
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { if controller.player !== player { controller.player = player } }
}
