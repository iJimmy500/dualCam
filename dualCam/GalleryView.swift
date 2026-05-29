import SwiftUI

struct GalleryView: View {
    @EnvironmentObject var capture: CaptureManager
    @State private var selectedItem: MediaItem?
    @State private var selectedFilter: MediaFilter = .all

    enum MediaFilter: String, CaseIterable { case all = "All", photos = "Photos", videos = "Videos" }

    private var filteredItems: [MediaItem] {
        switch selectedFilter {
        case .all:    return capture.capturedItems
        case .photos: return capture.capturedItems.filter { $0.type == .photo }
        case .videos: return capture.capturedItems.filter { $0.type == .video }
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if capture.capturedItems.isEmpty {
                    emptyState
                } else {
                    scrollContent
                }
            }
            .navigationTitle("DualCam")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Color.black)
        }
        .fullScreenCover(item: $selectedItem) { item in
            MediaDetailView(item: item).environmentObject(capture)
        }
    }

    private var scrollContent: some View {
        ScrollView {
            HStack {
                Text("\(filteredItems.count) \(selectedFilter == .all ? "items" : selectedFilter.rawValue.lowercased())")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                Spacer()
            }

            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(filteredItems) { item in
                    ThumbnailCell(item: item)
                        .onTapGesture { selectedItem = item }
                }
            }
        }
        .background(Color.black)
    }

    private var filterMenu: some View {
        Menu {
            Picker("", selection: $selectedFilter) {
                ForEach(MediaFilter.allCases, id: \.self) {
                    Label($0.rawValue, systemImage: filterIcon(for: $0)).tag($0)
                }
            }
        } label: {
            Image(systemName: selectedFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .medium))
        }
    }

    private func filterIcon(for filter: MediaFilter) -> String {
        switch filter {
        case .all:    return "square.grid.3x3"
        case .photos: return "photo"
        case .videos: return "video"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No captures yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Dual-camera photos and videos appear here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .background(Color.black)
    }
}

struct ThumbnailCell: View {
    let item: MediaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumb = item.thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(.systemGray6))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: item.type == .photo ? "photo" : "video")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    )
            }

            // Video badge only — keep photos clean
            if item.type == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.5), in: Circle())
                    .padding(7)
            }
        }
        .contentShape(Rectangle())
    }
}
