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

    private var primaryURL: URL?
    private var secondaryURL: URL?

    private let lock = NSLock()
    private(set) var isRecording = false

    private static func videoSettings(highFrameRate: Bool) -> [String: Any] {
        return [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:          4_000_000,
                AVVideoExpectedSourceFrameRateKey: highFrameRate ? 60 : 30,
                AVVideoProfileLevelKey:            AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
    }

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey:         kAudioFormatMPEG4AAC,
        AVSampleRateKey:       44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey:   64_000
    ]

    // Call this while the "Preparing…" indicator is visible — does the slow
    // AVAssetWriter init + startWriting() so the actual record tap is instant.
    func prepare(highFrameRate: Bool) {
        lock.lock()
        guard !isRecording, !isPrepared else { lock.unlock(); return }
        lock.unlock()

        let tmp = FileManager.default.temporaryDirectory
        let pURL = tmp.appendingPathComponent("primary_\(UUID().uuidString).mov")
        let sURL = tmp.appendingPathComponent("secondary_\(UUID().uuidString).mov")

        guard let pw = try? AVAssetWriter(outputURL: pURL, fileType: .mov),
              let sw = try? AVAssetWriter(outputURL: sURL, fileType: .mov) else { return }

        let pvi = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(highFrameRate: highFrameRate))
        let svi = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(highFrameRate: highFrameRate))
        let ai  = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)

        // Rotate 90° CCW so portrait playback is correct (sensor delivers 1280×720 landscape)
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)
        pvi.transform = portrait
        svi.transform = portrait

        pvi.expectsMediaDataInRealTime = true
        svi.expectsMediaDataInRealTime = true
        ai.expectsMediaDataInRealTime  = true

        pw.add(pvi); pw.add(ai)
        sw.add(svi)

        // This is the slow part (~100–300 ms) — doing it here instead of at tap time.
        pw.startWriting()
        sw.startWriting()

        lock.lock()
        primaryWriter = pw;   secondaryWriter = sw
        primaryVideoInput = pvi; secondaryVideoInput = svi; audioInput = ai
        primaryURL = pURL;    secondaryURL = sURL
        isPrepared = true;    sessionStarted = false
        lock.unlock()
    }

    // Called at tap — nearly instant because prepare() already ran.
    func startRecording() -> (primary: URL, secondary: URL)? {
        lock.lock()
        if !isPrepared {
            lock.unlock()
            prepare(highFrameRate: false) // Fallback if not prepared
            lock.lock()
        }
        guard isPrepared, let p = primaryURL, let s = secondaryURL else {
            lock.unlock(); return nil
        }
        isRecording = true
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
            lock.unlock(); return nil
        }
        isRecording = false
        isPrepared  = false
        lock.unlock()

        primaryVideoInput?.markAsFinished()
        secondaryVideoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await pw.finishWriting()
        await sw.finishWriting()

        primaryWriter = nil;     secondaryWriter = nil
        primaryVideoInput = nil; secondaryVideoInput = nil
        audioInput = nil;        sessionStarted = false

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
        showWatermark: Bool = true,
        quality: VideoQuality = .medium
    ) async -> URL? {
        let primaryAsset   = AVURLAsset(url: primary)
        let secondaryAsset = AVURLAsset(url: secondary)

        guard let primaryVideoTrack   = try? await primaryAsset.loadTracks(withMediaType: .video).first,
              let secondaryVideoTrack = try? await secondaryAsset.loadTracks(withMediaType: .video).first
        else { return nil }

        let primaryDuration   = (try? await primaryAsset.load(.duration))   ?? .zero
        let secondaryDuration = (try? await secondaryAsset.load(.duration)) ?? .zero
        let duration = CMTimeMinimum(primaryDuration, secondaryDuration)
        guard duration.seconds > 0 else { return nil }

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
        
        if layout == .splitH || layout == .splitV {
            renderSize = CGSize(width: dispW, height: dispW)
        } else if layout == .spotH {
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
            // Main fill-scales to cover the canvas (overflow clips at canvas edges).
            mainFinalTransform = fillTransform(naturalSize: mainNatural,
                                               preferredTransform: mainTransform,
                                               into: CGRect(origin: .zero, size: renderSize))
            // Pip slot sized to pip's natural ratio → fill == exact fit (no bars, no bleed).
            let pipW   = renderSize.width * pipWidthFraction
            let pipH   = pipW * (pipDisp.height / max(pipDisp.width, 1))
            let margin = renderSize.width * 0.025
            let halfW  = pipW / 2 + margin, halfH = pipH / 2 + margin
            let cx: CGFloat = pipPosition.x < 0.5 ? halfW : renderSize.width  - halfW
            let cy: CGFloat = pipPosition.y < 0.5 ? halfH : renderSize.height - halfH
            let pipRect = CGRect(x: cx - pipW / 2, y: cy - pipH / 2, width: pipW, height: pipH)
            videoPipRect = pipRect
            pipFinalTransform = fillTransform(naturalSize: pipNatural,
                                              preferredTransform: pipTransform,
                                              into: pipRect)

        case .splitH:
            // Both tracks fill-scale into their half. Main's downward overflow is
            // naturally overwritten by the pip track (rendered on top, layer order below).
            let half = (renderSize.height - gap) / 2
            mainFinalTransform = fillTransform(naturalSize: mainNatural,
                                               preferredTransform: mainTransform,
                                               into: CGRect(x: 0, y: 0,
                                                            width: renderSize.width, height: half))
            pipFinalTransform  = fillTransform(naturalSize: pipNatural,
                                               preferredTransform: pipTransform,
                                               into: CGRect(x: 0, y: half + gap,
                                                            width: renderSize.width, height: half))

        case .splitV:
            let half = (renderSize.width - gap) / 2
            mainFinalTransform = fillTransform(naturalSize: mainNatural,
                                               preferredTransform: mainTransform,
                                               into: CGRect(x: 0, y: 0,
                                                            width: half, height: renderSize.height))
            pipFinalTransform  = fillTransform(naturalSize: pipNatural,
                                               preferredTransform: pipTransform,
                                               into: CGRect(x: half + gap, y: 0,
                                                            width: half, height: renderSize.height))

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

        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try? mainComp.insertTimeRange(timeRange, of: mainTrack, at: .zero)
        try? pipComp.insertTimeRange(timeRange,  of: pipTrack,  at: .zero)

        // Audio is always written into the primary file — load it from there regardless of swap.
        if let audioTrack = try? await primaryAsset.loadTracks(withMediaType: .audio).first,
           let audioComp  = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioComp.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }

        let instruction = DualCamVideoCompositionInstruction(
            timeRange: timeRange,
            mainTrackID: mainComp.trackID,
            pipTrackID: pipComp.trackID,
            layoutMode: layout,
            renderSize: renderSize,
            pipRect: videoPipRect,
            mainTransform: mainFinalTransform,
            pipTransform: pipFinalTransform,
            frameStyle: frameStyle,
            frameColor: frameColor,
            pipShape: pipShape,
            showWatermark: showWatermark,
            cornerRadius: renderSize.width * 0.028
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

        await exporter.export()

        if exporter.status == .completed {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: secondary)
            return outputURL
        } else {
            print("Video export failed with status: \(exporter.status.rawValue), error: \(String(describing: exporter.error))")
        }
        return nil
    }


}

