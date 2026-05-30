import SwiftUI

struct StorageInfoView: View {
    @ObservedObject var storageManager: StorageManager
    let showEstimates: Bool
    
    init(storageManager: StorageManager, showEstimates: Bool = false) {
        self.storageManager = storageManager
        self.showEstimates = showEstimates
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Storage overview
            HStack {
                Label("Device Storage", systemImage: "internaldrive")
                Spacer()
                Button("Refresh") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    storageManager.updateStorageInfo()
                }
                .font(.caption)
                .foregroundStyle(.blue)
            }
            
            // Storage bar visualization
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Used: \(storageManager.usedSpaceFormatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Available: \(storageManager.availableSpaceFormatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 6)
                        
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(storageBarColor)
                            .frame(width: geo.size.width * storageManager.usedSpacePercentage, height: 6)
                    }
                }
                .frame(height: 6)
                
                HStack {
                    Text("Total: \(storageManager.totalSpaceFormatted)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    
                    Spacer()
                    
                    if storageManager.usedSpacePercentage > 0.8 {
                        Label("\(Int(storageManager.usedSpacePercentage * 100))% full", 
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(storageManager.usedSpacePercentage > 0.9 ? .red : .orange)
                    }
                }
            }
            
            if showEstimates {
                estimatesSection
            }
        }
        .padding(.vertical, 6)
    }
    
    @ViewBuilder
    private var estimatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording Estimates")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                // These would need to be passed as parameters or computed based on current settings
                Text("Estimates require current video settings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
    }
    
    private var storageBarColor: Color {
        if storageManager.usedSpacePercentage > 0.9 {
            return .red
        } else if storageManager.usedSpacePercentage > 0.8 {
            return .orange
        } else if storageManager.usedSpacePercentage > 0.7 {
            return .yellow
        } else {
            return .green
        }
    }
}

// MARK: - Storage Badge

struct StorageBadgeView: View {
    @ObservedObject var storageManager: StorageManager
    
    var body: some View {
        Group {
            if storageManager.usedSpacePercentage > 0.8 {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive.fill.badge.exclamationmark")
                        .font(.system(size: 12, weight: .medium))
                    Text("\(storageManager.availableSpaceFormatted) free")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(storageManager.usedSpacePercentage > 0.9 ? .red.opacity(0.9) : .orange.opacity(0.9), 
                           in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
            }
        }
    }
}

#Preview {
    StorageInfoView(storageManager: StorageManager(), showEstimates: true)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}