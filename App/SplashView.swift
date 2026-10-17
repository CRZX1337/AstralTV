import SwiftUI
import AVFoundation
import UIKit

// MARK: - Splash View
// Single SwiftUI layout for all platforms. Sizing adapts via compile-time
// platform flags (#if os) and, on iOS/iPadOS, the horizontal size class
// so iPhones and iPads each get proportionate logo/text sizes.

struct SplashView: View {
    @Binding var isFinished: Bool

    var body: some View {
        VideoSplashView(isFinished: $isFinished)
    }
}

// MARK: - Video Splash (iPhone/iPad)
// Plays the branded splash video (AstralSplash.mp4) full-bleed and muted,
// once, then hands off to the app. Fills the iPhone screen; letterboxed on
// iPad. tvOS and macOS keep the static logo splash below.

private struct VideoSplashView: View {
    @Binding var isFinished: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = Bundle.main.url(forResource: "AstralSplash", withExtension: "mp4") {
                SplashPlayerLayerView(
                    url: url,
                    fillScreen: sizeClass == .compact,
                    onFinished: { isFinished = true }
                )
                .ignoresSafeArea()
            } else {
                UniversalSplashView(isFinished: $isFinished)
            }
        }
        .onAppear {
            // Safety net: never strand the user on the splash if the video
            // fails to load or reach its end (AVPlayer wouldn't call back).
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                isFinished = true
            }
        }
    }
}

private struct SplashPlayerLayerView: UIViewRepresentable {
    let url: URL
    let fillScreen: Bool
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    func makeUIView(context: Context) -> SplashPlayerView {
        let view = SplashPlayerView()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        context.coordinator.player = player
        context.coordinator.observe(item)
        player.play()
        return view
    }

    func updateUIView(_ uiView: SplashPlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: SplashPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.stopObserving()
    }

    final class Coordinator {
        var player: AVPlayer?
        private var endObserver: NSObjectProtocol?
        private let onFinished: () -> Void

        init(onFinished: @escaping () -> Void) {
            self.onFinished = onFinished
        }

        func observe(_ item: AVPlayerItem) {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onFinished()
            }
        }

        func stopObserving() {
            if let token = endObserver {
                NotificationCenter.default.removeObserver(token)
                endObserver = nil
            }
        }
    }
}

private final class SplashPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}


// MARK: - Universal Splash

private struct UniversalSplashView: View {
    @Binding var isFinished: Bool
    @State private var opacity: Double = 0.0

    /// On iOS/iPadOS, compact = iPhone, regular = iPad.
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image("AstralLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .clipShape(RoundedRectangle(cornerRadius: logoCornerRadius,
                                               style: .continuous))
                    .shadow(color: Color(hex: "1AC4D8").opacity(0.55),
                            radius: shadowRadius,
                            y: logoSize * 0.075)
                    .padding(.bottom, logoBottomPad)

                Text("AstralTV")
                    .scaledFont(.system(size: titleSize, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Live TV  ·  Movies  ·  Series")
                    .scaledFont(.system(size: subtitleSize, weight: .light))
                    .foregroundColor(Color(hex: "1AC4D8"))
                    .padding(.top, subtitleTopPad)

                Spacer()
            }
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.4)) { opacity = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                withAnimation(.easeOut(duration: 0.4)) { opacity = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                isFinished = true
            }
        }
    }

    // MARK: - Per-Platform Metrics

    private var logoSize: CGFloat {
        return sizeClass == .compact ? 100 : 130   // iPhone : iPad
    }

    private var logoCornerRadius: CGFloat {
        return sizeClass == .compact ? 20 : 28     // iPhone : iPad
    }

    private var titleSize: CGFloat {
        return sizeClass == .compact ? 50 : 64     // iPhone : iPad
    }

    private var subtitleSize: CGFloat {
        return sizeClass == .compact ? 18 : 24     // iPhone : iPad
    }

    private var logoBottomPad: CGFloat {
        return sizeClass == .compact ? 24 : 32     // iPhone : iPad
    }

    private var subtitleTopPad: CGFloat {
        return 10
    }

    private var shadowRadius: CGFloat {
        return sizeClass == .compact ? 20 : 30     // iPhone : iPad
    }
}