// MARK: - Custom Video Compositing

// Custom instruction that holds our layout parameters
class DualCamVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = false
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let mainTrackID: CMPersistentTrackID
    let pipTrackID: CMPersistentTrackID
    let layoutMode: LayoutMode
    let renderSize: CGSize
    let pipRect: CGRect?
    let mainTransform: CGAffineTransform
    let pipTransform: CGAffineTransform
    
    // PiP styling
    let frameStyle: PipFrameStyle
    let frameColor: PipFrameColor
    let pipShape: PipShape
    let showWatermark: Bool
    let cornerRadius: CGFloat

    init(
        timeRange: CMTimeRange,
        mainTrackID: CMPersistentTrackID,
        pipTrackID: CMPersistentTrackID,
        layoutMode: LayoutMode,
        renderSize: CGSize,
        pipRect: CGRect?,
        mainTransform: CGAffineTransform,
        pipTransform: CGAffineTransform,
        frameStyle: PipFrameStyle,
        frameColor: PipFrameColor,
        pipShape: PipShape,
        showWatermark: Bool,
        cornerRadius: CGFloat
    ) {
        self.timeRange = timeRange
        self.mainTrackID = mainTrackID
        self.pipTrackID = pipTrackID
        self.layoutMode = layoutMode
        self.renderSize = renderSize
        self.pipRect = pipRect
        self.mainTransform = mainTransform
        self.pipTransform = pipTransform
        self.frameStyle = frameStyle
        self.frameColor = frameColor
        self.pipShape = pipShape
        self.showWatermark = showWatermark
        self.cornerRadius = cornerRadius
        
        self.requiredSourceTrackIDs = [
            NSNumber(value: mainTrackID),
            NSNumber(value: pipTrackID)
        ]
        super.init()
    }
}

