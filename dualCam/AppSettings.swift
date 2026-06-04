import Foundation
import Combine
import SwiftUI
import AVFoundation

// MARK: - Settings

enum SaveDestination: String, CaseIterable, Identifiable {
    case photos = "Photos"
    case files  = "Files"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .files:  return "folder"
        }
    }
    var note: String {
        switch self {
        case .photos: return "Saves directly to your Photos library"
        case .files:  return "Pick a folder each time you save"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case high = "Highest (4K if available)"
    case medium = "Medium (1080p recommended)"
    case low = "Low (720p)"
    var id: String { self.rawValue }
}

enum SpotlightSplit: String, CaseIterable, Identifiable {
    case half     = "50/50"
    case slight   = "60/40"
    case standard = "65/35"
    case major    = "70/30"
    var id: String { rawValue }
    var mainFraction: CGFloat {
        switch self {
        case .half:     return 0.50
        case .slight:   return 0.60
        case .standard: return 0.65
        case .major:    return 0.70
        }
    }
}

enum SpotlightGap: String, CaseIterable, Identifiable {
    case none  = "None"
    case thin  = "Thin"
    case thick = "Thick"
    var id: String { rawValue }
    var points: CGFloat {
        switch self {
        case .none:  return 0
        case .thin:  return 4
        case .thick: return 12
        }
    }
}

enum RecordingCodec: String, CaseIterable, Identifiable {
    case h264        = "Standard"
    case hevcSafe    = "Efficient"
    case hevcSave    = "Power Save"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264:     return "Standard — H.264 · 4 Mbps"
        case .hevcSafe: return "Efficient — HEVC · 4 Mbps"
        case .hevcSave: return "Power Save — HEVC · 2.5 Mbps"
        }
    }

    var note: String {
        switch self {
        case .h264:     return "No battery optimization. Maximum device compatibility."
        case .hevcSafe: return "Same quality as Standard. ~40% smaller temp files → less I/O, modest battery savings. Recommended."
        case .hevcSave: return "Smallest temp files, most battery savings. Possible quality drop on fast motion or high-contrast scenes."
        }
    }
}

final class AppSettings: ObservableObject {
    // @AppStorage properties in a class do NOT automatically fire objectWillChange.
    // Subscribe here so any UserDefaults write (including @AppStorage) triggers view re-renders.
    private var cancellable: AnyCancellable?
    init() {
        cancellable = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
    }
    // Camera
    @AppStorage("hapticFeedback")    var hapticFeedback    = true
    @AppStorage("showGridOverlay")   var showGridOverlay   = false
    @AppStorage("layoutMode")        var layoutModeRaw     = LayoutMode.pip.rawValue
    @AppStorage("aspectRatio")       var aspectRatioRaw    = AspectRatio.full.rawValue
    @AppStorage("captureTimer")      var captureTimer      = 0         // 0, 3, 10 seconds
    @AppStorage("pipFrameStyle")     var pipFrameStyleRaw  = PipFrameStyle.glass.rawValue
    @AppStorage("pipFrameColor")     var pipFrameColorRaw  = PipFrameColor.white.rawValue
    @AppStorage("pipShape")          var pipShapeRaw           = PipShape.roundedRect.rawValue
    @AppStorage("videoQuality")      var videoQualityRaw       = VideoQuality.medium.rawValue
    @AppStorage("spotlightSplit")    var spotlightSplitRaw     = SpotlightSplit.standard.rawValue
    @AppStorage("spotlightGap")      var spotlightGapRaw       = SpotlightGap.thin.rawValue

    // After capture
    @AppStorage("showCapturePreview")  var showCapturePreview  = true
    @AppStorage("soundOnCapture")      var soundOnCapture      = false
    @AppStorage("autoSaveRawFeeds")    var autoSaveRawFeeds    = false
    @AppStorage("saveDestination")     var saveDestinationRaw  = SaveDestination.photos.rawValue

