import AVFoundation
import SwiftUI
import UIKit

/// Native vertical paging. Only the current page can play; UIKit drives the interactive swipe animation.
struct ReelPager: UIViewControllerRepresentable {
    let clips: [Clip]
    let index: Int
    let active: Bool
    let videoURL: (Clip) -> URL
    let onIndexChanged: (Int) -> Void
    let onFinished: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .vertical)
        pager.view.backgroundColor = .black
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        context.coordinator.install(pager, at: index, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let oldIDs = coordinator.parent.clips.map(\.id)
        coordinator.parent = self
        let current = pager.viewControllers?.first as? ReelPageController
        if !active { current?.setActive(false) }
        guard !coordinator.transitioning else { return }
        if oldIDs != clips.map(\.id) || current == nil {
            coordinator.install(pager, at: index, animated: false)
        } else if current?.position != index {
            coordinator.install(pager, at: index, animated: true)
        } else {
            current?.setActive(active)
        }
    }

    static func dismantleUIViewController(_ pager: UIPageViewController, coordinator: Coordinator) {
        (pager.viewControllers?.first as? ReelPageController)?.setActive(false)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ReelPager
        var transitioning = false
        init(_ parent: ReelPager) { self.parent = parent }

        private func page(at index: Int) -> ReelPageController? {
            guard parent.clips.indices.contains(index) else { return nil }
            let clip = parent.clips[index]
            return ReelPageController(position: index, url: parent.videoURL(clip), finished: { [weak self] in self?.parent.onFinished(clip.id) })
        }

        func install(_ pager: UIPageViewController, at index: Int, animated: Bool) {
            guard let next = page(at: index) else { return }
            let old = pager.viewControllers?.first as? ReelPageController
            old?.setActive(false)
            let direction: UIPageViewController.NavigationDirection = index >= (old?.position ?? index) ? .forward : .reverse
            transitioning = animated
            pager.setViewControllers([next], direction: direction, animated: animated) { [weak self, weak next] finished in
                guard let self else { return }
                self.transitioning = false
                if let next, self.parent.index != next.position, self.parent.clips.indices.contains(self.parent.index) {
                    self.install(pager, at: self.parent.index, animated: false)
                    return
                }
                if finished || !animated { next?.setActive(self.parent.active) }
                else { (pager.viewControllers?.first as? ReelPageController)?.setActive(self.parent.active) }
            }
            if !animated { next.setActive(parent.active) }
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let reel = viewController as? ReelPageController else { return nil }
            return page(at: reel.position - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let reel = viewController as? ReelPageController else { return nil }
            return page(at: reel.position + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            (pageViewController.viewControllers?.first as? ReelPageController)?.setActive(false)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            guard let current = pageViewController.viewControllers?.first as? ReelPageController else { return }
            if completed {
                for case let page as ReelPageController in previousViewControllers { page.setActive(false) }
                parent.onIndexChanged(current.position)
            }
            current.setActive(parent.active)
        }
    }
}

final class ReelPageController: UIViewController, UIGestureRecognizerDelegate {
    let position: Int
    private let player: AVPlayer
    private let completed: () -> Void
    private let playerLayer = AVPlayerLayer()
    private let playGlyph = UIImageView(image: UIImage(systemName: "play.fill"))
    private let speedBadge = UILabel()
    private var active = false
    private var playing = true
    private var holding = false
    private var observer: NSObjectProtocol?
    private lazy var edgePress = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))

    init(position: Int, url: URL, finished: @escaping () -> Void) {
        self.position = position
        player = AVPlayer(url: url)
        completed = finished
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        edgePress.minimumPressDuration = 0.20
        edgePress.allowableMovement = 20
        edgePress.delegate = self
        tap.require(toFail: edgePress)
        view.addGestureRecognizer(edgePress)
        view.addGestureRecognizer(tap)

        playGlyph.tintColor = UIColor.white.withAlphaComponent(0.9)
        playGlyph.contentMode = .scaleAspectFit
        playGlyph.isUserInteractionEnabled = false
        playGlyph.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        playGlyph.layer.cornerRadius = 33
        playGlyph.isHidden = true
        view.addSubview(playGlyph)
        speedBadge.text = "2×  ▶▶"
        speedBadge.font = .systemFont(ofSize: 16, weight: .bold)
        speedBadge.textColor = .white
        speedBadge.textAlignment = .center
        speedBadge.backgroundColor = UIColor.black.withAlphaComponent(0.66)
        speedBadge.layer.cornerRadius = 18
        speedBadge.clipsToBounds = true
        speedBadge.isHidden = true
        speedBadge.isUserInteractionEnabled = false
        view.addSubview(speedBadge)

        if let item = player.currentItem {
            observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                guard let self, self.active else { return }
                self.completed()
                self.player.seek(to: .zero) { [weak self] _ in DispatchQueue.main.async { self?.applyRate() } }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
        playGlyph.frame = CGRect(x: view.bounds.midX - 33, y: view.bounds.midY - 33, width: 66, height: 66)
        speedBadge.frame = CGRect(x: view.bounds.midX - 47, y: view.safeAreaInsets.top + 88, width: 94, height: 36)
    }

    func setActive(_ value: Bool) {
        loadViewIfNeeded()
        guard active != value else { return }
        active = value
        if !value { holding = false; speedBadge.isHidden = true }
        applyRate()
    }

    private func applyRate() {
        let rate = PlaybackPolicy.rate(playing: active && playing, holding: holding)
        if rate == 0 { player.pause() } else { player.playImmediately(atRate: rate) }
        playGlyph.isHidden = !active || playing
    }

    @objc private func handleTap() {
        guard active else { return }
        playing.toggle(); applyRate()
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard active, playing else { return }
            holding = true; speedBadge.isHidden = false; applyRate()
        case .ended, .cancelled, .failed:
            holding = false; speedBadge.isHidden = true; applyRate()
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === edgePress else { return true }
        return PlaybackPolicy.isSpeedEdge(x: Double(touch.location(in: view).x), width: Double(view.bounds.width))
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; player.pause() }
}