class DualCamVideoCompositor: NSObject, AVVideoCompositing {
    private let renderContextQueue = DispatchQueue(label: "com.dualcam.videocompositor")
    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    var sourcePixelBufferAttributes: [String: Any]? {
        return [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
            String(kCVPixelBufferMetalCompatibilityKey): true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        return [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
            String(kCVPixelBufferMetalCompatibilityKey): true
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContextQueue.sync {
            self.renderContext = newRenderContext
        }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? DualCamVideoCompositionInstruction else {
                request.finish(with: NSError(domain: "DualCamVideoCompositor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid instruction type."]))
                return
            }

            let mainPixelBuffer = request.sourceFrame(byTrackID: instruction.mainTrackID)
            let pipPixelBuffer = request.sourceFrame(byTrackID: instruction.pipTrackID)

            guard let outputPixelBuffer = renderContext?.newPixelBuffer() else {
                request.finish(with: NSError(domain: "DualCamVideoCompositor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create output pixel buffer."]))
                return
            }

            let renderRect = CGRect(origin: .zero, size: instruction.renderSize)
            
            let mainImage: CIImage
            if let mb = mainPixelBuffer {
                let h = CGFloat(CVPixelBufferGetHeight(mb))
                let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
                mainImage = CIImage(cvPixelBuffer: mb).transformed(by: flip).transformed(by: instruction.mainTransform)
            } else {
                mainImage = CIImage(color: .black).cropped(to: renderRect)
            }

            let pipImage: CIImage
            if let pb = pipPixelBuffer {
                let h = CGFloat(CVPixelBufferGetHeight(pb))
                let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
                pipImage = CIImage(cvPixelBuffer: pb).transformed(by: flip).transformed(by: instruction.pipTransform)
            } else {
                pipImage = CIImage(color: .clear).cropped(to: renderRect)
            }

            var finalImage: CIImage

            if instruction.layoutMode == .pip, let pipRect = instruction.pipRect {
                // 1. Draw main image
                let background = mainImage.cropped(to: renderRect)

                // 2. Convert pipRect from UIKit Y-down space into CIImage Y-up space,
                //    then crop the pip image to that converted rect.
                let ciPipRect = CGRect(
                    x: pipRect.minX,
                    y: instruction.renderSize.height - pipRect.maxY,
                    width: pipRect.width,
                    height: pipRect.height
                )
                let croppedPip = pipImage.cropped(to: ciPipRect)
                
                // Create custom shape mask — uses CIImage Y-up rect so the mask
                // sits in the same coordinate space as the composited images.
                guard let maskImage = createShapeMask(shape: instruction.pipShape, rect: ciPipRect, renderRect: renderRect, cornerRadius: instruction.cornerRadius) else {
                    request.finish(with: NSError(domain: "DualCamVideoCompositor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create shape mask."]))
                    return
                }
                
                // Apply the mask to the PiP image
                let blendFilter = CIFilter(name: "CIBlendWithMask")!
                blendFilter.setValue(croppedPip, forKey: kCIInputImageKey)
                blendFilter.setValue(CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: instruction.renderSize)), forKey: kCIInputBackgroundImageKey)
                blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)
                let roundedPip = blendFilter.outputImage!

                // 3. Create Drop Shadow of matching shape
                let shadowFilter = CIFilter(name: "CIGaussianBlur")!
                let shadowMask = CIFilter(name: "CIColorMatrix")!
                shadowMask.setValue(maskImage, forKey: kCIInputImageKey)
                shadowMask.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
                shadowMask.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
                shadowMask.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
                shadowMask.setValue(CIVector(x: 0, y: 0, z: 0, w: 0.45), forKey: "inputAVector")
                
                shadowFilter.setValue(shadowMask.outputImage, forKey: kCIInputImageKey)
                shadowFilter.setValue(instruction.renderSize.width * 0.018, forKey: kCIInputRadiusKey)
                let shadow = shadowFilter.outputImage!
                    .transformed(by: CGAffineTransform(translationX: 0, y: -instruction.renderSize.width * 0.006)) // UIKit/CoreImage Y-axis difference

                // 4. Create Frame Border of matching shape (also in CIImage Y-up space)
                var frameImage = CIImage(color: .clear).cropped(to: renderRect)
                if instruction.frameStyle != .none {
                    if let border = createShapeBorder(shape: instruction.pipShape, rect: ciPipRect, renderSize: instruction.renderSize, frameStyle: instruction.frameStyle, frameColor: instruction.frameColor, cornerRadius: instruction.cornerRadius) {
                        frameImage = border
                    }
                }

                // 5. Composite them all together: Shadow -> PiP -> Border
                let compShadowPip = CIFilter(name: "CISourceOverCompositing")!
                compShadowPip.setValue(roundedPip, forKey: kCIInputImageKey)
                compShadowPip.setValue(shadow, forKey: kCIInputBackgroundImageKey)
                
                let compFullPip = CIFilter(name: "CISourceOverCompositing")!
                compFullPip.setValue(frameImage, forKey: kCIInputImageKey)
                compFullPip.setValue(compShadowPip.outputImage, forKey: kCIInputBackgroundImageKey)
                
                var finalPipGroup = compFullPip.outputImage!
                
                // Animate pop-in for the first 0.6 seconds to hide delayed/missing starting frames
                let time = request.compositionTime.seconds
                let animDuration = 0.6
                if time < animDuration {
                    let progress = time / animDuration
                    let easeOut = 1.0 - pow(1.0 - progress, 4) // Quartic ease out
                    
                    // Use CIImage-space pip center for the scale pivot
                    let scaleTransform = CGAffineTransform(translationX: ciPipRect.midX, y: ciPipRect.midY)
                        .scaledBy(x: CGFloat(easeOut), y: CGFloat(easeOut))
                        .translatedBy(x: -ciPipRect.midX, y: -ciPipRect.midY)
                    
                    finalPipGroup = finalPipGroup.transformed(by: scaleTransform)
                    
                    let alphaFilter = CIFilter(name: "CIColorMatrix")!
                    alphaFilter.setValue(finalPipGroup, forKey: kCIInputImageKey)
                    alphaFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(easeOut)), forKey: "inputAVector")
                    finalPipGroup = alphaFilter.outputImage!
                }
                
                let compFinal = CIFilter(name: "CISourceOverCompositing")!
                compFinal.setValue(finalPipGroup, forKey: kCIInputImageKey)
                compFinal.setValue(background, forKey: kCIInputBackgroundImageKey)
                
                finalImage = compFinal.outputImage!.cropped(to: renderRect)

            } else {
                // Split or Spotlight
                // In these modes, the layouts are just sharp rectangles, so we just composite them directly
                // mainImage is already transformed to fill its half
                // pipImage is transformed to fill its half
                // pip layer sits on top
                let comp = CIFilter(name: "CISourceOverCompositing")!
                comp.setValue(pipImage.cropped(to: renderRect), forKey: kCIInputImageKey)
                comp.setValue(mainImage.cropped(to: renderRect), forKey: kCIInputBackgroundImageKey)
                finalImage = comp.outputImage!.cropped(to: renderRect)
            }
            
            // Watermark disabled

            let flipOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: instruction.renderSize.height)
            let finalToRender = finalImage.transformed(by: flipOutput)

            self.ciContext.render(finalToRender, to: outputPixelBuffer, bounds: renderRect, colorSpace: CGColorSpaceCreateDeviceRGB())
            request.finish(withComposedVideoFrame: outputPixelBuffer)
        }
    }

    private func createShapeMask(shape: PipShape, rect: CGRect, renderRect: CGRect, cornerRadius: CGFloat) -> CIImage? {
        let size = renderRect.size
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor.clear.cgColor)
            ctx.fill(renderRect)
            
            ctx.setFillColor(UIColor.white.cgColor)
            let path = UIBezierPath.pathForShape(shape, in: rect, cornerRadius: cornerRadius)
            path.fill()
        }
        guard let cg = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    private func createShapeBorder(shape: PipShape, rect: CGRect, renderSize: CGSize, frameStyle: PipFrameStyle, frameColor: PipFrameColor, cornerRadius: CGFloat) -> CIImage? {
        let size = renderSize
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor.clear.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            
            let lw = max(3.0, renderSize.width * 0.004)
            let c = frameColor.uiColor
            ctx.setStrokeColor(c.cgColor)
            
            let insetRect = rect.insetBy(dx: lw / 2, dy: lw / 2)
            
            switch frameStyle {
            case .none:
                break
            case .solid:
                ctx.setLineWidth(lw)
                let path = UIBezierPath.pathForShape(shape, in: insetRect, cornerRadius: max(0, cornerRadius - lw/2))
                path.stroke()
            case .thick:
                let thickLw = lw * 3.5
                ctx.setLineWidth(thickLw)
                let path = UIBezierPath.pathForShape(shape, in: rect.insetBy(dx: thickLw/2, dy: thickLw/2), cornerRadius: max(0, cornerRadius - thickLw/2))
                path.stroke()
            case .double:
                ctx.setLineWidth(lw)
                let pathOuter = UIBezierPath.pathForShape(shape, in: insetRect, cornerRadius: max(0, cornerRadius - lw/2))
                c.withAlphaComponent(0.9).setStroke()
                pathOuter.stroke()
                
                let innerInset = lw * 2
                ctx.setLineWidth(lw * 0.75)
                let pathInner = UIBezierPath.pathForShape(shape, in: rect.insetBy(dx: innerInset, dy: innerInset), cornerRadius: max(0, cornerRadius - innerInset))
                c.withAlphaComponent(0.65).setStroke()
                pathInner.stroke()
            case .dashed:
                ctx.setLineWidth(lw * 1.5)
                let path = UIBezierPath.pathForShape(shape, in: insetRect, cornerRadius: max(0, cornerRadius - lw * 0.75))
                path.setLineDash([lw * 5, lw * 2.5], count: 2, phase: 0)
                path.stroke()
            case .glass:
                ctx.setLineWidth(lw)
                let path = UIBezierPath.pathForShape(shape, in: insetRect, cornerRadius: max(0, cornerRadius - lw/2))
                c.withAlphaComponent(0.65).setStroke()
                path.stroke()
            case .glow, .neon:
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: renderSize.width * 0.012, color: c.withAlphaComponent(0.7).cgColor)
                ctx.setLineWidth(lw * 1.5)
                let path = UIBezierPath.pathForShape(shape, in: insetRect, cornerRadius: max(0, cornerRadius - lw * 0.75))
                path.stroke()
                ctx.restoreGState()
            }
        }
        guard let cg = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    private func createWatermarkImage(renderSize: CGSize) -> CIImage? {
        let scale = renderSize.width
        
        // Safe bundle-aware asset loading for background-thread and custom contexts
        var logo = UIImage(named: "noticedicon")
        if logo == nil {
            logo = UIImage(named: "noticedicon", in: Bundle.main, compatibleWith: nil)
        }
        
        guard let logoImg = logo else { return nil }
        
        let logoSize = max(32.0, scale * 0.05) // 5% of the video canvas width
        let padding = logoSize * 0.2
        let totalSize = logoSize + padding * 2
        let size = CGSize(width: totalSize, height: totalSize)
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { context in
            let r = CGRect(origin: .zero, size: size)
            let ctx = context.cgContext
            
            // Premium background glass capsule
            let path = UIBezierPath(roundedRect: r, cornerRadius: totalSize * 0.28)
            UIColor.black.withAlphaComponent(0.4).setFill()
            path.fill()
            
            // Ultra-subtle liquid glass border
            UIColor.white.withAlphaComponent(0.2).setStroke()
            path.lineWidth = max(1.0, scale * 0.0012)
            path.stroke()
            
            // Draw logo with smooth rounded clipping and neon ring
            let logoRect = CGRect(
                x: padding,
                y: padding,
                width: logoSize,
                height: logoSize
            )
            ctx.saveGState()
            let logoPath = UIBezierPath(roundedRect: logoRect, cornerRadius: logoSize * 0.24)
            logoPath.addClip()
            logoImg.draw(in: logoRect)
            ctx.restoreGState()
            
            UIColor.white.withAlphaComponent(0.3).setStroke()
            logoPath.lineWidth = max(1.0, scale * 0.0008)
            logoPath.stroke()
        }
        
        guard let cgImage = uiImage.cgImage else { return nil }
        let watermarkCI = CIImage(cgImage: cgImage)
        
        let margin = scale * 0.03
        let posX = renderSize.width - size.width - margin
        let posY = margin
        
        return watermarkCI.transformed(by: CGAffineTransform(translationX: posX, y: posY))
    }
}
