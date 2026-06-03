import AVFoundation
import Photos
import UIKit
import SwiftUI
import BackgroundTasks
import ActivityKit
import UserNotifications
import Combine

// Processing task model for background queue
struct ProcessingTask: Identifiable {
    let id = UUID()
    let primaryURL: URL
    let secondaryURL: URL
    let isSwapped: Bool
    let layout: LayoutMode
    let aspectRatio: AspectRatio?
    let highFrameRate: Bool
    let pipWidthFraction: CGFloat
    let pipPosition: CGPoint
    let frameStyle: PipFrameStyle
    let frameColor: PipFrameColor
    let pipShape: PipShape
    let quality: VideoQuality
    let pair: CameraPair
    var progress: Double = 0.0
    var status: String = "Queued"
    
    enum Status {
        case queued, processing, completed, failed
    }
}

extension AVCaptureDevice.FlashMode {
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return "Auto"
        @unknown default: return "Unknown"
        }
    }
    
    var systemImage: String {
        switch self {
        case .off: return "bolt.slash"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.a"
        @unknown default: return "bolt"
        }
    }
}

@MainActor
class CaptureManager: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var isRecording = false
    @Published var capturedItems: [MediaItem] = []
    @Published var currentPair: CameraPair = .frontAndBack
    @Published var isSupported = false
    @Published var isConfiguring = false
    @Published var configurationProgress: Double = 0.0
    @Published var configurationStatusMessage = ""
    @Published var isSwapped = false
    @Published var isProcessingVideo = false
    @Published var processingProgress: Double = 0.0
    @Published var processingStatusMessage = ""
    @Published var errorMessage: String?
    @Published var pipPosition  = CGPoint(x: 0.8, y: 0.2)
    
    // System monitoring
    @Published var thermalWarningMessage: String?
    @Published var powerOptimizationMessage: String?
    @Published var isPerformanceReduced = false
    
    private let systemMonitor: SystemMonitor = SystemMonitor.shared
    private let backgroundManager: BackgroundManager = BackgroundManager.shared
    private let logger = AppLogger.shared
    // These settings are read at capture/record time so they must always reflect the
    // current UserDefaults value — not a potentially-stale @Published copy.
    var layoutMode: LayoutMode {
        LayoutMode(rawValue: UserDefaults.standard.string(forKey: "layoutMode") ?? "") ?? .pip
    }
    var aspectRatio: AspectRatio { .full }
    var pipFrameStyle: PipFrameStyle {
        PipFrameStyle(rawValue: UserDefaults.standard.string(forKey: "pipFrameStyle") ?? "") ?? .glass
    }
    var pipFrameColor: PipFrameColor {
        PipFrameColor(rawValue: UserDefaults.standard.string(forKey: "pipFrameColor") ?? "") ?? .white
    }
    var pipShape: PipShape {
        PipShape(rawValue: UserDefaults.standard.string(forKey: "pipShape") ?? "") ?? .roundedRect
    }
    var videoQuality: VideoQuality {
        VideoQuality(rawValue: UserDefaults.standard.string(forKey: "videoQuality") ?? "") ?? .medium
    }
    var autoSaveRawFeeds: Bool {
        UserDefaults.standard.bool(forKey: "autoSaveRawFeeds")
    }
    var saveDestination: SaveDestination {
        SaveDestination(rawValue: UserDefaults.standard.string(forKey: "saveDestination") ?? "") ?? .photos
    }
    @Published var pipWidth: CGFloat            = 108
    @Published var displayWidth: CGFloat        = UIScreen.main.bounds.width
    @Published var pendingExportURL: URL?       = nil
    @Published var flashMode: AVCaptureDevice.FlashMode = .auto {
        didSet { UserDefaults.standard.set(flashMode.rawValue, forKey: "flashMode") }
    }
    @Published var flashFired = false
    @Published var showSavedBanner = false
    private var savedBannerVersion = 0
    @Published var zoom: CGFloat = 1.0
    @Published var focusPoint: CGPoint? = nil
    @Published private(set) var primaryPreviewLayer = AVCaptureVideoPreviewLayer()
    @Published private(set) var secondaryPreviewLayer = AVCaptureVideoPreviewLayer()
    @Published var rawCapturedURLs: (primary: URL, secondary: URL)? = nil
    @Published var isVideoRecorderReady = false
    @Published var recordingCodec: RecordingCodec = .hevcSafe
    @Published var recentVideoItem: MediaItem? = nil

    let session = AVCaptureMultiCamSession()

    /// Best virtual back camera detected at startup — drives real lens switching via videoZoomFactor.
    private(set) var detectedBackCamera: AVCaptureDevice? = nil

    private var primaryPhotoOutput = AVCapturePhotoOutput()
    private var secondaryPhotoOutput = AVCapturePhotoOutput()
    private var primaryVideoOutput = AVCaptureVideoDataOutput()
    private var secondaryVideoOutput = AVCaptureVideoDataOutput()
    private var audioOutput = AVCaptureAudioDataOutput()

    nonisolated(unsafe) private var _primaryVideoOutput: AVCaptureVideoDataOutput?
    nonisolated(unsafe) private var _secondaryVideoOutput: AVCaptureVideoDataOutput?
    nonisolated(unsafe) private var _audioOutput: AVCaptureAudioDataOutput?
    nonisolated(unsafe) private var _recorder = VideoRecorder()
    private let _outputLock = NSLock()

    private let videoQueue = DispatchQueue(label: "com.dualcam.video", qos: .userInitiated)
    private var recordingTimer: Timer?
    private var videoCaptureAspectRatio: AspectRatio? = nil
    private var videoCaptureHighFrameRate: Bool = false
    @Published var recordingSecondsElapsed: Int = 0
    private var focusTask: Task<Void, Never>?   // cancellable; prevents stacked focus timers

    // Background processing support
    @Published var processingQueue: [ProcessingTask] = []
    @Published var isBackgroundProcessingEnabled = true
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var currentProcessingTask: ProcessingTask?
    private var activeProcessingTask: Task<Void, Never>?  // cancellable processing task
    
    // Live Activity support
    private let liveActivityManager = LiveActivityManager()
    static var maxRecordingSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: "recordingLimitSeconds")
        return v > 0 ? v : 150
    }

    private var pendingPrimaryPhotoData: Data?
    private var pendingSecondaryPhotoData: Data?
    private var photoCapturePair: CameraPair          = .frontAndBack
    private var photoCaptureLayout: LayoutMode        = .pip
    private var photoCapturePipWidth: CGFloat         = 108
    private var photoCaptureAspectRatio: AspectRatio  = .full
    private var photoCaptureFrameStyle: PipFrameStyle = .glass
    private var photoCaptureFrameColor: PipFrameColor = .white
    private var photoCapturePipShape: PipShape        = .roundedRect
    private var photoCaptureIsSwapped: Bool           = false
    // True while waiting for the user/timer to trigger secondary in delayed-dual mode
    private(set) var awaitingDelayedSecondary = false

    override init() {
        super.init()
        isSupported = AVCaptureMultiCamSession.isMultiCamSupported
        
        // Setup system monitoring
        backgroundManager.register(captureManager: self)
        setupSystemMonitoring()
        
        // isConfiguring starts false; the loading overlay stays visible because
        // isSessionRunning is also false — see cameraContent's overlay condition.

        // Restore persisted settings
        if let raw = UserDefaults.standard.object(forKey: "flashMode") as? Int,
           let saved = AVCaptureDevice.FlashMode(rawValue: raw) {
            flashMode = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "cameraPair"),
           let saved = CameraPair(rawValue: raw) {
            currentPair = saved
        }
    }

    // MARK: - System Monitoring

    private func setupSystemMonitoring() {
        systemMonitor.startMonitoring()
        
        // Monitor thermal state changes
        systemMonitor.$thermalState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] thermalState in
                self?.handleThermalStateChange(thermalState)
            }
            .store(in: &cancellables)
        
        // Monitor power state changes
        systemMonitor.$lowPowerModeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lowPowerMode in
                self?.handlePowerStateChange(lowPowerMode)
            }
            .store(in: &cancellables)
        
        // Update warning messages
        updateSystemWarnings()
    }
    
    private func handleThermalStateChange(_ thermalState: ProcessInfo.ThermalState) {
        logger.log("CaptureManager: Thermal state changed to \(thermalState.description)")
        
        switch thermalState {
        case .critical:
            // Stop recording if critical
            if isRecording {
                stopRecording()
                errorMessage = "Recording stopped due to device overheating. Please let your device cool down."
            }
            isPerformanceReduced = true
            
        case .serious:
            // Reduce performance but continue
            isPerformanceReduced = true
            
        case .fair, .nominal:
            isPerformanceReduced = false
            
        @unknown default:
            break
        }
        
        updateSystemWarnings()
    }
    
    private func handlePowerStateChange(_ lowPowerMode: Bool) {
        logger.log("CaptureManager: Low power mode \(lowPowerMode ? "enabled" : "disabled")")
        
        // Compare raw values: nominal(0), fair(1), serious(2), critical(3)
        isPerformanceReduced = lowPowerMode || systemMonitor.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        updateSystemWarnings()
    }
    
    private func updateSystemWarnings() {
        thermalWarningMessage = systemMonitor.thermalWarningMessage
        powerOptimizationMessage = systemMonitor.powerOptimizationMessage
    }
    
    // Apply performance optimizations based on system state
    func getOptimizedSettings() -> (codec: RecordingCodec, quality: VideoQuality) {
        return (systemMonitor.recommendedCodec, systemMonitor.recommendedQuality)
    }
    
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Setup

    func checkPermissionsAndSetup() async {
        // Guard against re-entry: SwiftUI .task can re-fire if the view disappears
        // and reappears (backgrounding, fullScreenCover on some iOS versions). Re-running
        // configureSession on a live session would tear down all inputs mid-capture.
        guard !isSessionRunning, !isConfiguring else {
            logger.log("checkPermissionsAndSetup: already running — skipping")
            return
        }
        isConfiguring = true

        guard isSupported else {
            isConfiguring = false
            errorMessage = "Multi-cam not supported on this device (requires iPhone XS/XR or newer)."
            return
        }

        let hasPermissions = await requestPermissions()
        guard hasPermissions else { isConfiguring = false; return }

        detectBackCamera()
        
        // Log available multi-cam device sets for debugging
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        
        logger.log("checkPermissionsAndSetup: Available multi-cam device sets:")
        for (index, deviceSet) in discoverySession.supportedMultiCamDeviceSets.enumerated() {
            let deviceNames = deviceSet.map { $0.deviceType.rawValue }.joined(separator: " + ")
            logger.log("  Set \(index): \(deviceNames)")
        }
        
        let supportedPairs = getSupportedCameraPairs()
        logger.log("checkPermissionsAndSetup: Supported camera pairs: \(supportedPairs.map(\.rawValue))")
        
        // Ensure we start with a supported pair
        if !supportedPairs.contains(currentPair) {
            if let fallbackPair = supportedPairs.first {
                logger.log("checkPermissionsAndSetup: Current pair \(currentPair.rawValue) not supported, switching to \(fallbackPair.rawValue)")
                currentPair = fallbackPair
                UserDefaults.standard.set(fallbackPair.rawValue, forKey: "cameraPair")
            }
        }
        
        setupAudioSession()
        configureSession(pair: currentPair)
    }

    // The default audio session category (.soloAmbient) doesn't allow recording,
    // causing -19224 errors that cascade into camera XPC failures. Configure it first.
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Non-fatal — session will work without audio
        }
    }

    private func requestPermissions() async -> Bool {
        // Request video permission if needed
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .video)
        }
        
        // Request audio permission if needed
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
        
        // Request photo library permission if needed
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        
        // Check if we have video permission (required for camera)
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            errorMessage = "Camera access denied. Go to Settings → Privacy → Camera and enable DualCam."
            return false
        }
        
        return true
    }

    func switchPair(_ pair: CameraPair) {
        // Check if the requested pair is actually supported
        guard isCameraPairSupported(pair) else {
            logger.log("switchPair: Requested pair \(pair.rawValue) not supported, finding alternative")
            
            // Fall back to the first supported pair
            let supportedPairs = getSupportedCameraPairs()
            guard let fallbackPair = supportedPairs.first else {
                logger.log("switchPair: No supported camera pairs found!")
                errorMessage = "No compatible camera pairs found on this device."
                return
            }
            
            logger.log("switchPair: Falling back to \(fallbackPair.rawValue)")
            currentPair = fallbackPair
            UserDefaults.standard.set(fallbackPair.rawValue, forKey: "cameraPair")
            
            isSwapped = false
            zoom = 1.0
            
            if !isFlashAvailable {
                flashMode = .off
            }
            
            reconfigureSession(for: fallbackPair)
            return
        }
        
        // Add safety check for telephoto pairs in challenging conditions
        if pair.requiresTelephoto && !canAccessTelephotoCamera() {
            logger.log("switchPair: Telephoto pair requested but camera not accessible, falling back to frontAndBack")
            currentPair = .frontAndBack
            UserDefaults.standard.set(CameraPair.frontAndBack.rawValue, forKey: "cameraPair")
        } else {
            currentPair = pair
            UserDefaults.standard.set(pair.rawValue, forKey: "cameraPair")
        }
        
        isSwapped = false
        zoom = 1.0
        
        // Reset flash mode if new cameras don't support flash
        if !isFlashAvailable {
            flashMode = .off
        }
        
        reconfigureSession(for: currentPair)
    }
    
    func canAccessTelephotoCamera() -> Bool {
        // Check if telephoto camera is actually accessible (not just if device has one)
        guard let _ = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) else {
            logger.log("canAccessTelephotoCamera: Telephoto camera not available")
            return false
        }
        return true
    }
    
    private func reconfigureSession(for pair: CameraPair) {
        Task {
            let captureSession = self.session
            await Task.detached(priority: .userInitiated) {
                captureSession.stopRunning()
            }.value
            self.configureSession(pair: pair)
        }
    }

    func swapCameras() {
        isSwapped.toggle()
    }
    
    func updatePipPosition(_ position: CGPoint, in bounds: CGRect, pipWidth: CGFloat, pipHeight: CGFloat) {
        let margin: CGFloat = 8
        let halfW = (pipWidth / 2 + margin) / bounds.width
        let halfH = (pipHeight / 2 + margin) / bounds.height
        pipPosition = CGPoint(
            x: min(1 - halfW, max(halfW, position.x / bounds.width)),
            y: min(1 - halfH, max(halfH, position.y / bounds.height))
        )
    }
    
    // MARK: - Flash Management
    
    var isFlashAvailable: Bool {
        // Check if any of the current cameras support flash
        guard let (primaryDevice, secondaryDevice) = devicesFor(pair: currentPair) else { return false }
        return primaryDevice.hasFlash || secondaryDevice.hasFlash
    }
    
    var flashCapabilities: String {
        guard let (primaryDevice, secondaryDevice) = devicesFor(pair: currentPair) else { return "No cameras" }
        let primaryFlash = primaryDevice.hasFlash
        let secondaryFlash = secondaryDevice.hasFlash
        
        switch (primaryFlash, secondaryFlash) {
        case (true, true): return "Both cameras support flash"
        case (true, false): return "Primary camera supports flash"
        case (false, true): return "Secondary camera supports flash"  
        case (false, false): return "No flash available"
        }
    }
    
    var availableFlashModes: [AVCaptureDevice.FlashMode] {
        guard isFlashAvailable else { return [.off] }
        return [.off, .auto, .on]
    }
    
    func setFlashMode(_ mode: AVCaptureDevice.FlashMode) {
        flashMode = mode
    }
    
    func cycleFlashMode() {
        let modes = availableFlashModes
        if let currentIndex = modes.firstIndex(of: flashMode) {
            let nextIndex = (currentIndex + 1) % modes.count
            flashMode = modes[nextIndex]
        } else {
            flashMode = modes.first ?? .off
        }
    }
    
    // MARK: - Focus

    func setFocus(at point: CGPoint, in layer: AVCaptureVideoPreviewLayer) {
        guard let device = getCurrentPrimaryDevice() else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        } catch {}
        focusPoint = point
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            focusPoint = nil
        }
    }
    
    func setZoom(_ factor: CGFloat) {
        guard let device = getCurrentPrimaryDevice() else { return }
        
        do {
            try device.lockForConfiguration()
            
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10.0) // Cap at 10x
            let clampedZoom = max(1.0, min(maxZoom, factor))
            device.videoZoomFactor = clampedZoom
            zoom = clampedZoom
            
            device.unlockForConfiguration()
        } catch {
            print("Failed to set zoom: \(error)")
        }
    }
    
    private func getCurrentPrimaryDevice() -> AVCaptureDevice? {
        guard let (primaryDevice, _) = devicesFor(pair: currentPair) else { return nil }
        return primaryDevice
    }
    
    var maxZoomFactor: CGFloat {
        guard let device = getCurrentPrimaryDevice() else { return 1.0 }
        return min(device.activeFormat.videoMaxZoomFactor, 10.0)
    }
    
    var supportsZoom: Bool {
        guard let device = getCurrentPrimaryDevice() else { return false }
        return device.activeFormat.videoMaxZoomFactor > 1.0
    }

    // MARK: - Zoom Presets

    struct ZoomPreset: Identifiable {
        let id: String
        let label: String
        let zoom: CGFloat
        // true = secondary camera should be the visual main (isSwapped=true)
        let wantsSwapped: Bool
    }

    var zoomPresets: [ZoomPreset] {
        switch currentPair {
        case .frontAndBack:
            return presetsForDetectedBackCamera()
        case .wideAndUltrawide:
            return [
                ZoomPreset(id: "0.5", label: ".5×", zoom: 1.0, wantsSwapped: true),
                ZoomPreset(id: "1",   label: "1×",  zoom: 1.0, wantsSwapped: false),
                ZoomPreset(id: "2",   label: "2×",  zoom: 2.0, wantsSwapped: false),
                ZoomPreset(id: "3",   label: "3×",  zoom: 3.0, wantsSwapped: false),
            ]
        case .wideAndTelephoto:
            return [
                ZoomPreset(id: "1",    label: "1×",   zoom: 1.0, wantsSwapped: false),
                ZoomPreset(id: "2",    label: "2×",   zoom: 2.0, wantsSwapped: false),
                ZoomPreset(id: "tele", label: "Tele", zoom: 1.0, wantsSwapped: true),
            ]
        case .ultraAndFront:
            return [
                ZoomPreset(id: "0.5", label: ".5×", zoom: 1.0, wantsSwapped: false),
                ZoomPreset(id: "1",   label: "1×",  zoom: 1.0, wantsSwapped: true),
            ]
        case .telephotoAndFront:
            return [
                ZoomPreset(id: "tele", label: "Tele", zoom: 1.0, wantsSwapped: false),
                ZoomPreset(id: "1",    label: "1×",   zoom: 1.0, wantsSwapped: true),
            ]
        case .ultrawideAndTelephoto:
            return [
                ZoomPreset(id: "0.5",  label: ".5×",  zoom: 1.0, wantsSwapped: false),
                ZoomPreset(id: "tele", label: "Tele",  zoom: 1.0, wantsSwapped: true),
            ]
        }
    }

    /// Builds presets from the virtual back camera's actual lens-switchover zoom factors.
    /// iOS physically switches lenses at those thresholds — no digital zoom needed.
    private func presetsForDetectedBackCamera() -> [ZoomPreset] {
        guard let device = detectedBackCamera else {
            return [ZoomPreset(id: "1", label: "1×", zoom: 1.0, wantsSwapped: false)]
        }

        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.floatValue) }
        let type = device.deviceType

        switch switches.count {
        case 0:
            // Single physical lens — only a 1× preset
            return [ZoomPreset(id: "1", label: "1×", zoom: 1.0, wantsSwapped: false)]

        case 1:
            let switchZoom = switches[0]
            if type == .builtInDualWideCamera {
                // Wide + Ultrawide: base = ultrawide, switch to wide at switchZoom
                return [
                    ZoomPreset(id: "ultra", label: ".5×", zoom: 1.0,        wantsSwapped: false),
                    ZoomPreset(id: "wide",  label: "1×",  zoom: switchZoom,  wantsSwapped: false),
                ]
            } else {
                // Wide + Tele: base = wide, switch to tele at switchZoom
                let teleOptical = Int(switchZoom.rounded())
                return [
                    ZoomPreset(id: "wide", label: "1×",             zoom: 1.0,       wantsSwapped: false),
                    ZoomPreset(id: "tele", label: "\(teleOptical)×", zoom: switchZoom, wantsSwapped: false),
                ]
            }

        default:
            // Triple camera: ultrawide at 1.0, wide at switches[0], tele at switches[1]
            let wideZoom = switches[0]
            let teleZoom = switches[1]
            let teleOptical = (teleZoom / wideZoom).rounded()
            let teleLabel = teleOptical == teleOptical.rounded() ? "\(Int(teleOptical))×" : String(format: "%.1f×", teleOptical)
            return [
                ZoomPreset(id: "ultra", label: ".5×",     zoom: 1.0,      wantsSwapped: false),
                ZoomPreset(id: "wide",  label: "1×",      zoom: wideZoom,  wantsSwapped: false),
                ZoomPreset(id: "tele",  label: teleLabel,  zoom: teleZoom,  wantsSwapped: false),
            ]
        }
    }

    /// Active preset: nil when between presets. Uses relative tolerance so it works
    /// across all zoom scales (1×, 2×, 6×, etc.).
    var activePresetID: String? {
        if currentPair == .frontAndBack {
            return zoomPresets.first { abs($0.zoom - zoom) <= max(0.2, $0.zoom * 0.1) }?.id
        }
        return zoomPresets.first { $0.wantsSwapped == isSwapped && abs($0.zoom - zoom) < 0.15 }?.id
    }

    func applyZoomPreset(_ preset: ZoomPreset) {
        logger.log("Zoom preset: \(preset.label) (swap=\(preset.wantsSwapped), zoom=\(preset.zoom)×, pair=\(currentPair.rawValue))")
        // frontAndBack uses a virtual device — iOS handles lens switching via videoZoomFactor,
        // no camera swap needed. Other pairs use physical-device swaps to reach different lenses.
        if currentPair != .frontAndBack && preset.wantsSwapped != isSwapped {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { swapCameras() }
        }
        setZoom(preset.zoom)
    }

    // MARK: - Front Camera Mirror

    /// Mirrors the secondary preview layer when pair is front+back and setting is on.
    func applyFrontCameraMirror() {
        let mirrored = UserDefaults.standard.bool(forKey: "mirrorFrontCamera")
        // Only meaningful for front+back; other pairs don't show a front camera as secondary
        guard currentPair == .frontAndBack else {
            secondaryPreviewLayer.transform = CATransform3DIdentity
            return
        }
        secondaryPreviewLayer.transform = mirrored
            ? CATransform3DMakeScale(-1, 1, 1)
            : CATransform3DIdentity
    }

    // MARK: - Volume Button Shutter

    private var volumeObserver: NSKeyValueObservation?

    func startVolumeObservation() {
        guard volumeObserver == nil else { return }
        volumeObserver = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.new, .old]
        ) { [weak self] _, change in
            guard let self,
                  UserDefaults.standard.bool(forKey: "volumeShutter"),
                  let old = change.oldValue, let new = change.newValue,
                  old != new          // real button press, not programmatic reset
            else { return }
            Task { @MainActor in
                NotificationCenter.default.post(name: .dualCamVolumeShutter, object: nil)
            }
        }
        logger.log("Volume button shutter: observation started")
    }

    func stopVolumeObservation() {
        volumeObserver?.invalidate()
        volumeObserver = nil
    }

    // MARK: - Back Camera Detection

    private func detectBackCamera() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        detectedBackCamera = types.compactMap {
            AVCaptureDevice.default($0, for: .video, position: .back)
        }.first
        logger.log("Back camera detected: \(detectedBackCamera?.deviceType.rawValue ?? "none")")
    }
    
    // MARK: - Camera Pair Compatibility
    
    func getSupportedCameraPairs() -> [CameraPair] {
        let allPairs: [CameraPair] = [.frontAndBack, .wideAndUltrawide, .ultraAndFront, .wideAndTelephoto, .telephotoAndFront, .ultrawideAndTelephoto]
        return allPairs.filter { pair in
            guard let devices = getCompatibleDevicesFor(pair: pair) else { return false }
            return areDevicesCompatibleForMultiCam(devices.0, devices.1)
        }
    }
    
    func isCameraPairSupported(_ pair: CameraPair) -> Bool {
        guard let devices = getCompatibleDevicesFor(pair: pair) else { return false }
        return areDevicesCompatibleForMultiCam(devices.0, devices.1)
    }

    // MARK: - Session Configuration

    private func configureSession(pair: CameraPair) {
        isConfiguring = true
        configurationProgress = 0.0
        configurationStatusMessage = "Initializing camera session..."
        
        // Create new preview layers for clean configuration
        let newPrimaryLayer = AVCaptureVideoPreviewLayer()
        newPrimaryLayer.videoGravity = .resizeAspectFill
        let newSecondaryLayer = AVCaptureVideoPreviewLayer()
        newSecondaryLayer.videoGravity = .resizeAspectFill

        configurationProgress = 0.1
        configurationStatusMessage = "Setting up audio session..."
        
        // Let us manage the audio session ourselves (set up in setupAudioSession).
        // Leaving this at true causes -19224 category conflicts in AVCaptureMultiCamSession.
        session.automaticallyConfiguresApplicationAudioSession = false

        // Required for AVCaptureMultiCamSession: associate layers with the session
        // before adding connections. Without this the session won't route frames to
        // the layers even if a valid AVCaptureConnection exists.
        newPrimaryLayer.setSessionWithNoConnection(session)
        newSecondaryLayer.setSessionWithNoConnection(session)

        configurationProgress = 0.2
        configurationStatusMessage = "Configuring camera inputs..."

        session.beginConfiguration()
        
        // Clean slate - remove all existing connections and I/O
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        configurationProgress = 0.3
        configurationStatusMessage = "Creating camera outputs..."

        // Create fresh outputs
        primaryPhotoOutput = AVCapturePhotoOutput()
        secondaryPhotoOutput = AVCapturePhotoOutput()
        primaryVideoOutput = AVCaptureVideoDataOutput()
        secondaryVideoOutput = AVCaptureVideoDataOutput()
        audioOutput = AVCaptureAudioDataOutput()

        configurationProgress = 0.4
        configurationStatusMessage = "Finding camera devices..."

        guard let (primaryDevice, secondaryDevice) = devicesFor(pair: pair) else {
            session.commitConfiguration()
            
            // Try to find a supported pair instead
            let supportedPairs = getSupportedCameraPairs()
            if let fallbackPair = supportedPairs.first, fallbackPair != pair {
                logger.log("configureSession: Falling back to supported pair: \(fallbackPair.rawValue)")
                currentPair = fallbackPair
                UserDefaults.standard.set(fallbackPair.rawValue, forKey: "cameraPair")
                configureSession(pair: fallbackPair)
                return
            }
            
            errorMessage = "Could not find compatible cameras for multi-cam recording on this device."
            isConfiguring = false
            return
        }

        configurationProgress = 0.5
        configurationStatusMessage = "Validating device compatibility..."
        
        // Double-check multi-cam compatibility before attempting to add inputs
        guard areDevicesCompatibleForMultiCam(primaryDevice, secondaryDevice) else {
            session.commitConfiguration()
            logger.log("configureSession: Device combination not supported for multi-cam - \(primaryDevice.deviceType.rawValue) + \(secondaryDevice.deviceType.rawValue)")
            
            // Virtual back camera rejected — fall back to physical wide-angle camera
            if pair == .frontAndBack,
               let currentBack = detectedBackCamera,
               currentBack.deviceType != .builtInWideAngleCamera,
               let wideAngle = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                logger.log("configureSession: virtual device not multi-cam compatible — falling back to builtInWideAngleCamera")
                detectedBackCamera = wideAngle
                configureSession(pair: pair)
                return
            }
            
            // Try a different supported pair
            let supportedPairs = getSupportedCameraPairs()
            if let fallbackPair = supportedPairs.first, fallbackPair != pair {
                logger.log("configureSession: Devices incompatible, trying fallback pair: \(fallbackPair.rawValue)")
                currentPair = fallbackPair
                UserDefaults.standard.set(fallbackPair.rawValue, forKey: "cameraPair")
                configureSession(pair: fallbackPair)
                return
            }
            
            errorMessage = "These cameras cannot be used simultaneously on this device."
            isConfiguring = false
            return
        }
        
        logger.log("configureSession: Using devices - Primary: \(primaryDevice.deviceType.rawValue), Secondary: \(secondaryDevice.deviceType.rawValue)")

        do {
            configurationProgress = 0.55
            configurationStatusMessage = "Connecting camera inputs..."
            
            let primaryInput = try AVCaptureDeviceInput(device: primaryDevice)
            let secondaryInput = try AVCaptureDeviceInput(device: secondaryDevice)

            guard session.canAddInput(primaryInput), session.canAddInput(secondaryInput) else {
                session.commitConfiguration()
                logger.log("configureSession: Session cannot add camera inputs - this should not happen after compatibility check")
                errorMessage = "Failed to configure camera session. Please try again."
                isConfiguring = false
                return
            }
            session.addInputWithNoConnections(primaryInput)
            session.addInputWithNoConnections(secondaryInput)

            configurationProgress = 0.6
            configurationStatusMessage = "Setting up microphone..."

            if let mic = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(audioInput) {
                session.addInputWithNoConnections(audioInput)
            }

            configurationProgress = 0.7
            configurationStatusMessage = "Configuring video outputs..."

            primaryVideoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            secondaryVideoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
            // Drop late frames rather than queuing them — keeps framerate stable
            primaryVideoOutput.alwaysDiscardsLateVideoFrames   = true
            secondaryVideoOutput.alwaysDiscardsLateVideoFrames = true

            configurationProgress = 0.8
            configurationStatusMessage = "Adding outputs to session..."

            for output in [primaryPhotoOutput, secondaryPhotoOutput,
                           primaryVideoOutput, secondaryVideoOutput, audioOutput] as [AVCaptureOutput] {
                if session.canAddOutput(output) { session.addOutputWithNoConnections(output) }
            }

            configurationProgress = 0.9
            configurationStatusMessage = "Establishing camera connections..."

            let primaryPort = primaryInput.ports(
                for: .video,
                sourceDeviceType: primaryDevice.deviceType,
                sourceDevicePosition: primaryDevice.position
            ).first

            let secondaryPort = secondaryInput.ports(
                for: .video,
                sourceDeviceType: secondaryDevice.deviceType,
                sourceDevicePosition: secondaryDevice.position
            ).first

            if let port = primaryPort {
                for conn in [AVCaptureConnection(inputPorts: [port], output: primaryPhotoOutput),
                             AVCaptureConnection(inputPorts: [port], output: primaryVideoOutput)] {
                    if session.canAddConnection(conn) { session.addConnection(conn) }
                }
                let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: newPrimaryLayer)
                if session.canAddConnection(previewConn) { session.addConnection(previewConn) }
            }

            if let port = secondaryPort {
                for conn in [AVCaptureConnection(inputPorts: [port], output: secondaryPhotoOutput),
                             AVCaptureConnection(inputPorts: [port], output: secondaryVideoOutput)] {
                    if session.canAddConnection(conn) { session.addConnection(conn) }
                }
                let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: newSecondaryLayer)
                if session.canAddConnection(previewConn) { session.addConnection(previewConn) }
            }

            if let audioDeviceInput = session.inputs
                .compactMap({ $0 as? AVCaptureDeviceInput })
                .first(where: { $0.device.hasMediaType(.audio) }),
               let audioPort = audioDeviceInput.ports(
                for: .audio, sourceDeviceType: nil, sourceDevicePosition: .unspecified).first {
                let conn = AVCaptureConnection(inputPorts: [audioPort], output: audioOutput)
                if session.canAddConnection(conn) { session.addConnection(conn) }
            }

        } catch {
            session.commitConfiguration()
            errorMessage = error.localizedDescription
            isConfiguring = false
            return
        }

        session.commitConfiguration()

        configurationProgress = 1.0
        configurationStatusMessage = "Finalizing camera setup..."

        // Update preview layers atomically on main thread
        Task { @MainActor in
            self.primaryPreviewLayer = newPrimaryLayer
            self.secondaryPreviewLayer = newSecondaryLayer
            // Apply front-camera mirror to the secondary layer if needed
            self.applyFrontCameraMirror()
        }

        _outputLock.lock()
        let oldRecorder = _recorder
        _primaryVideoOutput   = primaryVideoOutput
        _secondaryVideoOutput = secondaryVideoOutput
        _audioOutput          = audioOutput
        _recorder             = VideoRecorder()
        _outputLock.unlock()
        // Clean up any prepared-but-unused writers from the previous session.
        oldRecorder.cancelPrepare()
        isVideoRecorderReady = false

        let captureSession = session
        Task.detached(priority: .userInitiated) {
            await MainActor.run { [weak self] in
                self?.configurationStatusMessage = "Starting camera..."
            }
            
            print("🎬 Starting camera session...")
            captureSession.startRunning()
            let running = captureSession.isRunning
            print("📹 Session running: \(running)")
            
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isSessionRunning = running
                self.isConfiguring = false
                self.configurationProgress = 0.0
                self.configurationStatusMessage = ""
                if running == false && self.errorMessage == nil {
                    self.errorMessage = "Camera failed to start. Try closing other apps using the camera, or restart your phone."
                }
            }
        }
    }

    private func devicesFor(pair: CameraPair) -> (AVCaptureDevice, AVCaptureDevice)? {
        let devices = getCompatibleDevicesFor(pair: pair)
        guard let primary = devices?.0, let secondary = devices?.1 else { return nil }
        
        // First, validate that these devices can actually be used together for multi-cam
        guard areDevicesCompatibleForMultiCam(primary, secondary) else {
            logger.log("devicesFor: Devices not compatible for multi-cam - \(primary.deviceType.rawValue) + \(secondary.deviceType.rawValue)")
            
            // For front+back pairs, try falling back to physical wide-angle if using virtual device
            if pair == .frontAndBack,
               let virtualDevice = detectedBackCamera,
               virtualDevice.deviceType != .builtInWideAngleCamera,
               let wideAngle = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
               areDevicesCompatibleForMultiCam(wideAngle, front) {
                logger.log("devicesFor: Falling back to physical wide-angle camera for multi-cam compatibility")
                return (wideAngle, front)
            }
            
            return nil
        }
        
        return (primary, secondary)
    }
    
    private func getCompatibleDevicesFor(pair: CameraPair) -> (AVCaptureDevice, AVCaptureDevice)? {
        switch pair {
        case .frontAndBack:
            guard let back = detectedBackCamera
                          ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            else { return nil }
            return (back, front)

        case .wideAndUltrawide:
            guard let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            else { return nil }
            return (wide, ultra)

        case .ultraAndFront:
            guard let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
                  let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            else { return nil }
            return (ultra, front)

        case .wideAndTelephoto:
            guard let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
            else { return nil }
            return (wide, tele)

        case .telephotoAndFront:
            guard let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back),
                  let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            else { return nil }
            return (tele, front)

        case .ultrawideAndTelephoto:
            guard let ultra = AVCaptureDevice.default(.builtInUltraWideCamera,  for: .video, position: .back),
                  let tele  = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
            else { return nil }
            return (ultra, tele)
        }
    }
    
    private func areDevicesCompatibleForMultiCam(_ device1: AVCaptureDevice, _ device2: AVCaptureDevice) -> Bool {
        // Get supported multi-cam device sets
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        
        // Check if this combination is supported
        for deviceSet in discoverySession.supportedMultiCamDeviceSets {
            if deviceSet.contains(device1) && deviceSet.contains(device2) {
                logger.log("areDevicesCompatibleForMultiCam: ✅ Compatible - \(device1.deviceType.rawValue) + \(device2.deviceType.rawValue)")
                return true
            }
        }
        
        logger.log("areDevicesCompatibleForMultiCam: ❌ Device combination not supported - \(device1.deviceType.rawValue) + \(device2.deviceType.rawValue)")
        
        // Log all available device sets for debugging
        logger.log("Available multi-cam device sets:")
        for (index, deviceSet) in discoverySession.supportedMultiCamDeviceSets.enumerated() {
            let deviceNames = deviceSet.map { $0.deviceType.rawValue }.joined(separator: " + ")
            logger.log("  Set \(index): \(deviceNames)")
        }
        
        return false
    }

    // MARK: - Photo Capture

    func capturePhoto() {
        logger.log("capturePhoto: pair=\(currentPair.rawValue) layout=\(layoutMode) flash=\(flashMode.displayName)")
        photoCapturePair          = currentPair
        photoCaptureLayout        = layoutMode
        photoCapturePipWidth      = pipWidth
        photoCaptureAspectRatio   = aspectRatio
        photoCaptureFrameStyle    = pipFrameStyle
        photoCaptureFrameColor    = pipFrameColor
        photoCapturePipShape      = pipShape
        photoCaptureIsSwapped     = isSwapped
        pendingPrimaryPhotoData   = nil
        pendingSecondaryPhotoData = nil

        let settings = AVCapturePhotoSettings()
        settings.flashMode = flashMode

        let secondarySettings = AVCapturePhotoSettings()
        secondarySettings.flashMode = flashMode

        primaryPhotoOutput.capturePhoto(with: settings, delegate: self)
        secondaryPhotoOutput.capturePhoto(with: secondarySettings, delegate: self)
    }

    // Delayed dual capture: primary fires immediately, secondary fires after a countdown.
    func captureDelayedPrimary() {
        logger.log("captureDelayedPrimary: firing primary now, awaiting secondary")
        photoCapturePair          = currentPair
        photoCaptureLayout        = layoutMode
        photoCapturePipWidth      = pipWidth
        photoCaptureAspectRatio   = aspectRatio
        photoCaptureFrameStyle    = pipFrameStyle
        photoCaptureFrameColor    = pipFrameColor
        photoCapturePipShape      = pipShape
        photoCaptureIsSwapped    = isSwapped
        pendingPrimaryPhotoData  = nil
        pendingSecondaryPhotoData = nil
        awaitingDelayedSecondary = true

        let settings = AVCapturePhotoSettings()
        settings.flashMode = flashMode
        primaryPhotoOutput.capturePhoto(with: settings, delegate: self)
    }

    func captureDelayedSecondary() {
        logger.log("captureDelayedSecondary: firing secondary after delay")
        guard awaitingDelayedSecondary else { return }
        awaitingDelayedSecondary = false
        let settings = AVCapturePhotoSettings()
        secondaryPhotoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func finishPhotoCapture() {
        guard let primaryData = pendingPrimaryPhotoData,
              let secondaryData = pendingSecondaryPhotoData,
              let primaryImg = UIImage(data: primaryData),
              let secondaryImg = UIImage(data: secondaryData) else {
            logger.log("finishPhotoCapture: missing data — aborting composite")
            return
        }
        logger.log("finishPhotoCapture: compositing \(photoCaptureLayout) pair=\(photoCapturePair.rawValue) swapped=\(photoCaptureIsSwapped)")

        pendingPrimaryPhotoData = nil
        pendingSecondaryPhotoData = nil

        // Respect swap: the full-screen camera becomes the main image in the composite
        var mainImg = photoCaptureIsSwapped ? secondaryImg : primaryImg
        var pipImg  = photoCaptureIsSwapped ? primaryImg   : secondaryImg

        // Mirror front camera: flip the front-camera image horizontally to match preview
        if photoCapturePair == .frontAndBack,
           UserDefaults.standard.bool(forKey: "mirrorFrontCamera") {
            // Secondary is front camera regardless of swap
            let flipped = secondaryImg.flippedHorizontally()
            if photoCaptureIsSwapped { mainImg = flipped } else { pipImg = flipped }
        }

        let rawComposite = makeComposite(main: mainImg, pip: pipImg,
                                         layout: photoCaptureLayout,
                                         pipWidthFraction: photoCapturePipWidth / max(displayWidth, 1))
        // Aspect ratio crop only applies to PiP — Spotlight has its own inherent 4:5 canvas
        // and additional cropping would chop off part of each panel.
        let composite = photoCaptureLayout == .pip
            ? cropToAspectRatio(rawComposite, ratio: photoCaptureAspectRatio.ratio)
            : rawComposite

        let item = MediaItem(type: .photo, pair: photoCapturePair)
        item.primaryImage = composite
        item.thumbnail = composite
        capturedItems.insert(item, at: 0)

        Task {
            if saveDestination == .files {
                let name = "dualcam_\(Int(Date().timeIntervalSince1970)).jpg"
                let url  = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                if let data = composite.jpegData(compressionQuality: 0.95) {
                    try? data.write(to: url)
                    pendingExportURL = url
                }
            } else {
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: composite)
                    }
                    await flashSavedBanner()
                    sendSavedNotification(title: "Photo Saved", body: "Your dual-camera photo was saved to the camera roll.")
                } catch {
                    print("Failed to save photo to photo library: \(error)")
                }
            }
        }
    }

    private func cropToAspectRatio(_ image: UIImage, ratio: CGFloat?) -> UIImage {
        guard let ratio else { return image }
        let w = image.size.width, h = image.size.height
        let targetH = w / ratio
        let cropRect: CGRect
        if targetH <= h {
            cropRect = CGRect(x: 0, y: (h - targetH) / 2, width: w, height: targetH)
        } else {
            let targetW = h * ratio
            cropRect = CGRect(x: (w - targetW) / 2, y: 0, width: targetW, height: h)
        }
        
        let renderer = UIGraphicsImageRenderer(size: cropRect.size)
        return renderer.image { _ in
            let drawOrigin = CGPoint(x: -cropRect.minX, y: -cropRect.minY)
            image.draw(at: drawOrigin)
        }
    }

    private func drawPipFrame(in rect: CGRect, shape: PipShape, cornerRadius: CGFloat,
                               scale: CGFloat, context ctx: UIGraphicsImageRendererContext) {
        let lw    = max(2.5, scale * 0.003)
        let c     = photoCaptureFrameColor.uiColor
        let style = photoCaptureFrameStyle
        guard style != .none else { return }

        switch style {
        case .none: break

        case .solid:
            let b = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cornerRadius)
            b.lineWidth = lw; c.setStroke(); b.stroke()

        case .thick:
            let b = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cornerRadius)
            b.lineWidth = lw * 3.5; c.setStroke(); b.stroke()

        case .double:
            let outer = UIBezierPath.pathForShape(shape, in: rect.insetBy(dx: -lw, dy: -lw), cornerRadius: cornerRadius + lw)
            outer.lineWidth = lw; c.withAlphaComponent(0.9).setStroke(); outer.stroke()
            let inner = UIBezierPath.pathForShape(shape, in: rect.insetBy(dx: lw * 2, dy: lw * 2), cornerRadius: max(0, cornerRadius - lw * 2))
            inner.lineWidth = lw * 0.75; c.withAlphaComponent(0.65).setStroke(); inner.stroke()

        case .dashed:
            let b = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cornerRadius)
            b.lineWidth = lw * 1.5
            b.setLineDash([lw * 5, lw * 2.5], count: 2, phase: 0)
            c.setStroke(); b.stroke()

        case .glass:
            let b = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cornerRadius)
            b.lineWidth = lw; c.withAlphaComponent(0.72).setStroke(); b.stroke()

        case .glow:
            ctx.cgContext.saveGState()
            ctx.cgContext.setShadow(offset: .zero, blur: scale * 0.012,
                                    color: c.withAlphaComponent(0.7).cgColor)
            let b = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cornerRadius)
            b.lineWidth = lw * 1.5; c.setStroke(); b.stroke()
            ctx.cgContext.restoreGState()

        case .neon:
            ctx.cgContext.saveGState()
            ctx.cgContext.setShadow(offset: .zero, blur: scale * 0.024,
                                    color: c.withAlphaComponent(0.9).cgColor)
            let b = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cornerRadius)
            b.lineWidth = lw * 1.2
            c.setStroke()
            b.stroke()
            
            ctx.cgContext.setShadow(offset: .zero, blur: scale * 0.008,
                                    color: UIColor.white.cgColor)
            b.stroke()
            ctx.cgContext.restoreGState()
        }
    }

    private func makeComposite(main: UIImage, pip: UIImage,
                               layout: LayoutMode, pipWidthFraction: CGFloat) -> UIImage {
        switch layout {
        case .pip:   return makeCompositePiP(main: main, pip: pip, widthFraction: pipWidthFraction)
        case .spotH: return makeCompositeSpotlight(main: main, pip: pip)
        }
    }

    // Aspect-fill draw: scales image to fill rect (center-crop), clipped.
    // Always uses UIBezierPath.addClip() which is reliable with UIImage.draw(in:).
    private func drawFill(_ image: UIImage, in rect: CGRect,
                          shape: PipShape? = nil,
                          roundedRadius: CGFloat = 0,
                          context ctx: UIGraphicsImageRendererContext) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = max(rect.width / s.width, rect.height / s.height)
        let drawRect = CGRect(
            x: rect.minX + (rect.width  - s.width  * scale) / 2,
            y: rect.minY + (rect.height - s.height * scale) / 2,
            width:  s.width  * scale,
            height: s.height * scale
        )
        ctx.cgContext.saveGState()
        let clipPath: UIBezierPath
        if let sh = shape {
            clipPath = UIBezierPath.pathForShape(sh, in: rect, cornerRadius: roundedRadius)
        } else {
            clipPath = roundedRadius > 0
                ? UIBezierPath(roundedRect: rect, cornerRadius: roundedRadius)
                : UIBezierPath(rect: rect)
        }
        clipPath.addClip()
        image.draw(in: drawRect)
        ctx.cgContext.restoreGState()
    }

    private func makeCompositePiP(main: UIImage, pip: UIImage, widthFraction: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: main.size)
        return renderer.image { ctx in
            // Main fills canvas
            drawFill(main, in: CGRect(origin: .zero, size: main.size), context: ctx)

            let pipNatural = pip.size  // already orientation-corrected by UIKit
            let pipW   = main.size.width * widthFraction
            let rawPipH = pipW * (pipNatural.height / max(pipNatural.width, 1))
            // Circle requires a square rect so ovalIn: produces a true circle, not an ellipse
            let pipH   = photoCapturePipShape == .circle ? pipW : rawPipH
            let margin = main.size.width * 0.025
            // Radius relative to pip width matches the preview's 20pt/108pt ≈ 0.185 ratio
            let radius = pipW * 0.185

            let halfW = pipW / 2 + margin
            let halfH = pipH / 2 + margin
            let cx: CGFloat = pipPosition.x < 0.5 ? halfW : main.size.width  - halfW
            let cy: CGFloat = pipPosition.y < 0.5 ? halfH : main.size.height - halfH
            let pipRect = CGRect(x: cx - pipW / 2, y: cy - pipH / 2, width: pipW, height: pipH)

            // Shadow
            ctx.cgContext.saveGState()
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: main.size.width * 0.006),
                                    blur: main.size.width * 0.018,
                                    color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIBezierPath.pathForShape(photoCapturePipShape, in: pipRect, cornerRadius: radius).fill()
            ctx.cgContext.restoreGState()

            // Pip content — aspect-filled, clipped to custom shape
            drawFill(pip, in: pipRect, shape: photoCapturePipShape, roundedRadius: radius, context: ctx)

            // Border based on selected frame style and shape
            drawPipFrame(in: pipRect, shape: photoCapturePipShape, cornerRadius: radius, scale: main.size.width, context: ctx)
        }
    }

    private func makeCompositeSpotlight(main: UIImage, pip: UIImage) -> UIImage {
        let W = main.size.width
        // 4:5 portrait canvas — Instagram-friendly, shows main prominently
        let H = W * 1.25
        let gap: CGFloat = max(4, W * 0.004)
        let mainH    = (H - gap) * 0.65
        let pipSlotH = H - mainH - gap
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H))
        return renderer.image { ctx in
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: W, height: H))
            drawFill(main, in: CGRect(x: 0, y: 0,           width: W, height: mainH),    context: ctx)
            drawFill(pip,  in: CGRect(x: 0, y: mainH + gap, width: W, height: pipSlotH), context: ctx)
        }
    }

    // MARK: - Video Capture

    func prepareForRecording(highFrameRate: Bool) {
        _recorder.cancelPrepare()
        isVideoRecorderReady = false

        let recorder = _recorder
        let codec = recordingCodec
        logger.log("prepareForRecording: HFR=\(highFrameRate) codec=\(codec.rawValue)")
        Task.detached(priority: .userInitiated) { [weak self] in
            recorder.prepare(highFrameRate: highFrameRate, codec: codec)
            await MainActor.run {
                if recorder.isPreparedForRecording {
                    self?.isVideoRecorderReady = true
                }
            }
        }
    }

    func cancelVideoRecorderPrep() {
        _recorder.cancelPrepare()
        isVideoRecorderReady = false
    }

    func startRecording(highFrameRate: Bool) {
        guard !_recorder.isRecording else { return }
        guard _recorder.startRecording() != nil else {
            logger.log("startRecording: recorder not ready — ignoring")
            return
        }
        logger.log("startRecording: started (HFR=\(highFrameRate), limit=\(CaptureManager.maxRecordingSeconds)s, pair=\(currentPair.rawValue))")
        isRecording = true
        videoCaptureAspectRatio = aspectRatio
        videoCaptureHighFrameRate = highFrameRate
        recordingSecondsElapsed = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.recordingSecondsElapsed += 1
                if self.recordingSecondsElapsed >= CaptureManager.maxRecordingSeconds {
                    self.stopRecording()
                }
            }
        }
    }

    func stopRecording() {
        logger.log("stopRecording: elapsed=\(recordingSecondsElapsed)s pair=\(currentPair.rawValue) layout=\(layoutMode)")
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false          // clear immediately so UI stops showing the recording state
        isVideoRecorderReady = false // disable the record button until the recorder fully resets
        let swapped    = isSwapped
        let pair       = currentPair
        let layout     = layoutMode
        let pipFrac    = pipWidth / max(displayWidth, 1)
        let pipPos     = pipPosition
        let frmStyle   = pipFrameStyle
        let frmColor   = pipFrameColor
        let frmShape   = pipShape
        let snapRatio  = videoCaptureAspectRatio
        let snapHFR    = videoCaptureHighFrameRate
        let qual       = videoQuality
        let autoRaw    = autoSaveRawFeeds
        
        Task {
            guard let urls = await _recorder.stopRecording() else { 
                logger.log("stopRecording: VideoRecorder.stopRecording() returned nil - processing aborted")
                await MainActor.run {
                    self.errorMessage = "Failed to stop recording properly. Please try recording again."
                    self.isVideoRecorderReady = false
                    self.recordingSecondsElapsed = 0
                }
                return 
            }
            logger.log("stopRecording: VideoRecorder returned URLs successfully - starting processing")
            isVideoRecorderReady = false
            recordingSecondsElapsed = 0
            
            // Create processing task
            let task = ProcessingTask(
                primaryURL: urls.primary,
                secondaryURL: urls.secondary,
                isSwapped: swapped,
                layout: layout,
                aspectRatio: snapRatio,
                highFrameRate: snapHFR,
                pipWidthFraction: pipFrac,
                pipPosition: pipPos,
                frameStyle: frmStyle,
                frameColor: frmColor,
                pipShape: frmShape,
                quality: qual,
                pair: pair
            )
            
            if isBackgroundProcessingEnabled {
                // Add to queue for background processing
                processingQueue.append(task)
                processNextVideoInQueue()
            } else {
                // Process immediately in foreground
                processVideoTask(task, inBackground: false)
            }
            
            // Auto-prepare for the next recording so the user doesn't have to
            // switch modes. Uses the same highFrameRate that was active.
            // Delay this slightly to ensure the previous recording resources are fully cleaned up
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                self.prepareForRecording(highFrameRate: snapHFR)
            }
        }
    }
    
    private func processVideoTask(_ task: ProcessingTask, inBackground: Bool) {
        guard !isProcessingVideo else { return }

        activeProcessingTask?.cancel()
        isProcessingVideo = true
        processingProgress = 0.0
        processingStatusMessage = "Starting video processing..."
        currentProcessingTask = task
        
        if inBackground {
            startBackgroundTask()
            // Start Live Activity for background processing
            liveActivityManager.startVideoProcessingActivity(videosInQueue: processingQueue.count + 1)
        }
        
        activeProcessingTask = Task.detached(priority: .userInitiated) {
            await MainActor.run { [weak self] in
                self?.processingProgress = 0.1
                self?.processingStatusMessage = "Preparing video merge..."
                if inBackground {
                    self?.liveActivityManager.updateProgress(0.1, statusMessage: "Preparing video merge...", videosInQueue: self?.processingQueue.count ?? 0)
                }
            }
            
            let merged = await VideoRecorder.mergeWithLayout(
                primary: task.primaryURL,
                secondary: task.secondaryURL,
                isSwapped: task.isSwapped,
                layout: task.layout,
                aspectRatio: task.aspectRatio,
                highFrameRate: task.highFrameRate,
                pipWidthFraction: task.pipWidthFraction,
                pipPosition: task.pipPosition,
                frameStyle: task.frameStyle,
                frameColor: task.frameColor,
                pipShape: task.pipShape,
                quality: task.quality,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        
                        // Create more detailed status messages based on progress
                        let statusMessages = [
                            (0.0...0.2, "Compositing dual cameras"),
                            (0.2...0.5, "Rendering video layers"),
                            (0.5...0.8, "Encoding final video"),
                            (0.8...1.0, "Finalizing export")
                        ]
                        
                        var currentMessage = "Processing video"
                        for (range, message) in statusMessages {
                            if range.contains(progress) {
                                currentMessage = message
                                break
                            }
                        }
                        
                        self.processingProgress = 0.1 + (progress * 0.8) // 10-90%
                        let progressPercent = Int(progress * 100)
                        self.processingStatusMessage = "\(currentMessage)... \(progressPercent)%"
                        
                        if inBackground {
                            self.liveActivityManager.updateProgress(
                                0.1 + (progress * 0.8),
                                statusMessage: "\(currentMessage)... \(progressPercent)%",
                                videosInQueue: self.processingQueue.count
                            )
                        }
                    }
                }
            )
            
            await MainActor.run { [weak self] in
                guard let self else { return }
                
                if let merged = merged {
                    self.processingProgress = 0.95
                    self.processingStatusMessage = "Saving to photo library..."
                    if inBackground {
                        self.liveActivityManager.updateProgress(0.95, statusMessage: "Saving to photo library...", videosInQueue: self.processingQueue.count)
                    }
                    
                    let item = MediaItem(type: .video, pair: task.pair)
                    item.primaryVideoURL = merged
                    self.capturedItems.insert(item, at: 0)
                    // Generate thumbnail off the main thread — copyCGImage is synchronous and slow
                    let mergedForThumb = merged
                    Task.detached(priority: .utility) {
                        let thumb = self.thumbnailFrom(url: mergedForThumb)
                        await MainActor.run { item.thumbnail = thumb }
                    }
                    
                    Task {
                        if self.saveDestination == .files {
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                self.processingProgress = 1.0
                                self.processingStatusMessage = "Ready to export"
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(300))
                                    self.pendingExportURL = merged
                                    self.isProcessingVideo = false
                                    self.processingProgress = 0.0
                                    self.processingStatusMessage = ""
                                    self.currentProcessingTask = nil
                                    self.recentVideoItem = item
                                    if inBackground { self.endBackgroundTask() }
                                    self.processNextVideoInQueue()
                                }
                            }
                            return
                        }
                        do {
                            try await PHPhotoLibrary.shared().performChanges {
                                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: merged)
                            }
                            await self.flashSavedBanner()
                            self.sendSavedNotification(title: "Video Saved", body: "Your dual-camera video is ready in the camera roll.")
                            
                            await MainActor.run { [weak self] in
                                self?.processingProgress = 1.0
                                self?.processingStatusMessage = "Video saved successfully!"
                                
                                if inBackground {
                                    self?.liveActivityManager.updateProgress(1.0, statusMessage: "Video saved successfully!", videosInQueue: self?.processingQueue.count ?? 0)
                                    
                                    // Complete Live Activity if queue is empty, otherwise continue
                                    if self?.processingQueue.isEmpty == true {
                                        self?.liveActivityManager.completeActivity()
                                    }
                                }
                                
                                // Auto-delay clear the success message
                                let savedItem = item
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(2))
                                    self?.isProcessingVideo = false
                                    self?.processingProgress = 0.0
                                    self?.processingStatusMessage = ""
                                    self?.currentProcessingTask = nil
                                    // Signal preview AFTER the loading overlay is gone
                                    self?.recentVideoItem = savedItem

                                    if inBackground {
                                        self?.endBackgroundTask()
                                    }

                                    // Process next item in queue
                                    self?.processNextVideoInQueue()
                                }
                            }
                        } catch {
                            await MainActor.run { [weak self] in
                                print("Failed to save video: \(error)")
                                self?.errorMessage = "Failed to save video: \(error.localizedDescription)"
                                self?.isProcessingVideo = false
                                self?.processingProgress = 0.0
                                self?.processingStatusMessage = ""
                                self?.currentProcessingTask = nil
                                
                                if inBackground {
                                    self?.liveActivityManager.cancelActivity()
                                    self?.endBackgroundTask()
                                }
                            }
                        }
                    }
                } else {
                    self.isProcessingVideo = false
                    self.processingProgress = 0.0
                    self.processingStatusMessage = ""
                    self.currentProcessingTask = nil
                    self.errorMessage = "Video processing failed. The recording may be too short."
                    
                    if inBackground {
                        self.liveActivityManager.cancelActivity()
                        self.endBackgroundTask()
                    }
                }
            }
        }
    }
    
    private func processNextVideoInQueue() {
        guard !isProcessingVideo, !processingQueue.isEmpty else { return }
        let nextTask = processingQueue.removeFirst()
        processVideoTask(nextTask, inBackground: true)
    }
    
    private func startBackgroundTask() {
        endBackgroundTask() // End any existing task
        
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "VideoProcessing") { [weak self] in
            // Called when the system is about to terminate the background task
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
            backgroundTaskIdentifier = .invalid
        }
    }
    
    // MARK: - Queue Management
    
    func clearProcessingQueue() {
        processingQueue.removeAll()
        liveActivityManager.cancelActivity()
    }
    
    func cancelCurrentProcessing() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        isProcessingVideo = false
        processingProgress = 0.0
        processingStatusMessage = ""
        currentProcessingTask = nil
        liveActivityManager.cancelActivity()
        endBackgroundTask()
    }

    func flashSavedBanner() {
        savedBannerVersion += 1
        let v = savedBannerVersion
        showSavedBanner = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2400))
            if self.savedBannerVersion == v { self.showSavedBanner = false }
        }
    }

    private func sendSavedNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated private func thumbnailFrom(url: URL?) -> UIImage? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if let cgImage = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CaptureManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            logger.log("photoOutput error: \(error.localizedDescription)")
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            logger.log("photoOutput: no file data representation")
            return
        }
        let exifFlash = (photo.metadata["{Exif}"] as? [String: Any])?["Flash"] as? Int ?? 0
        let actuallyFired = (exifFlash & 0x1) != 0

        Task { @MainActor in
            if actuallyFired {
                logger.log("photoOutput: flash fired")
                flashFired = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    flashFired = false
                }
            }
            if output === primaryPhotoOutput {
                logger.log("photoOutput: primary received (\(data.count / 1024)KB)")
                pendingPrimaryPhotoData = data
            } else {
                logger.log("photoOutput: secondary received (\(data.count / 1024)KB)")
                pendingSecondaryPhotoData = data
            }
            if pendingPrimaryPhotoData != nil && pendingSecondaryPhotoData != nil {
                logger.log("photoOutput: both received — compositing")
                finishPhotoCapture()
            }
        }
    }

    // MARK: - Video Processing Controls

    func cancelProcessing() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        isProcessingVideo = false
        processingProgress = 0.0
        processingStatusMessage = ""
        currentProcessingTask = nil
        rawCapturedURLs = nil
        liveActivityManager.cancelActivity()
        endBackgroundTask()
    }
    
    func saveBothVideosSeparately() {
        guard let urls = rawCapturedURLs else { return }
        isProcessingVideo = false
        
        let pURL = urls.primary
        let sURL = urls.secondary
        let pair = currentPair
        
        let pItem = MediaItem(type: .video, pair: pair)
        pItem.primaryVideoURL = pURL
        pItem.thumbnail = thumbnailFrom(url: pURL)
        
        let sItem = MediaItem(type: .video, pair: pair)
        sItem.primaryVideoURL = sURL
        sItem.thumbnail = thumbnailFrom(url: sURL)
        
        capturedItems.insert(pItem, at: 0)
        capturedItems.insert(sItem, at: 0)
        
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: pURL)
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: sURL)
                }
                await flashSavedBanner()
            } catch {
                print("Failed to save raw feeds: \(error)")
            }
        }
        
        rawCapturedURLs = nil
    }
}

extension Notification.Name {
    static let dualCamVolumeShutter = Notification.Name("com.dualcam.volumeShutter")
}

// MARK: - Sample Buffer Delegates

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Called on videoQueue — VideoRecorder is a plain class with NSLock so we
    // can write synchronously here with zero Task/await overhead per frame.
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        _outputLock.lock()
        let pvo = _primaryVideoOutput
        let svo = _secondaryVideoOutput
        let ao  = _audioOutput
        let rec = _recorder
        _outputLock.unlock()

        if output === pvo {
            rec.appendPrimaryVideo(sampleBuffer)
        } else if output === svo {
            rec.appendSecondaryVideo(sampleBuffer)
        } else if output === ao {
            rec.appendAudio(sampleBuffer)
        }
    }
}

private extension UIImage {
    func flippedHorizontally() -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.translateBy(x: size.width, y: 0)
            ctx.cgContext.scaleBy(x: -1, y: 1)
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
