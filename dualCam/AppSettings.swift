import AVFoundation
import Combine
import SwiftUI

enum VideoQuality: String, CaseIterable, Identifiable {
    case high = "Highest (4K if available)"
    case medium = "Medium (1080p recommended)"
    case low = "Low (720p)"
    var id: String { self.rawValue }
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
    @AppStorage("extendedRecording")  var extendedRecording  = false
    @AppStorage("showDebugInfo")      var showDebugInfo      = false
    @AppStorage("mirrorFrontCamera")  var mirrorFrontCamera  = true
    @AppStorage("delayedDualCapture") var delayedDualCapture = false
    @AppStorage("liveMode")           var liveMode           = false
    @AppStorage("volumeShutter")      var volumeShutter      = false
    @AppStorage("macroMode")          var macroMode          = false

    // Pro
    @AppStorage("highFrameRate")     var highFrameRate     = false

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

    static var hasTelephoto: Bool {
        #if os(iOS)
        return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil
        #else
        return false
        #endif
    }
}
