import AVFoundation
import UIKit

// Plain class (not actor) so sample buffer delegates can call append methods
// directly on the videoQueue without Task/await overhead. An NSLock guards
// the mutable state accessed from both the capture queue and main thread.
class VideoRecorder {
    private var primaryWriter: AVAssetWriter?
    private var secondaryWriter: AVAssetWriter?
    private var primaryVideoInput: AVAssetWriterInput?
    private var secondaryVideoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var isPrepared = false
    private var preparationId: UUID?

    private var primaryURL: URL?
    private var secondaryURL: URL?

    private let lock = NSLock()
    private(set) var isRecording = false

    private static func videoSettings(highFrameRate: Bool, codec: RecordingCodec) -> [String: Any] {
        let (avCodec, bitrate): (AVVideoCodecType, Int) = {
            switch codec {
            case .h264:
                return (.h264, 4_000_000)
            case .hevcSafe:
                // HEVC hardware encoder, same bitrate → ~40% smaller files, same perceptual quality
                return (.hevc, 4_000_000)
            case .hevcSave:
                // HEVC at lower bitrate → ~60% smaller files, modest battery savings,
                // slight quality risk on fast motion
                return (.hevc, 2_500_000)
            }
        }()
        var props: [String: Any] = [
            AVVideoAverageBitRateKey:          bitrate,
            AVVideoExpectedSourceFrameRateKey: highFrameRate ? 60 : 30
        ]
        if avCodec == .h264 {
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey:  avCodec,
            AVVideoWidthKey:  1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: props
        ]
    }

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey:         kAudioFormatMPEG4AAC,
        AVSampleRateKey:       44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey:   64_000
    ]

    /// Thread-safe read of preparation state for UI polling.
    var isPreparedForRecording: Bool {
        lock.lock()
        let v = isPrepared
        lock.unlock()
        return v
    }

    func prepare(highFrameRate: Bool, codec: RecordingCodec) {
        lock.lock()
        guard !isRecording, !isPrepared else { 
            AppLogger.shared.log("VideoRecorder.prepare: Skipping preparation - isRecording: \(isRecording), isPrepared: \(isPrepared)")
            lock.unlock(); return 
        }
        // Stamp this preparation so we can detect stale completions.
        let myId = UUID()
        preparationId = myId
        AppLogger.shared.log("VideoRecorder.prepare: Starting preparation with ID \(myId)")
        lock.unlock()

        let tmp = FileManager.default.temporaryDirectory
        let pURL = tmp.appendingPathComponent("primary_\(UUID().uuidString).mov")
        let sURL = tmp.appendingPathComponent("secondary_\(UUID().uuidString).mov")

        guard let pw = try? AVAssetWriter(outputURL: pURL, fileType: .mov),
              let sw = try? AVAssetWriter(outputURL: sURL, fileType: .mov) else { 
            AppLogger.shared.log("VideoRecorder.prepare: Failed to create AVAssetWriters")
            return 
        }

        let pvi = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(highFrameRate: highFrameRate, codec: codec))
        let svi = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(highFrameRate: highFrameRate, codec: codec))
        let ai  = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)

        // Rotate 90 deg CCW so portrait playback is correct (sensor delivers 1280x720 landscape)
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)
        pvi.transform = portrait
        svi.transform = portrait

        pvi.expectsMediaDataInRealTime = true
        svi.expectsMediaDataInRealTime = true
        ai.expectsMediaDataInRealTime  = true

        pw.add(pvi); pw.add(ai)
        sw.add(svi)

        // This is the slow part (~100-300 ms) -- doing it here instead of at tap time.
        AppLogger.shared.log("VideoRecorder.prepare: Starting writers...")
        pw.startWriting()
        sw.startWriting()
        AppLogger.shared.log("VideoRecorder.prepare: Writers started - primary status: \(pw.status.rawValue), secondary status: \(sw.status.rawValue)")

        lock.lock()
        // If cancelPrepare() was called while we were doing the slow work, discard.
        guard preparationId == myId else {
            AppLogger.shared.log("VideoRecorder.prepare: Preparation was cancelled during setup (ID mismatch)")
            lock.unlock()
            pw.cancelWriting()
            sw.cancelWriting()
            try? FileManager.default.removeItem(at: pURL)
            try? FileManager.default.removeItem(at: sURL)
            return
        }
        primaryWriter = pw;   secondaryWriter = sw
        primaryVideoInput = pvi; secondaryVideoInput = svi; audioInput = ai
        primaryURL = pURL;    secondaryURL = sURL
        isPrepared = true;    sessionStarted = false
        AppLogger.shared.log("VideoRecorder.prepare: Preparation completed successfully - isPrepared=\(isPrepared)")
        lock.unlock()
    }

    /// Cancel any in-flight or completed preparation, cleaning up writers.
    /// Call this when switching away from video mode or when the session reconfigures.
    func cancelPrepare() {
        lock.lock()
        preparationId = nil  // invalidate any in-flight prepare()
        guard !isRecording else { 
            AppLogger.shared.log("VideoRecorder.cancelPrepare: Skipping cancellation - recording in progress")
            lock.unlock(); return 
        }
        let hadPreparedContent = isPrepared
        AppLogger.shared.log("VideoRecorder.cancelPrepare: Cancelling preparation (was prepared: \(hadPreparedContent))")
        let pw = primaryWriter
        let sw = secondaryWriter
        let pURL = primaryURL
        let sURL = secondaryURL
        primaryWriter = nil;     secondaryWriter = nil
        primaryVideoInput = nil; secondaryVideoInput = nil
        audioInput = nil
        primaryURL = nil;        secondaryURL = nil
        isPrepared = false;      sessionStarted = false
        lock.unlock()

        // Clean up writers outside the lock to avoid blocking.
        if let pw, pw.status == .writing { pw.cancelWriting() }
        if let sw, sw.status == .writing { sw.cancelWriting() }
        if let pURL { try? FileManager.default.removeItem(at: pURL) }
        if let sURL { try? FileManager.default.removeItem(at: sURL) }
    }

    // Called at tap -- nearly instant because prepare() already ran.
    // Returns nil if not yet prepared; caller should NOT block the main thread.
    func startRecording() -> (primary: URL, secondary: URL)? {
        lock.lock()
        guard isPrepared, let p = primaryURL, let s = secondaryURL else {
            AppLogger.shared.log("VideoRecorder.startRecording failed - isPrepared: \(isPrepared), primaryURL: \(primaryURL != nil), secondaryURL: \(secondaryURL != nil)")
            lock.unlock(); return nil
        }
        isRecording = true
        AppLogger.shared.log("VideoRecorder.startRecording success - isRecording set to true")
        lock.unlock()
        return (p, s)
    }

    func appendPrimaryVideo(_ buffer: CMSampleBuffer) {
        lock.lock()
        guard isRecording, let input = primaryVideoInput, let writer = primaryWriter else {
            lock.unlock(); return
        }
        if !sessionStarted {
            let ts = CMSampleBufferGetPresentationTimeStamp(buffer)
            writer.startSession(atSourceTime: ts)
            secondaryWriter?.startSession(atSourceTime: ts)
            sessionStarted = true
            AppLogger.shared.log("Recording session started at time: \(ts.seconds)")
        }
        let ready = input.isReadyForMoreMediaData
        lock.unlock()
        if ready { input.append(buffer) }
    }

    func appendSecondaryVideo(_ buffer: CMSampleBuffer) {
        lock.lock()
        guard isRecording, let input = secondaryVideoInput, sessionStarted else {
            lock.unlock(); return
        }
        let ready = input.isReadyForMoreMediaData
        lock.unlock()
        if ready { input.append(buffer) }
    }

    func appendAudio(_ buffer: CMSampleBuffer) {
        lock.lock()
        guard isRecording, let input = audioInput, sessionStarted else {
            lock.unlock(); return
        }
        let ready = input.isReadyForMoreMediaData
        lock.unlock()
        if ready { input.append(buffer) }
    }

    func stopRecording() async -> (primary: URL, secondary: URL)? {
        lock.lock()
        guard isRecording, let pURL = primaryURL, let sURL = secondaryURL,
              let pw = primaryWriter, let sw = secondaryWriter else {
            AppLogger.shared.log("VideoRecorder.stopRecording failed - isRecording: \(isRecording), primaryURL: \(primaryURL != nil), secondaryURL: \(secondaryURL != nil), primaryWriter: \(primaryWriter != nil), secondaryWriter: \(secondaryWriter != nil)")
            lock.unlock(); return nil
        }
        isRecording = false
        isPrepared  = false
        lock.unlock()

        primaryVideoInput?.markAsFinished()
        secondaryVideoInput?.markAsFinished()
        audioInput?.markAsFinished()

        AppLogger.shared.log("VideoRecorder.stopRecording: Finishing writers - primary status: \(pw.status.rawValue), secondary status: \(sw.status.rawValue)")
        
        await pw.finishWriting()
        await sw.finishWriting()
        
        AppLogger.shared.log("VideoRecorder.stopRecording: Writers finished - primary status: \(pw.status.rawValue), secondary status: \(sw.status.rawValue)")
        
        // Check for errors
        if pw.status == .failed, let error = pw.error {
            AppLogger.shared.log("VideoRecorder.stopRecording: Primary writer failed with error: \(error)")
        }
        if sw.status == .failed, let error = sw.error {
            AppLogger.shared.log("VideoRecorder.stopRecording: Secondary writer failed with error: \(error)")
        }

        primaryWriter = nil;     secondaryWriter = nil
        primaryVideoInput = nil; secondaryVideoInput = nil
        audioInput = nil;        sessionStarted = false

        AppLogger.shared.log("VideoRecorder.stopRecording: Returning URLs - primary: \(pURL.lastPathComponent), secondary: \(sURL.lastPathComponent)")
        return (pURL, sURL)
    }

    // Returns the axis-aligned display size of a video track after its preferred transform.
    private static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let pts = [CGPoint(x: 0, y: 0),
                   CGPoint(x: naturalSize.width, y: 0),
                   CGPoint(x: 0, y: naturalSize.height),
                   CGPoint(x: naturalSize.width, y: naturalSize.height)]
            .map { $0.applying(transform) }
        return CGSize(width:  pts.map(\.x).max()! - pts.map(\.x).min()!,
                      height: pts.map(\.y).max()! - pts.map(\.y).min()!)
    }

    // Aspect-FILL: scale so the video fills (and may overflow) the target rect,
    // centered. Matches AVCaptureVideoPreviewLayer's resizeAspectFill behaviour.
    // Overflow is clipped implicitly by the composition render canvas or by the
    // rendering order of adjacent layer instructions.
    private static func fillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        into target: CGRect
    ) -> CGAffineTransform {
        let pts = [CGPoint(x: 0, y: 0),
                   CGPoint(x: naturalSize.width, y: 0),
                   CGPoint(x: 0, y: naturalSize.height),
                   CGPoint(x: naturalSize.width, y: naturalSize.height)]
            .map { $0.applying(preferredTransform) }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let dispW = maxX - minX, dispH = maxY - minY

        let scale   = max(target.width / dispW, target.height / dispH)   // FILL, not fit
        let offsetX = target.minX + (target.width  - dispW * scale) / 2 - minX * scale
        let offsetY = target.minY + (target.height - dispH * scale) / 2 - minY * scale

        return preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }

    static func mergeWithLayout(
        primary: URL, secondary: URL,
        isSwapped: Bool, layout: LayoutMode,
        aspectRatio: AspectRatio?, highFrameRate: Bool,
        pipWidthFraction: CGFloat, pipPosition: CGPoint,
        frameStyle: PipFrameStyle = .none,
        frameColor: PipFrameColor = .white,
        pipShape: PipShape = .roundedRect,
        quality: VideoQuality = .medium,
        progressCallback: ((Double) -> Void)? = nil
    ) async -> URL? {
        let primaryAsset   = AVURLAsset(url: primary)
        let secondaryAsset = AVURLAsset(url: secondary)

        guard let primaryVideoTrack   = try? await primaryAsset.loadTracks(withMediaType: .video).first,
              let secondaryVideoTrack = try? await secondaryAsset.loadTracks(withMediaType: .video).first
        else { return nil }

        let primaryDuration   = (try? await primaryAsset.load(.duration))   ?? .zero
        let secondaryDuration = (try? await secondaryAsset.load(.duration)) ?? .zero
        let duration = CMTimeMinimum(primaryDuration, secondaryDuration)
        
        AppLogger.shared.log("DualCam Merge Debug:")
        AppLogger.shared.log("  Primary duration: \(primaryDuration.seconds)s")
        AppLogger.shared.log("  Secondary duration: \(secondaryDuration.seconds)s") 
        AppLogger.shared.log("  Final duration: \(duration.seconds)s")
        AppLogger.shared.log("  Is swapped: \(isSwapped)")
        AppLogger.shared.log("  Layout: \(layout)")
        AppLogger.shared.log("  Main track will be: \(isSwapped ? "secondary" : "primary")")
        AppLogger.shared.log("  PiP track will be: \(isSwapped ? "primary" : "secondary")")
        
        // Check for frame availability at the start
        let startTime = CMTime(value: 0, timescale: 600) // Use a higher timescale for precision
        AppLogger.shared.log("  Checking frame availability at start time...")
        
        guard duration.seconds > 0 else { 
            AppLogger.shared.log("Error - Invalid duration: videos too short")
            return nil 
        }

        let mainTrack = isSwapped ? secondaryVideoTrack : primaryVideoTrack
        let pipTrack  = isSwapped ? primaryVideoTrack   : secondaryVideoTrack
        let mainAsset = isSwapped ? secondaryAsset      : primaryAsset

        let mainNatural   = (try? await mainTrack.load(.naturalSize))        ?? CGSize(width: 1280, height: 720)
        let mainTransform = (try? await mainTrack.load(.preferredTransform)) ?? .identity
        let pipNatural    = (try? await pipTrack.load(.naturalSize))         ?? CGSize(width: 1280, height: 720)
        let pipTransform  = (try? await pipTrack.load(.preferredTransform))  ?? .identity

        // Derive portrait display size from the main track
        let mainPts = [CGPoint(x: 0, y: 0),
                       CGPoint(x: mainNatural.width, y: 0),
                       CGPoint(x: 0, y: mainNatural.height),
                       CGPoint(x: mainNatural.width, y: mainNatural.height)]
            .map { $0.applying(mainTransform) }
        let dispW = (mainPts.map(\.x).max()! - mainPts.map(\.x).min()!)
        let dispH = (mainPts.map(\.y).max()! - mainPts.map(\.y).min()!)
        
        var renderSize = CGSize(width: dispW, height: dispH)
        
        if layout == .spotH {
            renderSize = CGSize(width: dispW, height: dispW * 1.25)
        } else if layout == .pip, let ratio = aspectRatio?.ratio {
            let targetH = dispW / ratio
            if targetH <= dispH {
                renderSize = CGSize(width: dispW, height: targetH)
            } else {
                let targetW = dispH * ratio
                renderSize = CGSize(width: targetW, height: dispH)
            }
        }

        // Pip display size — used to size the PiP slot to match the pip's natural aspect ratio
        // so fill transform == exact fit (no letterbox bars, no overflow).
        let pipDisp = displaySize(naturalSize: pipNatural, transform: pipTransform)

        let gap: CGFloat = 4
        let mainFinalTransform: CGAffineTransform
        let pipFinalTransform: CGAffineTransform
        var videoPipRect: CGRect? = nil   // only set for .pip — used for frame overlay

        switch layout {
        case .pip:
            mainFinalTransform = fillTransform(naturalSize: mainNatural,
                                               preferredTransform: mainTransform,
                                               into: CGRect(origin: .zero, size: renderSize))
            let pipW    = renderSize.width * pipWidthFraction
            let rawPipH = pipW * (pipDisp.height / max(pipDisp.width, 1))
            let pipH    = pipShape == .circle ? pipW : rawPipH
            let margin  = renderSize.width * 0.025
            let halfW   = pipW / 2 + margin
            let halfH   = pipH / 2 + margin
            let cx: CGFloat = pipPosition.x < 0.5 ? halfW : renderSize.width  - halfW
            let cy: CGFloat = pipPosition.y < 0.5 ? halfH : renderSize.height - halfH
            let pipRect = CGRect(x: cx - pipW / 2, y: cy - pipH / 2, width: pipW, height: pipH)
            videoPipRect = pipRect
            pipFinalTransform = fillTransform(naturalSize: pipNatural,
                                              preferredTransform: pipTransform,
                                              into: pipRect)

        case .spotH:
            let mainH  = (renderSize.height - gap) * 0.65
            let pipH   = renderSize.height - mainH - gap
            mainFinalTransform = fillTransform(naturalSize: mainNatural,
                                               preferredTransform: mainTransform,
                                               into: CGRect(x: 0, y: 0,
                                                            width: renderSize.width, height: mainH))
            pipFinalTransform  = fillTransform(naturalSize: pipNatural,
                                               preferredTransform: pipTransform,
                                               into: CGRect(x: 0, y: mainH + gap,
                                                            width: renderSize.width, height: pipH))
        }

        let composition = AVMutableComposition()
        guard let mainComp = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid),
              let pipComp  = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        // Check if this might be a synchronization issue with missing initial frames
        let timingTolerance = CMTime(value: 1, timescale: 30) // 1/30 second tolerance
        let baseTimeRange = CMTimeRange(start: .zero, duration: duration)
        var adjustedTimeRange = baseTimeRange
        
        // If one video is significantly shorter at the start, we might have sync issues
        let durationDiff = abs(primaryDuration.seconds - secondaryDuration.seconds)
        if durationDiff > 0.1 { // More than 100ms difference
            AppLogger.shared.log("  Duration difference detected: \(durationDiff)s - adjusting for sync")
            // Use a small offset to account for potential timing differences
            let offset = CMTime(value: 1, timescale: 600) // 1.67ms offset
            adjustedTimeRange = CMTimeRange(start: offset, duration: CMTimeSubtract(duration, offset))
        }
        
        let finalTimeRange = adjustedTimeRange
        
        do {
            try mainComp.insertTimeRange(finalTimeRange, of: mainTrack, at: .zero)
            AppLogger.shared.log("DualCam: Inserted main track (ID: \(mainComp.trackID))")
        } catch {
            AppLogger.shared.log("DualCam: Failed to insert main track: \(error)")
            return nil
        }
        
        do {
            try pipComp.insertTimeRange(finalTimeRange, of: pipTrack, at: .zero)
            AppLogger.shared.log("DualCam: Inserted pip track (ID: \(pipComp.trackID))")
        } catch {
            AppLogger.shared.log("DualCam: Failed to insert pip track: \(error)")
            // Even if PiP track insertion fails, continue with main track only
            AppLogger.shared.log("Warning: PiP track insertion failed, continuing with main track only")
        }

        // Audio is always written into the primary file — load it from there regardless of swap.
        if let audioTrack = try? await primaryAsset.loadTracks(withMediaType: .audio).first,
           let audioComp  = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioComp.insertTimeRange(finalTimeRange, of: audioTrack, at: .zero)
        }

        // Corner radius relative to pip width → matches preview's 20pt/108pt ≈ 0.185 ratio
        // at default pip size, and scales correctly at all display sizes.
        let pipCornerRadius = (videoPipRect?.width ?? renderSize.width * 0.28) * 0.185

        let instruction = DualCamVideoCompositionInstruction(
            timeRange:     finalTimeRange,
            mainTrackID:   mainComp.trackID,
            pipTrackID:    pipComp.trackID,
            layoutMode:    layout,
            renderSize:    renderSize,
            pipRect:       videoPipRect,
            mainTransform: mainFinalTransform,
            pipTransform:  pipFinalTransform,
            frameStyle:    frameStyle,
            frameColor:    frameColor,
            pipShape:      pipShape,
            cornerRadius:  pipCornerRadius
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = DualCamVideoCompositor.self
        videoComposition.instructions  = [instruction]
        videoComposition.frameDuration = CMTime(value: 1, timescale: highFrameRate ? 60 : 30)
        videoComposition.renderSize    = renderSize

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dualcam_\(UUID().uuidString).mov")

        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        var preferredPresets: [String]
        switch quality {
        case .high:
            preferredPresets = [AVAssetExportPresetHighestQuality, AVAssetExportPresetMediumQuality]
        case .medium:
            preferredPresets = [AVAssetExportPresetMediumQuality, AVAssetExportPresetHighestQuality]
        case .low:
            preferredPresets = [AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality]
        }
        
        guard let preset = preferredPresets.first(where: { compatiblePresets.contains($0) }),
              let exporter = AVAssetExportSession(asset: composition, presetName: preset)
        else { return nil }
        exporter.outputURL        = outputURL
        exporter.outputFileType   = .mov
        exporter.videoComposition = videoComposition

        // Progress reporting with better status messages
        if let progressCallback = progressCallback {
            progressCallback(0.0)
            
            // Create a task to monitor progress with more frequent updates
            let progressTask = Task {
                var lastProgress: Float = 0.0
                while !Task.isCancelled && exporter.status == .exporting {
                    let currentProgress = exporter.progress
                    if currentProgress > lastProgress {
                        await MainActor.run {
                            progressCallback(Double(currentProgress))
                        }
                        lastProgress = currentProgress
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            
            await exporter.export()
            progressTask.cancel()
            progressCallback(1.0)
        } else {
            await exporter.export()
        }

        if exporter.status == .completed {
            AppLogger.shared.log("DualCam export completed successfully")
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: secondary)
            return outputURL
        } else {
            AppLogger.shared.log("Video export failed with status: \(exporter.status.rawValue), error: \(String(describing: exporter.error))")
            print("Video export failed with status: \(exporter.status.rawValue), error: \(String(describing: exporter.error))")
        }
        return nil
    }



    // MARK: - Frame overlay helpers

    private static func addFrameOverlay(
        to parent: CALayer, pipRect: CGRect, cornerRadius: CGFloat,
        style: PipFrameStyle, color: PipFrameColor, renderWidth: CGFloat
    ) {
        let lw  = max(3.0, renderWidth * 0.004)
        let c   = color.uiColor
        let path = UIBezierPath(roundedRect: pipRect, cornerRadius: cornerRadius).cgPath

        switch style {
        case .none: break

        case .solid:
            parent.addSublayer(sl(path, color: c, lw: lw))

        case .thick:
            parent.addSublayer(sl(path, color: c, lw: lw * 3.5))

        case .double:
            parent.addSublayer(sl(path, color: c.withAlphaComponent(0.9), lw: lw))
            let innerPath = UIBezierPath(
                roundedRect: pipRect.insetBy(dx: lw * 2, dy: lw * 2),
                cornerRadius: max(0, cornerRadius - lw * 2)).cgPath
            parent.addSublayer(sl(innerPath, color: c.withAlphaComponent(0.65), lw: lw * 0.75))

        case .dashed:
            let layer = sl(path, color: c, lw: lw * 1.5)
            layer.lineDashPattern = [NSNumber(value: lw * 4), NSNumber(value: lw * 2)]
            parent.addSublayer(layer)

        case .glass:
            parent.addSublayer(sl(path, color: c.withAlphaComponent(0.65), lw: lw))

        case .glow:
            let layer = sl(path, color: c, lw: lw * 1.5)
            layer.shadowColor   = c.cgColor
            layer.shadowOpacity = 0.85
            layer.shadowRadius  = lw * 4
            layer.shadowOffset  = .zero
            parent.addSublayer(layer)

        case .neon:
            let outer = sl(path, color: c.withAlphaComponent(0.4), lw: lw * 5)
            outer.shadowColor = c.cgColor; outer.shadowOpacity = 0.7
            outer.shadowRadius = lw * 7;   outer.shadowOffset  = .zero
            parent.addSublayer(outer)
            let inner = sl(path, color: c, lw: lw)
            inner.shadowColor = c.cgColor; inner.shadowOpacity = 1.0
            inner.shadowRadius = lw * 2.5; inner.shadowOffset  = .zero
            parent.addSublayer(inner)
        }
    }

    private static func sl(_ path: CGPath, color: UIColor, lw: CGFloat) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path        = path
        s.fillColor   = UIColor.clear.cgColor
        s.strokeColor = color.cgColor
        s.lineWidth   = lw
        return s
    }

}