    var saveDestination: SaveDestination {
        get { SaveDestination(rawValue: saveDestinationRaw) ?? .photos }
        set { saveDestinationRaw = newValue.rawValue }
    }

    // General QoL
    @AppStorage("screenAlwaysOn")    var screenAlwaysOn    = true
    @AppStorage("zoomResetOnSwap")   var zoomResetOnSwap   = true

    // Experimental
    @AppStorage("recordingLimitSeconds") var recordingLimitSeconds = 150  // 150 / 300 / 600
    @AppStorage("extendedRecording")  var extendedRecording  = false
    @AppStorage("showDebugInfo")      var showDebugInfo      = false
    @AppStorage("mirrorFrontCamera")  var mirrorFrontCamera  = true
    @AppStorage("delayedDualCapture") var delayedDualCapture = false
    @AppStorage("volumeShutter")      var volumeShutter      = false
    @AppStorage("macroMode")          var macroMode          = false

    // Storage
    @AppStorage("showStorageWarnings") var showStorageWarnings = true
    @AppStorage("autoCleanTempFiles")  var autoCleanTempFiles  = true
    
    // Audio
    @AppStorage("mixAudioWithMusic")  var mixAudioWithMusic  = true

    // Notifications
    @AppStorage("notifyOnSave")       var notifyOnSave       = true

    // Onboarding
    @AppStorage("hasSeenWelcome")     var hasSeenWelcome     = false

    @AppStorage("recordingCodec")     var recordingCodecRaw  = RecordingCodec.hevcSafe.rawValue

    // Computed wrappers
    var layoutMode: LayoutMode {
        get { LayoutMode(rawValue: layoutModeRaw) ?? .pip }
        set { layoutModeRaw = newValue.rawValue }
    }
    var aspectRatio: AspectRatio {
        get { .full }
        set { aspectRatioRaw = newValue.rawValue }
    }
    var pipFrameStyle: PipFrameStyle {
        get { PipFrameStyle(rawValue: pipFrameStyleRaw) ?? .glass }
        set { pipFrameStyleRaw = newValue.rawValue }
    }
    var pipFrameColor: PipFrameColor {
        get { PipFrameColor(rawValue: pipFrameColorRaw) ?? .white }
        set { pipFrameColorRaw = newValue.rawValue }
    }
    var pipShape: PipShape {
        get { PipShape(rawValue: pipShapeRaw) ?? .roundedRect }
        set { pipShapeRaw = newValue.rawValue }
    }
    var videoQuality: VideoQuality {
        get { VideoQuality(rawValue: videoQualityRaw) ?? .medium }
        set { videoQualityRaw = newValue.rawValue }
    }
    var spotlightSplit: SpotlightSplit {
        get { SpotlightSplit(rawValue: spotlightSplitRaw) ?? .standard }
        set { spotlightSplitRaw = newValue.rawValue }
    }
    var spotlightGap: SpotlightGap {
        get { SpotlightGap(rawValue: spotlightGapRaw) ?? .thin }
        set { spotlightGapRaw = newValue.rawValue }
    }
    var recordingCodec: RecordingCodec {
        get { RecordingCodec(rawValue: recordingCodecRaw) ?? .hevcSafe }
        set { recordingCodecRaw = newValue.rawValue }
    }

    static var hasTelephoto: Bool {
        #if os(iOS)
        // Check if device model supports telephoto first (more reliable than camera availability)
        let deviceModel = UIDevice.current.modelName
        let supportsTelephoto = deviceModel.contains("Pro") || deviceModel.contains("Plus")
        
        // If device model supports it, also check camera availability as secondary confirmation
        if supportsTelephoto {
            // In Low Power Mode or certain states, camera might not be available
            // but device still has the hardware
            let cameraAvailable = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil
            return true  // Return true if device model supports it, regardless of momentary availability
        }
        
        return false
        #else
        return false
        #endif
    }
}

extension UIDevice {
    var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                ptr in String.init(validatingUTF8: ptr)
            }
        }
        return machine ?? "Unknown"
    }
}
