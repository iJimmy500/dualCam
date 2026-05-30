import AVFoundation
import Combine
import SwiftUI

enum VideoQuality: String, CaseIterable, Identifiable {
    case high = "Highest (4K if available)"
    case medium = "Medium (1080p recommended)"
    case low = "Low (720p)"
    var id: String { self.rawValue }
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
    @AppStorage("aspectRatio")       var aspectRatioRaw    = AspectRatio.r4_3.rawValue
    @AppStorage("captureTimer")      var captureTimer      = 0         // 0, 3, 10 seconds
    @AppStorage("pipFrameStyle")     var pipFrameStyleRaw  = PipFrameStyle.glass.rawValue
    @AppStorage("pipFrameColor")     var pipFrameColorRaw  = PipFrameColor.white.rawValue
    @AppStorage("pipShape")          var pipShapeRaw       = PipShape.roundedRect.rawValue
    @AppStorage("videoQuality")      var videoQualityRaw   = VideoQuality.medium.rawValue

    // After capture
    @AppStorage("showCapturePreview") var showCapturePreview = true
    @AppStorage("soundOnCapture")     var soundOnCapture     = false
    @AppStorage("showWatermark")      var showWatermark      = true
    @AppStorage("autoSaveRawFeeds")   var autoSaveRawFeeds   = false

    // General QoL
    @AppStorage("screenAlwaysOn")    var screenAlwaysOn    = true
    @AppStorage("zoomResetOnSwap")   var zoomResetOnSwap   = true

    // Experimental
    @AppStorage("recordingLimitSeconds") var recordingLimitSeconds = 150  // 150 / 300 / 600
    @AppStorage("extendedRecording")  var extendedRecording  = false
    @AppStorage("showDebugInfo")      var showDebugInfo      = false
    @AppStorage("mirrorFrontCamera")  var mirrorFrontCamera  = true
    @AppStorage("delayedDualCapture") var delayedDualCapture = false
    @AppStorage("liveMode")           var liveMode           = false
    @AppStorage("volumeShutter")      var volumeShutter      = false
    @AppStorage("macroMode")          var macroMode          = false

    // Storage
    @AppStorage("showStorageWarnings") var showStorageWarnings = true
    @AppStorage("autoCleanTempFiles")  var autoCleanTempFiles  = true
    
    // Onboarding
    @AppStorage("hasSeenWelcome")     var hasSeenWelcome     = false

    // Pro
    @AppStorage("highFrameRate")      var highFrameRate      = false
    @AppStorage("recordingCodec")     var recordingCodecRaw  = RecordingCodec.hevcSafe.rawValue

    // Computed wrappers
    var layoutMode: LayoutMode {
        get { LayoutMode(rawValue: layoutModeRaw) ?? .pip }
        set { layoutModeRaw = newValue.rawValue }
    }
    var aspectRatio: AspectRatio {
        get { AspectRatio(rawValue: aspectRatioRaw) ?? .r4_3 }
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
    var recordingCodec: RecordingCodec {
        get { RecordingCodec(rawValue: recordingCodecRaw) ?? .hevcSafe }
        set { recordingCodecRaw = newValue.rawValue }
    }

    static var hasTelephoto: Bool {
        #if os(iOS)
        return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil
        #else
        return false
        #endif
    }
}
