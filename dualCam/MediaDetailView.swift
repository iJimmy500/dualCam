import SwiftUI
import AVKit

struct MediaDetailView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var savedToPhotos = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                mediaContent
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .font(.title3)
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    bottomTools
                }
            }
            .toolbarBackground(.black, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        if item.type == .photo {
            if let img = item.primaryImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder("Photo unavailable")
            }
        } else {
            if let url = item.primaryVideoURL {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                placeholder("Video unavailable")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shareItems: [Any] {
        if item.type == .photo, let img = item.primaryImage { return [img] }
        if item.type == .video, let url = item.primaryVideoURL { return [url] }
        return []
    }

    @ViewBuilder
    private var bottomTools: some View {
        Button {
            showShareSheet = true
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .foregroundStyle(.white)

        Spacer()

        if savedToPhotos {
            Label("Saved!", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline.weight(.semibold))
        } else {
            Button { saveToPhotos() } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .foregroundStyle(.white)
        }
    }

    private func saveToPhotos() {
        if item.type == .photo, let img = item.primaryImage {
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            withAnimation { savedToPhotos = true }
        } else if item.type == .video, let url = item.primaryVideoURL {
            UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
            withAnimation { savedToPhotos = true }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
