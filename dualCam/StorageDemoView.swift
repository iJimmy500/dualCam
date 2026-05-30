import SwiftUI

// Demo view to show the new storage functionality
struct StorageDemoView: View {
    @StateObject private var storageManager = StorageManager()
    @StateObject private var settings = AppSettings()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Storage Info Component
                StorageInfoView(storageManager: storageManager)
                    .padding()
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                
                // Storage Badge Demo
                VStack(spacing: 10) {
                    Text("Storage Badge Demo")
                        .font(.headline)
                    
                    StorageBadgeView(storageManager: storageManager)
                }
                
                // Recording Estimates
                VStack(alignment: .leading, spacing: 10) {
                    Text("Video Recording Estimates")
                        .font(.headline)
                    
                    ForEach([
                        (name: "1 minute 4K", duration: 60.0, quality: VideoQuality.high),
                        (name: "5 minutes 1080p", duration: 300.0, quality: VideoQuality.medium),
                        (name: "10 minutes 720p", duration: 600.0, quality: VideoQuality.low)
                    ], id: \.name) { item in
                        let estimate = storageManager.estimateVideoSize(
                            duration: item.duration, 
                            quality: item.quality, 
                            codec: .hevcSafe
                        )
                        let formatted = ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)
                        let canRecord = storageManager.checkAvailableSpace(for: estimate)
                        
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text("~\(formatted)")
                                .foregroundStyle(canRecord ? .green : .red)
                            Image(systemName: canRecord ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(canRecord ? .green : .red)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                
                Spacer()
                
                // Test Storage Check
                VStack(spacing: 10) {
                    Button("Test Storage Warning") {
                        // Simulate low storage scenario
                        testStorageWarning()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Refresh Storage Info") {
                        storageManager.updateStorageInfo()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(.black)
            .foregroundStyle(.white)
            .navigationTitle("Storage Manager Demo")
            .navigationBarTitleDisplayMode(.large)
            .preferredColorScheme(.dark)
        }
    }
    
    private func testStorageWarning() {
        let estimate: Int64 = 10 * 1024 * 1024 * 1024 // 10 GB
        if let warning = storageManager.getStorageWarningMessage(for: estimate) {
            print("Storage Warning: \(warning)")
        } else {
            print("No storage warning needed")
        }
    }
}

#Preview {
    StorageDemoView()
}