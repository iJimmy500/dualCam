import AVKit
import SwiftUI

struct CapturePreviewModal: View {
    let item: MediaItem
    var onDismiss: () -> Void

    @State private var player: AVPlayer?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if item.type == .photo, let img = item.primaryImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if item.type == .video, let url = item.primaryVideoURL {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        let p = AVPlayer(url: url)
                        player = p
                        p.play()
                    }
            } else {
                // Still processing
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                    Text("Processing…")
                        .foregroundStyle(.white.opacity(0.6))
                        .font(.system(size: 14))
                }
            }

            VStack(spacing: 0) {
                HStack {
                    closeButton
                    Spacer()
                    shareButton
                }
                .padding(.horizontal, 18)
                .padding(.top, 56)

                Spacer()

                captionStrip
            }
        }
        // Swipe-down-to-dismiss
        .offset(y: max(0, dragOffset.height))
        .gesture(
            DragGesture()
                .onChanged { dragOffset = $0.translation }
                .onEnded { v in
                    if v.translation.height > 100 || v.predictedEndTranslation.height > 220 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.9), value: dragOffset)
        .onDisappear { player?.pause() }
    }

    // MARK: - Sub-views

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.18), in: Circle())
        }
    }

    private var shareButton: some View {
        Button(action: shareItem) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.18), in: Circle())
        }
    }

    private var captionStrip: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.type == .photo ? "Photo" : "Video")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(item.cameraPair.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if item.type == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Share

    private func shareItem() {
        var items: [Any] = []
        if let img = item.primaryImage            { items = [img] }
        else if let url = item.primaryVideoURL    { items = [url] }
        guard !items.isEmpty else { return }

        let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .present(ac, animated: true)
    }
}
