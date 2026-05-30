import Foundation
import AVFoundation

@MainActor
final class StorageManager: ObservableObject {
    @Published var availableSpace: Int64 = 0
    @Published var totalSpace: Int64 = 0
    @Published var usedSpace: Int64 = 0
    @Published var lastUpdated: Date = Date()
    
    init() {
        updateStorageInfo()
    }
    
    // MARK: - Public Methods
    
    func updateStorageInfo() {
        Task { @MainActor in
            let (available, total, used) = await getStorageInfo()
            self.availableSpace = available
            self.totalSpace = total
            self.usedSpace = used
            self.lastUpdated = Date()
        }
    }
    
    func checkAvailableSpace(for estimatedSize: Int64) -> Bool {
        let safetyMargin: Int64 = 500 * 1024 * 1024 // 500 MB safety margin
        return availableSpace > (estimatedSize + safetyMargin)
    }
    
    func estimateVideoSize(duration: TimeInterval, quality: VideoQuality, codec: RecordingCodec) -> Int64 {
        // Base bitrate per quality level (in bits per second)
        let baseBitrate: Double = switch quality {
        case .high: 20_000_000    // 20 Mbps for 4K
        case .medium: 8_000_000   // 8 Mbps for 1080p
        case .low: 4_000_000      // 4 Mbps for 720p
        }
        
        // Codec efficiency multiplier
        let codecMultiplier: Double = switch codec {
        case .h264: 1.0
        case .hevcSafe: 0.6       // HEVC is ~40% more efficient
        case .hevcSave: 0.4       // Power save mode is even more efficient
        }
        
        // Dual camera multiplier (two streams)
        let dualCameraMultiplier: Double = 1.8  // Slightly less than 2x due to shared metadata
        
        let totalBitrate = baseBitrate * codecMultiplier * dualCameraMultiplier
        let sizeInBytes = Int64((totalBitrate * duration) / 8) // Convert bits to bytes
        
        // Add 20% overhead for audio, metadata, and container format
        return Int64(Double(sizeInBytes) * 1.2)
    }
    
    func canRecordVideo(duration: TimeInterval, quality: VideoQuality, codec: RecordingCodec) -> (canRecord: Bool, estimatedSize: Int64, availableSpace: Int64) {
        let estimatedSize = estimateVideoSize(duration: duration, quality: quality, codec: codec)
        let canRecord = checkAvailableSpace(for: estimatedSize)
        return (canRecord, estimatedSize, availableSpace)
    }
    
    // MARK: - Storage Info Formatting
    
    var availableSpaceFormatted: String {
        formatBytes(availableSpace)
    }
    
    var totalSpaceFormatted: String {
        formatBytes(totalSpace)
    }
    
    var usedSpaceFormatted: String {
        formatBytes(usedSpace)
    }
    
    var usedSpacePercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }
    
    // MARK: - Private Methods
    
    private func getStorageInfo() async -> (available: Int64, total: Int64, used: Int64) {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            AppLogger.shared.log("StorageManager: Failed to get documents directory")
            return (0, 0, 0)
        }
        
        do {
            let resourceValues = try documentsPath.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])
            
            let available = resourceValues.volumeAvailableCapacityForImportantUsage ?? 0
            let total = Int64(resourceValues.volumeTotalCapacity ?? 0)
            let used = total - available
            
            return (available, total, used)
        } catch {
            AppLogger.shared.log("StorageManager: Error getting storage info: \(error.localizedDescription)")
            return (0, 0, 0)
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Storage Alert Helper

extension StorageManager {
    func getStorageWarningMessage(for estimatedSize: Int64) -> String? {
        let availableGB = Double(availableSpace) / (1024 * 1024 * 1024)
        let estimatedGB = Double(estimatedSize) / (1024 * 1024 * 1024)
        
        if !checkAvailableSpace(for: estimatedSize) {
            return "Insufficient storage space. Need \(String(format: "%.1f", estimatedGB)) GB, but only \(String(format: "%.1f", availableGB)) GB available."
        }
        
        if availableGB < 2.0 {
            return "Low storage space remaining (\(String(format: "%.1f", availableGB)) GB). Recording may fail if device runs out of space."
        }
        
        return nil
    }
}