// MARK: - Custom CIImage compositor

// Instruction carries all layout params into the per-frame compositor.
class DualCamVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = false
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let mainTrackID: CMPersistentTrackID
    let pipTrackID:  CMPersistentTrackID
    let layoutMode:  LayoutMode
    let renderSize:  CGSize
    let pipRect:     CGRect?        // UIKit-space pip rect (used for crop + CIImage ops)
    let ciPipRect:   CGRect?        // CIImage Y-up pip rect (used for mask/border drawing)
    let mainTransform: CGAffineTransform
    let pipTransform:  CGAffineTransform
    let frameStyle:  PipFrameStyle
    let frameColor:  PipFrameColor
    let pipShape:    PipShape
    let cornerRadius: CGFloat

    init(timeRange: CMTimeRange,
         mainTrackID: CMPersistentTrackID, pipTrackID: CMPersistentTrackID,
         layoutMode: LayoutMode, renderSize: CGSize,
         pipRect: CGRect?, mainTransform: CGAffineTransform, pipTransform: CGAffineTransform,
         frameStyle: PipFrameStyle, frameColor: PipFrameColor, pipShape: PipShape,
         cornerRadius: CGFloat) {
        self.timeRange = timeRange
        self.mainTrackID = mainTrackID; self.pipTrackID = pipTrackID
        self.layoutMode = layoutMode;   self.renderSize = renderSize
        self.pipRect = pipRect
        // Pre-compute CIImage Y-up equivalent of pipRect for mask/border rendering
        if let pr = pipRect {
            self.ciPipRect = CGRect(x: pr.minX, y: renderSize.height - pr.maxY,
                                    width: pr.width, height: pr.height)
        } else { self.ciPipRect = nil }
        self.mainTransform = mainTransform; self.pipTransform = pipTransform
        self.frameStyle = frameStyle; self.frameColor = frameColor; self.pipShape = pipShape
        self.cornerRadius = cornerRadius
        self.requiredSourceTrackIDs = [NSNumber(value: mainTrackID), NSNumber(value: pipTrackID)]
        super.init()
    }
}


