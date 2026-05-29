import AVFoundation
import Photos
import UIKit
import BackgroundTasks
import ActivityKit

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
    @Published var layoutMode: LayoutMode       = .pip
    @Published var pipWidth: CGFloat            = 108
    @Published var displayWidth: CGFloat        = UIScreen.main.bounds.width
    @Published var aspectRatio: AspectRatio     = .r4_3
    @Published var pipFrameStyle: PipFrameStyle = .glass
    @Published var pipFrameColor: PipFrameColor = .white
    @Published var pipShape: PipShape           = .roundedRect
    var showWatermark: Bool {
        get { UserDefaults.standard.object(forKey: "showWatermark") as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "showWatermark")
        }
    }
    @Published var videoQuality: VideoQuality   = .medium
    @Published var autoSaveRawFeeds: Bool       = false
    @Published var isLiveModeActive             = false
    @Published private(set) var isLivePhotoAvailable = false
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

    let session = AVCaptureMultiCamSession()

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
    
    // Background processing support
    @Published var processingQueue: [ProcessingTask] = []
    @Published var isBackgroundProcessingEnabled = true
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var currentProcessingTask: ProcessingTask?
    
    // Live Activity support
    private let liveActivityManager = LiveActivityManager()
    static var maxRecordingSeconds: Int {
        UserDefaults.standard.bool(forKey: "extendedRecording") ? 600 : 150
    }

    private var pendingPrimaryPhotoData: Data?
    private var pendingSecondaryPhotoData: Data?
    private var photoCapturePair: CameraPair          = .frontAndBack
    private var photoCaptureLayout: LayoutMode        = .pip
    private var photoCapturePipWidth: CGFloat         = 108
    private var photoCaptureAspectRatio: AspectRatio  = .r4_3
    private var photoCaptureFrameStyle: PipFrameStyle = .glass
    private var photoCaptureFrameColor: PipFrameColor = .white
    private var photoCapturePipShape: PipShape        = .roundedRect
    private var photoCaptureIsSwapped: Bool           = false
    // Live photo support
    nonisolated(unsafe) private var pendingLivePhotoURL: URL?
    nonisolated(unsafe) private var livePhotoStillData: Data?
    // True while waiting for the user/timer to trigger secondary in delayed-dual mode
    private(set) var awaitingDelayedSecondary = false

    override init() {
        super.init()
        isSupported  = AVCaptureMultiCamSession.isMultiCamSupported
        isConfiguring = true  // Keep overlay up until session is actually running

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

    // MARK: - Setup

    func checkPermissionsAndSetup() async {
        guard isSupported else {
            isConfiguring = false
            errorMessage = "Multi-cam not supported on this device (requires iPhone XS/XR or newer)."
            return
        }

        let hasPermissions = await requestPermissions()
        guard hasPermissions else { isConfiguring = false; return }

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
        currentPair = pair
        isSwapped = false
        zoom = 1.0
        UserDefaults.standard.set(pair.rawValue, forKey: "cameraPair")
        
        // Reset flash mode if new cameras don't support flash
        if !isFlashAvailable {
            flashMode = .off
        }
        
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
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
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
            errorMessage = "Could not find cameras for this pair on this device."
            isConfiguring = false
            return
        }

        configurationProgress = 0.5
        configurationStatusMessage = "Connecting camera inputs..."

        do {
            let primaryInput = try AVCaptureDeviceInput(device: primaryDevice)
            let secondaryInput = try AVCaptureDeviceInput(device: secondaryDevice)

            guard session.canAddInput(primaryInput), session.canAddInput(secondaryInput) else {
                session.commitConfiguration()
                errorMessage = "Cannot add camera inputs to session."
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

        configurationProgress = 0.95
        configurationStatusMessage = "Enabling live photo capture..."

        // Enable live photo capture on the primary output if hardware supports it
        if primaryPhotoOutput.isLivePhotoCaptureSupported {
            primaryPhotoOutput.isLivePhotoCaptureEnabled = true
        }

        session.commitConfiguration()

        configurationProgress = 1.0
        configurationStatusMessage = "Finalizing camera setup..."

        // Update preview layers atomically on main thread
        Task { @MainActor in
            self.primaryPreviewLayer = newPrimaryLayer
            self.secondaryPreviewLayer = newSecondaryLayer
            self.isLivePhotoAvailable = self.primaryPhotoOutput.isLivePhotoCaptureEnabled
            print("✅ Updated preview layers — live photo: \(self.isLivePhotoAvailable)")
        }

        _outputLock.lock()
        _primaryVideoOutput   = primaryVideoOutput
        _secondaryVideoOutput = secondaryVideoOutput
        _audioOutput          = audioOutput
        _recorder             = VideoRecorder()
        _outputLock.unlock()

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
        switch pair {
        case .frontAndBack:
            guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
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

    // MARK: - Photo Capture

    func capturePhoto() {
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
        pendingLivePhotoURL       = nil
        livePhotoStillData        = nil

        let settings = AVCapturePhotoSettings()
        settings.flashMode = flashMode
        // Live photo — attach a movie URL when supported and the user has enabled it
        if isLiveModeActive && primaryPhotoOutput.isLivePhotoCaptureEnabled {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("live_\(UUID().uuidString).mov")
            settings.livePhotoMovieFileURL = url
        }

        let secondarySettings = AVCapturePhotoSettings()
        secondarySettings.flashMode = flashMode

        primaryPhotoOutput.capturePhoto(with: settings, delegate: self)
        secondaryPhotoOutput.capturePhoto(with: secondarySettings, delegate: self)
    }

    // Delayed dual capture: primary fires immediately, secondary fires after a countdown.
    func captureDelayedPrimary() {
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
        awaitingDelayedSecondary = true

        let settings = AVCapturePhotoSettings()
        settings.flashMode = flashMode
        primaryPhotoOutput.capturePhoto(with: settings, delegate: self)
    }

    func captureDelayedSecondary() {
        guard awaitingDelayedSecondary else { return }
        awaitingDelayedSecondary = false
        let settings = AVCapturePhotoSettings()
        secondaryPhotoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func finishPhotoCapture() {
        guard let primaryData = pendingPrimaryPhotoData,
              let secondaryData = pendingSecondaryPhotoData,
              let primaryImg = UIImage(data: primaryData),
              let secondaryImg = UIImage(data: secondaryData) else { return }

        pendingPrimaryPhotoData = nil
        pendingSecondaryPhotoData = nil

        // Respect swap: the full-screen camera becomes the main image in the composite
        let mainImg = photoCaptureIsSwapped ? secondaryImg : primaryImg
        let pipImg  = photoCaptureIsSwapped ? primaryImg   : secondaryImg

        let rawComposite = makeComposite(main: mainImg, pip: pipImg,
                                         layout: photoCaptureLayout,
                                         pipWidthFraction: photoCapturePipWidth / max(displayWidth, 1))
        var composite = cropToAspectRatio(rawComposite, ratio: photoCaptureAspectRatio.ratio)


        let item = MediaItem(type: .photo, pair: photoCapturePair)
        item.primaryImage = composite
        item.thumbnail = composite
        capturedItems.insert(item, at: 0)

        // Snapshot live photo state before any async work
        let liveURL  = pendingLivePhotoURL
        let liveStill = livePhotoStillData
        pendingLivePhotoURL = nil
        livePhotoStillData  = nil

        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: composite)
                }
                if let movieURL = liveURL, let stillData = liveStill {
                    try await PHPhotoLibrary.shared().performChanges {
                        let req = PHAssetCreationRequest.forAsset()
                        req.addResource(with: .photo, data: stillData, options: nil)
                        let opts = PHAssetResourceCreationOptions()
                        opts.shouldMoveFile = true
                        req.addResource(with: .pairedVideo, fileURL: movieURL, options: opts)
                    }
                }
                await flashSavedBanner()
            } catch {
                print("Failed to save photo to photo library: \(error)")
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
        case .pip:
            return makeCompositePiP(main: main, pip: pip, widthFraction: pipWidthFraction)
        case .splitH:
            return makeCompositeSplit(main: main, pip: pip, horizontal: true)
        case .splitV:
            return makeCompositeSplit(main: main, pip: pip, horizontal: false)
        case .spotH:
            return makeCompositeSpotlight(main: main, pip: pip)
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

            let fraction = widthFraction.clamped(to: 0.18...0.40)
            // Use pip's natural aspect ratio for the pip rect so content is never squashed
            let pipNatural = pip.size  // already orientation-corrected by UIKit
            let pipW   = main.size.width * fraction
            let pipH   = pipW * (pipNatural.height / max(pipNatural.width, 1))
            let margin = main.size.width * 0.025
            let radius = main.size.width * 0.028

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

    private func makeCompositeSplit(main: UIImage, pip: UIImage, horizontal: Bool) -> UIImage {
        let W = main.size.width
        // Use a square canvas — each slot is W × (W-gap)/2 (landscape) for splitH,
        // or (W-gap)/2 × W (portrait strip) for splitV. Square is a clean social format.
        let gap: CGFloat = max(4, W * 0.004)
        let canvasSize = CGSize(width: W, height: W)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { ctx in
            // Black background for any gaps
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: canvasSize))

            if horizontal {
                let half = (W - gap) / 2
                drawFill(main, in: CGRect(x: 0, y: 0,          width: W, height: half), context: ctx)
                drawFill(pip,  in: CGRect(x: 0, y: half + gap, width: W, height: half), context: ctx)
            } else {
                let half = (W - gap) / 2
                drawFill(main, in: CGRect(x: 0,          y: 0, width: half, height: W), context: ctx)
                drawFill(pip,  in: CGRect(x: half + gap, y: 0, width: half, height: W), context: ctx)
            }
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
        // Runs prepare() on a background thread so startWriting() doesn't block the UI.
        let recorder = _recorder
        Task.detached(priority: .userInitiated) { recorder.prepare(highFrameRate: highFrameRate) }
    }

    func startRecording(highFrameRate: Bool) {
        guard !_recorder.isRecording else { return }
        guard _recorder.startRecording() != nil else {
            errorMessage = "Could not start recording."
            return
        }
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
        recordingTimer?.invalidate()
        recordingTimer = nil
        let swapped    = isSwapped
        let pair       = currentPair
        let layout     = layoutMode
        let pipFrac    = (pipWidth / max(displayWidth, 1)).clamped(to: 0.18...0.40)
        let pipPos     = pipPosition
        let frmStyle   = pipFrameStyle
        let frmColor   = pipFrameColor
        let frmShape   = pipShape
        let snapRatio  = videoCaptureAspectRatio
        let snapHFR    = videoCaptureHighFrameRate
        let qual       = videoQuality
        let autoRaw    = autoSaveRawFeeds
        
        Task {
            guard let urls = await _recorder.stopRecording() else { return }
            isRecording = false
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
        }
    }
    
    private func processVideoTask(_ task: ProcessingTask, inBackground: Bool) {
        guard !isProcessingVideo else { return }
        
        isProcessingVideo = true
        processingProgress = 0.0
        processingStatusMessage = "Starting video processing..."
        currentProcessingTask = task
        
        if inBackground {
            startBackgroundTask()
            // Start Live Activity for background processing
            liveActivityManager.startVideoProcessingActivity(videosInQueue: processingQueue.count + 1)
        }
        
        Task.detached(priority: .userInitiated) {
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
                    item.thumbnail = self.thumbnailFrom(url: merged)
                    self.capturedItems.insert(item, at: 0)
                    
                    Task {
                        do {
                            try await PHPhotoLibrary.shared().performChanges {
                                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: merged)
                            }
                            await self.flashSavedBanner()
                            
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
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(2))
                                    self?.isProcessingVideo = false
                                    self?.processingProgress = 0.0
                                    self?.processingStatusMessage = ""
                                    self?.currentProcessingTask = nil
                                    
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
        isProcessingVideo = false
        processingProgress = 0.0
        processingStatusMessage = ""
        currentProcessingTask = nil
        liveActivityManager.cancelActivity()
        endBackgroundTask()
    }

    private func flashSavedBanner() {
        savedBannerVersion += 1
        let v = savedBannerVersion
        showSavedBanner = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2400))
            if self.savedBannerVersion == v { self.showSavedBanner = false }
        }
    }

    private func thumbnailFrom(url: URL?) -> UIImage? {
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
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let exifFlash = (photo.metadata["{Exif}"] as? [String: Any])?["Flash"] as? Int ?? 0
        let actuallyFired = (exifFlash & 0x1) != 0

        Task { @MainActor in
            if actuallyFired {
                flashFired = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    flashFired = false
                }
            }
            if output === primaryPhotoOutput {
                pendingPrimaryPhotoData = data
                livePhotoStillData = data      // stash for possible live photo save
            } else {
                pendingSecondaryPhotoData = data
            }
            if pendingPrimaryPhotoData != nil && pendingSecondaryPhotoData != nil {
                finishPhotoCapture()
            }
        }
    }

    // Called when the paired live-photo movie is ready on disk
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingLivePhotoToMovieFileAt url: URL,
                                  duration: CMTime, photoDisplayTime: CMTime,
                                  resolvedSettings: AVCaptureResolvedPhotoSettings,
                                  error: Error?) {
        guard error == nil else { return }
        pendingLivePhotoURL = url
    }
    
    // MARK: - Video Processing Controls
    
    func cancelProcessing() {
        isProcessingVideo = false
        rawCapturedURLs = nil
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