class DualCamVideoCompositor: NSObject, AVVideoCompositing {
    private let renderContextQueue = DispatchQueue(label: "com.dualcam.compositor")
    private var renderContext: AVVideoCompositionRenderContext?

    // Metal-backed context for GPU-accelerated compositing
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    // Masks are identical on every frame — compute once, reuse for all frames
    private var cachedMask: CIImage?
    private var cachedBorder: CIImage?
    private var masksReady = false

    var sourcePixelBufferAttributes: [String: Any]? {
        [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
         String(kCVPixelBufferMetalCompatibilityKey): true]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
         String(kCVPixelBufferMetalCompatibilityKey): true]
    }

    func renderContextChanged(_ ctx: AVVideoCompositionRenderContext) {
        renderContextQueue.sync { renderContext = ctx }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instr = request.videoCompositionInstruction
                    as? DualCamVideoCompositionInstruction else {
                request.finish(with: NSError(domain: "DualCam", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Bad instruction type"]))
                return
            }
            guard let outBuf = renderContext?.newPixelBuffer() else {
                request.finish(with: NSError(domain: "DualCam", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No output buffer"]))
                return
            }

            let renderRect = CGRect(origin: .zero, size: instr.renderSize)
            let H = instr.renderSize.height

            // Flip: CVPixelBuffer is stored top-first; flip converts to CIImage Y-up.
            // After flip + fillTransform (UIKit Y-down), content lands at pipRect in CIImage.
            func ci(_ buf: CVPixelBuffer, _ t: CGAffineTransform) -> CIImage {
                let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                             tx: 0, ty: CGFloat(CVPixelBufferGetHeight(buf)))
                return CIImage(cvPixelBuffer: buf).transformed(by: flip).transformed(by: t)
            }

            let mainBuf = request.sourceFrame(byTrackID: instr.mainTrackID)
            let pipBuf  = request.sourceFrame(byTrackID: instr.pipTrackID)

            let mainImage = mainBuf.map { ci($0, instr.mainTransform) }
                         ?? CIImage(color: .black).cropped(to: renderRect)
            let pipImage  = pipBuf.map  { ci($0, instr.pipTransform)  }
                         ?? CIImage(color: .black).cropped(to: renderRect)

            var finalImage: CIImage

            if instr.layoutMode == .pip,
               let pipRect   = instr.pipRect,
               let ciPipRect = instr.ciPipRect {

                // Build masks once per export, not once per frame
                if !masksReady {
                    masksReady = true
                    cachedMask   = makeMask(shape: instr.pipShape, rect: ciPipRect,
                                            size: instr.renderSize, cr: instr.cornerRadius)
                    cachedBorder = instr.frameStyle != .none
                        ? makeBorder(shape: instr.pipShape, rect: ciPipRect,
                                     size: instr.renderSize, style: instr.frameStyle,
                                     color: instr.frameColor, cr: instr.cornerRadius)
                        : nil
                }

                guard let maskImage = cachedMask else {
                    request.finish(with: NSError(domain: "DualCam", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Mask failed"]))
                    return
                }

                let background = mainImage.cropped(to: renderRect)

                // Crop pip from where it actually lives in CIImage (pipRect, NOT ciPipRect)
                let croppedPip = pipImage.cropped(to: pipRect)

                // Mask to custom shape
                let blend = CIFilter(name: "CIBlendWithMask")!
                blend.setValue(croppedPip, forKey: kCIInputImageKey)
                blend.setValue(CIImage(color: .clear).cropped(to: renderRect),
                               forKey: kCIInputBackgroundImageKey)
                blend.setValue(maskImage, forKey: kCIInputMaskImageKey)
                let shapedPip = blend.outputImage!

                // Drop shadow
                let shadowAlpha = CIFilter(name: "CIColorMatrix")!
                shadowAlpha.setValue(maskImage, forKey: kCIInputImageKey)
                shadowAlpha.setValue(CIVector(x:0,y:0,z:0,w:0), forKey:"inputRVector")
                shadowAlpha.setValue(CIVector(x:0,y:0,z:0,w:0), forKey:"inputGVector")
                shadowAlpha.setValue(CIVector(x:0,y:0,z:0,w:0), forKey:"inputBVector")
                shadowAlpha.setValue(CIVector(x:0,y:0,z:0,w:0.45), forKey:"inputAVector")
                let blurFilter = CIFilter(name: "CIGaussianBlur")!
                blurFilter.setValue(shadowAlpha.outputImage, forKey: kCIInputImageKey)
                blurFilter.setValue(instr.renderSize.width * 0.018, forKey: kCIInputRadiusKey)
                let shadow = blurFilter.outputImage!
                    .transformed(by: CGAffineTransform(translationX: 0,
                                                       y: -(instr.renderSize.width * 0.006)))

                // Frame border (pre-rendered, nil if none)
                let frameBorder = cachedBorder
                    ?? CIImage(color: .clear).cropped(to: renderRect)

                // Composite: shadow → pip → border
                let comp1 = CIFilter(name: "CISourceOverCompositing")!
                comp1.setValue(shapedPip, forKey: kCIInputImageKey)
                comp1.setValue(shadow,    forKey: kCIInputBackgroundImageKey)
                let comp2 = CIFilter(name: "CISourceOverCompositing")!
                comp2.setValue(frameBorder,       forKey: kCIInputImageKey)
                comp2.setValue(comp1.outputImage, forKey: kCIInputBackgroundImageKey)
                var pipGroup = comp2.outputImage!

                // Pop-in fade (0 → 1 over first 0.5 s, pivot at pip centre in CIImage space)
                let t = request.compositionTime.seconds
                if t < 0.5 {
                    let ease = CGFloat(1.0 - pow(1.0 - t / 0.5, 4))
                    let cx = pipRect.midX, cy = pipRect.midY
                    pipGroup = pipGroup.transformed(by:
                        CGAffineTransform(translationX: cx, y: cy)
                            .scaledBy(x: ease, y: ease)
                            .translatedBy(x: -cx, y: -cy))
                    let fade = CIFilter(name: "CIColorMatrix")!
                    fade.setValue(pipGroup, forKey: kCIInputImageKey)
                    fade.setValue(CIVector(x:0,y:0,z:0,w:ease), forKey:"inputAVector")
                    pipGroup = fade.outputImage!
                }

                let final = CIFilter(name: "CISourceOverCompositing")!
                final.setValue(pipGroup,   forKey: kCIInputImageKey)
                final.setValue(background, forKey: kCIInputBackgroundImageKey)
                finalImage = final.outputImage!.cropped(to: renderRect)

            } else {
                // Spotlight: crop each image to its own slot then composite over black.
                let gap: CGFloat = 4
                let W = instr.renderSize.width
                let H2 = instr.renderSize.height
                let mainH = (H2 - gap) * 0.65
                let mainSlot = CGRect(x: 0, y: 0,           width: W, height: mainH)
                let pipSlot  = CGRect(x: 0, y: mainH + gap, width: W, height: H2 - mainH - gap)

                let black = CIImage(color: .black).cropped(to: renderRect)
                let mainCropped = mainImage.cropped(to: mainSlot)
                let pipCropped  = pipImage.cropped(to: pipSlot)

                let step1 = CIFilter(name: "CISourceOverCompositing")!
                step1.setValue(mainCropped, forKey: kCIInputImageKey)
                step1.setValue(black,       forKey: kCIInputBackgroundImageKey)
                let step2 = CIFilter(name: "CISourceOverCompositing")!
                step2.setValue(pipCropped,        forKey: kCIInputImageKey)
                step2.setValue(step1.outputImage, forKey: kCIInputBackgroundImageKey)
                finalImage = step2.outputImage!.cropped(to: renderRect)
            }

            // Flip back to pixel-buffer storage order (Y-down / top-first)
            let flipOut = CGAffineTransform(a:1, b:0, c:0, d:-1, tx:0, ty:H)
            ciContext.render(finalImage.transformed(by: flipOut),
                             to: outBuf, bounds: renderRect,
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            request.finish(withComposedVideoFrame: outBuf)
        }
    }

    // MARK: - Mask / border helpers
    // scale = 1.0 is critical: renderSize is in VIDEO PIXELS not screen points.
    // Using screen scale (2× or 3×) creates a CGImage 2–3× too large, placing the
    // white shape at wrong CIImage coordinates and making the pip invisible.

    private func makeMask(shape: PipShape, rect: CGRect,
                          size: CGSize, cr: CGFloat) -> CIImage? {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIColor.white.setFill()
            UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cr).fill()
        }
        return img.cgImage.map { CIImage(cgImage: $0) }
    }

    private func makeBorder(shape: PipShape, rect: CGRect, size: CGSize,
                             style: PipFrameStyle, color: PipFrameColor,
                             cr: CGFloat) -> CIImage? {
        let lw  = max(3.0, size.width * 0.004)
        let c   = color.uiColor
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: size))
            switch style {
            case .none: break
            case .solid:
                let p = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cr)
                p.lineWidth = lw; c.setStroke(); p.stroke()
            case .thick:
                let p = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cr)
                p.lineWidth = lw * 3.5; c.setStroke(); p.stroke()
            case .double:
                let o = UIBezierPath.pathForShape(shape, in: rect.insetBy(dx: -lw, dy: -lw),
                                                  cornerRadius: cr + lw)
                o.lineWidth = lw; c.withAlphaComponent(0.9).setStroke(); o.stroke()
                let i = UIBezierPath.pathForShape(shape, in: rect.insetBy(dx: lw*2, dy: lw*2),
                                                  cornerRadius: max(0, cr - lw*2))
                i.lineWidth = lw * 0.75; c.withAlphaComponent(0.65).setStroke(); i.stroke()
            case .dashed:
                let p = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cr)
                p.lineWidth = lw * 1.5
                p.setLineDash([lw*5, lw*2.5], count: 2, phase: 0)
                c.setStroke(); p.stroke()
            case .glass:
                let p = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cr)
                p.lineWidth = lw; c.withAlphaComponent(0.72).setStroke(); p.stroke()
            case .glow:
                ctx.cgContext.saveGState()
                ctx.cgContext.setShadow(offset: .zero, blur: size.width * 0.012,
                                        color: c.withAlphaComponent(0.7).cgColor)
                let p = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cr)
                p.lineWidth = lw * 1.5; c.setStroke(); p.stroke()
                ctx.cgContext.restoreGState()
            case .neon:
                ctx.cgContext.saveGState()
                ctx.cgContext.setShadow(offset: .zero, blur: size.width * 0.024,
                                        color: c.withAlphaComponent(0.9).cgColor)
                let p = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cr)
                p.lineWidth = lw * 1.2; c.setStroke(); p.stroke()
                ctx.cgContext.setShadow(offset: .zero, blur: size.width * 0.008,
                                        color: UIColor.white.cgColor)
                p.stroke()
                ctx.cgContext.restoreGState()
            }
        }
        return img.cgImage.map { CIImage(cgImage: $0) }
    }
}
