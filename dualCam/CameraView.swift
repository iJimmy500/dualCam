import SwiftUI
import AVFoundation

struct CameraView: View {
    @EnvironmentObject var capture: CaptureManager
    @EnvironmentObject var settings: AppSettings
    @State private var captureMode: CaptureMode = .photo
    @State private var showPairPicker = false
    @State private var showSettings = false
    @State private var showQuickSettings = false
    @State private var pipDragging = CGSize.zero
    @State private var shutterPressed = false
    @State private var zoomGestureMagnification: CGFloat = 1.0
    @State private var lastZoomFactor: CGFloat = 1.0
    @State private var pipWidth: CGFloat = 108
    @State private var pipScaleGesture: CGFloat = 1.0
    @State private var videoModeReady = true
    @State private var previewItem: MediaItem? = nil
    @State private var countdown: Int? = nil
    @State private var countdownTask: Task<Void, Never>? = nil

    enum CaptureMode: String, CaseIterable { case photo = "PHOTO", video = "VIDEO" }

    private var mainLayer: AVCaptureVideoPreviewLayer {
        capture.isSwapped ? capture.secondaryPreviewLayer : capture.primaryPreviewLayer
    }
    private var pipLayer: AVCaptureVideoPreviewLayer {
        capture.isSwapped ? capture.primaryPreviewLayer : capture.secondaryPreviewLayer
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if capture.isSupported {
                cameraContent
            } else {
                unsupportedView
            }
        }
        .task { await capture.checkPermissionsAndSetup() }
        .alert("Camera Error", isPresented: .constant(capture.errorMessage != nil)) {
            Button("OK") { capture.errorMessage = nil }
        } message: {
            Text(capture.errorMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(capture)
                .environmentObject(settings)
        }
        .preferredColorScheme(.dark)
        .modifier(CaptureSettingsSyncModifier(capture: capture, settings: settings,
                                              pipWidth: pipWidth, previewItem: $previewItem))
        .fullScreenCover(item: $previewItem) { item in
            CapturePreviewModal(item: item) { previewItem = nil }
        }
    }

    // MARK: - Main content

    private var cameraContent: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                switch settings.layoutMode {
                case .pip:
                    mainPreview
                        .ignoresSafeArea()
                case .splitH:
                    splitHView(geo: geo)
                case .splitV:
                    splitVView(geo: geo)
                case .spotH:
                    spotlightView(geo: geo)
                }

                // Flash burst
                if capture.flashFired {
                    Color.white.opacity(0.9).ignoresSafeArea()
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.07), value: capture.flashFired)
                }

                if settings.layoutMode == .pip {
                    aspectRatioBars(in: geo)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: settings.aspectRatioRaw)
                }

                if settings.showGridOverlay && settings.layoutMode == .pip {
                    gridOverlay.transition(.opacity)
                }

                if settings.showDebugInfo { debugOverlay }

                if capture.isConfiguring || !capture.isSessionRunning || capture.isProcessingVideo {
                    loadingOverlay
                        .transition(.opacity.animation(.easeOut(duration: 0.3)))
                        .zIndex(10)
                }

                if settings.layoutMode == .pip && !capture.isConfiguring {
                    pipView(in: geo)
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: capture.isConfiguring)
                }

                if let pt = capture.focusPoint {
                    FocusIndicator()
                        .position(pt)
                        .transition(.scale(scale: 1.2).combined(with: .opacity))
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: capture.focusPoint)
                }

                if countdown != nil {
                    countdownOverlay
                        .transition(.opacity)
                }

                // Dismiss quick settings on background tap
                if showQuickSettings {
                    Color.clear.ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                                showQuickSettings = false
                            }
                        }
                        .zIndex(4)
                }

                // Quick settings panel — floats above shutter row, right-aligned
                if showQuickSettings {
                    QuickSettingsPanel()
                        .environmentObject(capture)
                        .environmentObject(settings)
                        .padding(.trailing, 16)
                        .padding(.bottom, geo.safeAreaInsets.bottom + 110)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.scale(scale: 0.88, anchor: .bottomTrailing).combined(with: .opacity))
                        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: showQuickSettings)
                        .zIndex(5)
                        .onTapGesture {} // absorb taps inside panel
                }

                // Saved to Photos banner
                if capture.showSavedBanner {
                    savedBanner
                        .padding(.top, geo.safeAreaInsets.top + 56)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: capture.showSavedBanner)
                        .zIndex(6)
                        .allowsHitTesting(false)
                }

                // Chrome
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar(geo: geo)
                }
                .padding(.top, geo.safeAreaInsets.top)
            }
        }
    }

    // Full-screen main preview with tap/zoom gestures
    private var mainPreview: some View {
        PreviewPlaceholder(layer: mainLayer)
            .onTapGesture(count: 2) {
                if settings.hapticFeedback { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                if settings.zoomResetOnSwap {
                    capture.setZoom(1.0); lastZoomFactor = 1.0
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { capture.swapCameras() }
            }
            .onTapGesture(count: 1) { location in
                capture.setFocus(at: location, in: mainLayer)
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard captureMode == .photo else { return }
                        let delta = value.magnification / zoomGestureMagnification
                        zoomGestureMagnification = value.magnification
                        capture.setZoom(lastZoomFactor * delta)
                    }
                    .onEnded { _ in
                        guard captureMode == .photo else { return }
                        lastZoomFactor = capture.zoom
                        zoomGestureMagnification = 1.0
                    }
            )
    }

    // MARK: - Split layout views

    private func splitHView(geo: GeometryProxy) -> some View {
        VStack(spacing: 2) {
            PreviewPlaceholder(layer: mainLayer)
                .frame(height: (geo.size.height - 2) / 2)
                .clipped()
                .onTapGesture(count: 2) {
                    if settings.hapticFeedback { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { capture.swapCameras() }
                }
            PreviewPlaceholder(layer: pipLayer)
                .frame(height: (geo.size.height - 2) / 2)
                .clipped()
        }
        .ignoresSafeArea()
    }

    private func splitVView(geo: GeometryProxy) -> some View {
        HStack(spacing: 2) {
            PreviewPlaceholder(layer: mainLayer)
                .frame(width: (geo.size.width - 2) / 2)
                .clipped()
                .onTapGesture(count: 2) {
                    if settings.hapticFeedback { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { capture.swapCameras() }
                }
            PreviewPlaceholder(layer: pipLayer)
                .frame(width: (geo.size.width - 2) / 2)
                .clipped()
        }
        .ignoresSafeArea()
    }

    private func spotlightView(geo: GeometryProxy) -> some View {
        VStack(spacing: 2) {
            PreviewPlaceholder(layer: mainLayer)
                .frame(height: geo.size.height * 0.65)
                .clipped()
                .onTapGesture(count: 2) {
                    if settings.hapticFeedback { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { capture.swapCameras() }
                }
            PreviewPlaceholder(layer: pipLayer)
                .frame(height: geo.size.height * 0.35 - 2)
                .clipped()
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar
    // Left slot: timer when recording | empty
    // Right slot: camera pair picker (text label so it doesn't read as a swap button)

    private var topBar: some View {
        HStack(alignment: .center, spacing: 0) {
            Button { showPairPicker = true } label: {
                Text(capture.currentPair.shortLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .tracking(0.8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.1), in: Capsule())
            }
            .confirmationDialog("Camera Pair", isPresented: $showPairPicker, titleVisibility: .visible) {
                ForEach(availablePairs) { pair in
                    Button(pair.rawValue) { capture.switchPair(pair) }
                }
                Button("Cancel", role: .cancel) {}
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private var availablePairs: [CameraPair] {
        CameraPair.allCases.filter { !$0.requiresTelephoto || AppSettings.hasTelephoto }
    }

    private var recordingTimer: some View {
        let remaining = CaptureManager.maxRecordingSeconds - capture.recordingSecondsElapsed
        let urgent = remaining <= 10
        return VStack(alignment: .center, spacing: 4) {
            Circle()
                .fill(urgent ? Color.red : Color.white)
                .frame(width: 8, height: 8)
                .opacity(urgent ? 1 : 0.85)
            Text(timeString(remaining))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(urgent ? .red : .white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.25), value: remaining)
        }
        .frame(width: 56, alignment: .center)
    }

    // MARK: - Bottom bar

    private func bottomBar(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if capture.supportsZoom {
                zoomControl
                    .padding(.bottom, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            modeSelector
                .padding(.bottom, 24)

            shutterRow
                .padding(.bottom, geo.safeAreaInsets.bottom + 20)
        }
        .padding(.horizontal, 24)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: captureMode)
    }

    // MARK: - Mode selector

    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        captureMode = mode
                    }
                    if mode == .video {
                        capture.setZoom(1.0)
                        lastZoomFactor = 1.0
                        zoomGestureMagnification = 1.0
                        videoModeReady = false
                        capture.prepareForRecording(highFrameRate: settings.highFrameRate)
                        Task {
                            // Writer startWriting() runs concurrently — 350 ms is enough headroom.
                            try? await Task.sleep(for: .milliseconds(350))
                            withAnimation(.easeOut(duration: 0.2)) { videoModeReady = true }
                        }
                    } else {
                        videoModeReady = true
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(mode.rawValue)
                            .font(.system(size: 13, weight: captureMode == mode ? .semibold : .regular))
                            .foregroundStyle(captureMode == mode ? .white : .white.opacity(0.4))
                            .tracking(1.2)

                        Circle()
                            .fill(.white)
                            .frame(width: 4, height: 4)
                            .opacity(captureMode == mode ? 1 : 0)
                            .scaleEffect(captureMode == mode ? 1 : 0.3)
                    }
                    .frame(width: 72)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: captureMode)
                }
            }
        }
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 0) {
                Group {
                    if capture.isRecording {
                        recordingTimer
                    } else {
                        settingsButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: capture.isRecording)

                shutterButton
                    .disabled(captureMode == .video && !videoModeReady)
                    .opacity(captureMode == .video && !videoModeReady ? 0.45 : 1)
                    .animation(.easeOut(duration: 0.2), value: videoModeReady)

                Group {
                    if captureMode == .photo {
                        quickSettingsButton
                    } else {
                        Color.clear.frame(width: 56, height: 56)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: captureMode)
            }

            if captureMode == .video && !videoModeReady {
                HStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.6))
                        .scaleEffect(0.7)
                    Text("Preparing…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: videoModeReady)
    }

    // MARK: - Settings button

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 56, height: 56)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Grid overlay

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                path.move(to: CGPoint(x: w / 3, y: 0)); path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: 2 * w / 3, y: 0)); path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                path.move(to: CGPoint(x: 0, y: h / 3)); path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: 2 * h / 3)); path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
            }
            .stroke(.white.opacity(0.22), lineWidth: 0.5)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Debug overlay

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Pair: \(capture.currentPair.rawValue)")
            Text("Zoom: \(String(format: "%.2f×", capture.zoom))")
            Text("Flash: \(capture.flashMode.displayName)")
            Text("Swapped: \(capture.isSwapped ? "Yes" : "No")")
            Text("Recording limit: \(CaptureManager.maxRecordingSeconds)s")
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.green)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.top, 64)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Quick settings button

    private var quickSettingsButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                showQuickSettings.toggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(showQuickSettings ? .white : .white.opacity(0.08))
                    .frame(width: 44, height: 44)
                Image(systemName: flashIconForQuickButton)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(showQuickSettings ? .black : flashColor)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 56, height: 56)
    }

    private var flashIconForQuickButton: String {
        switch capture.flashMode {
        case .on:   return "bolt.fill"
        case .auto: return "bolt.badge.a"
        default:    return "bolt.slash"
        }
    }

    // MARK: - Countdown overlay

    private var countdownOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture {
                    countdownTask?.cancel()
                    withAnimation { countdown = nil }
                }
            if let n = countdown {
                Text("\(n)")
                    .font(.system(size: 128, weight: .ultraLight, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 20)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.35, dampingFraction: 0.65), value: n)
            }
            VStack {
                Spacer()
                Text("Tap to cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 130)
            }
        }
    }

    // MARK: - Aspect ratio bars

    @ViewBuilder
    private func aspectRatioBars(in geo: GeometryProxy) -> some View {
        if let ratio = settings.aspectRatio.ratio {
            let w = geo.size.width, h = geo.size.height
            let targetH = w / ratio
            if targetH < h {
                let barH = (h - targetH) / 2
                VStack(spacing: 0) {
                    Color.black.opacity(0.55).frame(height: barH)
                    Spacer()
                    Color.black.opacity(0.55).frame(height: barH)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else {
                let targetW = h * ratio
                let barW = (w - targetW) / 2
                HStack(spacing: 0) {
                    Color.black.opacity(0.55).frame(width: barW)
                    Spacer()
                    Color.black.opacity(0.55).frame(width: barW)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - PiP

    private func pipView(in geo: GeometryProxy) -> some View {
        let pipW     = pipWidth * pipScaleGesture
        // Use 9:16 portrait ratio — matches how iPhones display camera previews in portrait mode.
        // resizeAspectFill handles any slight mismatch by cropping rather than squashing.
        let pipH     = pipW * (16.0 / 9.0)
        let baseX    = capture.pipPosition.x * geo.size.width
        let baseY    = capture.pipPosition.y * geo.size.height
        let dragging = pipDragging != .zero
        let locked   = false  // gestures always enabled; swap/drag/zoom allowed during recording

        // Break into a named sub-expression so Swift's type-checker doesn't time out
        let preview = PreviewPlaceholder(layer: pipLayer)
            .frame(width: pipW, height: pipH)
            .clipShape(settings.pipShape.shape)
            .overlay(pipBorder(dragging: dragging))
            .shadow(color: .black.opacity(0.55), radius: 16, x: 0, y: 6)
            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
            .scaleEffect(dragging ? 1.05 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.68), value: dragging)

        return preview
            .position(x: baseX + pipDragging.width, y: baseY + pipDragging.height)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !locked else { return }
                        pipDragging = value.translation
                    }
                    .onEnded { v in
                        guard !locked else { return }
                        let releasePt = CGPoint(x: baseX + v.translation.width,
                                                y: baseY + v.translation.height)
                        let snapped = snapToCorner(releasePt,
                                                   in: geo.frame(in: .local),
                                                   pipW: pipW, pipH: pipH)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                            capture.pipPosition = snapped
                            pipDragging = .zero
                        }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard !locked else { return }
                        pipScaleGesture = value.magnification
                    }
                    .onEnded { v in
                        guard !locked else { pipScaleGesture = 1.0; return }
                        let newW = (pipWidth * v.magnification).clamped(to: 80...240)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            pipWidth = newW
                            pipScaleGesture = 1.0
                        }
                        let newH = newW * (16.0 / 9.0)   // matches pipH = pipW * (16/9) above
                        let snapped = snapToCorner(CGPoint(x: baseX, y: baseY),
                                                   in: geo.frame(in: .local),
                                                   pipW: newW, pipH: newH)
                        capture.pipPosition = snapped
                    }
            )
    }

    @ViewBuilder
    private func pipBorder(dragging: Bool) -> some View {
        let sh = settings.pipShape.shape
        let c = settings.pipFrameColor.color
        switch settings.pipFrameStyle {
        case .none:
            EmptyView()
        case .solid:
            sh.stroke(c, lineWidth: dragging ? 2.5 : 2)
        case .thick:
            sh.stroke(c, lineWidth: dragging ? 7 : 5.5)
        case .double:
            sh.stroke(c.opacity(0.9), lineWidth: 2)
                .overlay(
                    sh.stroke(c.opacity(0.6), lineWidth: 1.5)
                        .scaleEffect(0.93)
                )
        case .dashed:
            sh.stroke(c, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
        case .glass:
            sh.stroke(
                LinearGradient(colors: [c.opacity(dragging ? 0.9 : 0.65),
                                        c.opacity(dragging ? 0.5 : 0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.5)
        case .glow:
            sh.stroke(c, lineWidth: 2)
                .shadow(color: c.opacity(0.65), radius: 8)
                .shadow(color: c.opacity(0.3),  radius: 16)
        case .neon:
            sh.stroke(c, lineWidth: 1.5)
                .shadow(color: c.opacity(0.9), radius: 4)
                .shadow(color: c.opacity(0.65), radius: 10)
                .shadow(color: c.opacity(0.35), radius: 22)
        }
    }

    private func snapToCorner(_ pt: CGPoint, in bounds: CGRect, pipW: CGFloat, pipH: CGFloat) -> CGPoint {
        let margin: CGFloat = 14
        let halfW = pipW / 2 + margin
        let halfH = pipH / 2 + margin
        let snappedX = pt.x < bounds.midX ? halfW : bounds.width - halfW
        let snappedY = pt.y < bounds.midY ? halfH : bounds.height - halfH
        return CGPoint(x: snappedX / bounds.width, y: snappedY / bounds.height)
    }

    // MARK: - Shutter button

    private var shutterButton: some View {
        Button { handleShutter() } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 2.5)
                    .frame(width: 76, height: 76)
                // Live mode badge
                if captureMode == .photo && settings.liveMode && capture.isLivePhotoAvailable {
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.9), in: Capsule())
                        .offset(y: -44)
                }

                if captureMode == .photo {
                    // Photo: white fill
                    Circle()
                        .fill(.white)
                        .frame(width: 64, height: 64)
                        .scaleEffect(shutterPressed ? 0.75 : 1)
                        .animation(.easeOut(duration: 0.09), value: shutterPressed)
                } else {
                    // Video: red roundrect morphs to stop square
                    RoundedRectangle(cornerRadius: capture.isRecording ? 7 : 32, style: .continuous)
                        .fill(.red)
                        .frame(
                            width:  capture.isRecording ? 30 : 58,
                            height: capture.isRecording ? 30 : 58
                        )
                        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: capture.isRecording)
                }
            }
        }
        .buttonStyle(ShutterButtonStyle())
    }

    private func handleShutter() {
        if settings.hapticFeedback { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        showQuickSettings = false

        switch captureMode {
        case .photo:
            // Tap during countdown → cancel
            if countdown != nil {
                countdownTask?.cancel()
                withAnimation { countdown = nil }
                return
            }

            if settings.delayedDualCapture {
                // Fire primary now, count down, then fire secondary
                flashShutterAnimation()
                capture.captureDelayedPrimary()
                let secs = max(settings.captureTimer, 3)
                startCountdown(secs) { self.capture.captureDelayedSecondary() }

            } else if settings.captureTimer > 0 {
                startCountdown(settings.captureTimer) { self.executePhotoCapture() }

            } else {
                executePhotoCapture()
            }

        case .video:
            if capture.isRecording { capture.stopRecording() } else { capture.startRecording(highFrameRate: settings.highFrameRate) }
        }
    }

    private func executePhotoCapture() {
        flashShutterAnimation()
        capture.capturePhoto()
    }

    private func flashShutterAnimation() {
        withAnimation(.easeIn(duration: 0.04)) { shutterPressed = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.easeOut(duration: 0.18)) { shutterPressed = false }
        }
    }

    private func startCountdown(_ seconds: Int, completion: @escaping () -> Void) {
        countdown = seconds
        countdownTask = Task { @MainActor in
            for remaining in stride(from: seconds - 1, through: 1, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { countdown = nil; return }
                if settings.hapticFeedback { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { countdown = remaining }
            }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { countdown = nil; return }
            withAnimation { countdown = nil }
            completion()
        }
    }

    // MARK: - Zoom

    private var zoomControl: some View {
        HStack(spacing: 10) {
            // Zoom level badge
            Text(String(format: capture.zoom < 10 ? "%.1f×" : "%.0f×", capture.zoom))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.yellow)
                .frame(width: 34, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.2), value: capture.zoom)

            Slider(
                value: Binding(get: { capture.zoom }, set: { capture.setZoom($0) }),
                in: 1...capture.maxZoomFactor
            )
            .tint(.white)
        }
    }

    // MARK: - Saved banner

    private var savedBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text("Saved to Photos")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: - Loading overlay

    private var loadingOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 24) {
                Spacer()
                
                VStack(spacing: 20) {
                    Image("noticedicon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                    
                    Text("dualCam")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .tracking(1.2)
                    
                    Text(capture.isProcessingVideo ? "Processing video…" : "Starting cameras…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .padding(.top, 2)
                }
                
                Spacer()
                
                if capture.isProcessingVideo {
                    VStack(spacing: 12) {
                        Button {
                            if settings.hapticFeedback { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                            capture.saveBothVideosSeparately()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "square.and.arrow.down.on.square")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Save Both Raw Feeds")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        }
                        .padding(.horizontal, 40)
                        
                        Button {
                            if settings.hapticFeedback { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                            capture.cancelProcessing()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        }
                        .padding(.horizontal, 40)
                    }
                    .padding(.bottom, 48)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Helpers

    private func timeString(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var flashColor: Color {
        switch capture.flashMode {
        case .on:   return .yellow
        case .auto: return .white
        default:    return .white.opacity(0.45)
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Multi-Camera Not Supported")
                .font(.system(size: 17, weight: .semibold))
            Text("Requires iPhone XS or newer.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Settings sync modifier (extracted so the body type-checks cleanly)

private struct CaptureSettingsSyncModifier: ViewModifier {
    let capture: CaptureManager
    let settings: AppSettings
    let pipWidth: CGFloat
    @Binding var previewItem: MediaItem?

    func body(content: Content) -> some View {
        content
            .onAppear { syncAll() }
            .onChange(of: settings.layoutMode) { _, v in capture.layoutMode = v }
            .onChange(of: settings.aspectRatio) { _, v in capture.aspectRatio = v }
            .onChange(of: settings.pipFrameStyle) { _, v in capture.pipFrameStyle = v }
            .onChange(of: settings.pipFrameColor) { _, v in capture.pipFrameColor = v }
            .onChange(of: settings.pipShape) { _, v in capture.pipShape = v }
            .onChange(of: settings.showWatermark) { _, v in capture.showWatermark = v }
            .onChange(of: settings.liveMode) { _, v in capture.isLiveModeActive = v }
            .onChange(of: settings.videoQuality) { _, v in capture.videoQuality = v }
            .onChange(of: settings.autoSaveRawFeeds) { _, v in capture.autoSaveRawFeeds = v }
            .onChange(of: settings.screenAlwaysOn) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
            .onChange(of: pipWidth)                  { _, w  in capture.pipWidth = w }
            .onChange(of: capture.capturedItems.count) { old, new in
                guard settings.showCapturePreview, new > old,
                      let item = capture.capturedItems.first else { return }
                previewItem = item
            }
    }

    private func syncAll() {
        capture.layoutMode       = settings.layoutMode
        capture.pipWidth         = pipWidth
        capture.aspectRatio      = settings.aspectRatio
        capture.pipFrameStyle    = settings.pipFrameStyle
        capture.pipFrameColor    = settings.pipFrameColor
        capture.pipShape         = settings.pipShape
        capture.showWatermark    = settings.showWatermark
        capture.isLiveModeActive = settings.liveMode
        capture.videoQuality     = settings.videoQuality
        capture.autoSaveRawFeeds = settings.autoSaveRawFeeds
        UIApplication.shared.isIdleTimerDisabled = settings.screenAlwaysOn
    }
}

// MARK: - Helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Focus square

struct FocusIndicator: View {
    @State private var scale: CGFloat = 1.2
    @State private var opacity: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: 68, height: 68)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) {
                    scale = 1; opacity = 1
                }
            }
    }
}

// MARK: - Preview bridge

struct PreviewPlaceholder: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    func makeUIView(context: Context) -> _PreviewUIView { _PreviewUIView() }
    func updateUIView(_ uiView: _PreviewUIView, context: Context) { uiView.setPreviewLayer(layer) }
}

class _PreviewUIView: UIView {
    private var currentLayer: AVCaptureVideoPreviewLayer?

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        guard currentLayer !== layer else { return }
        if let cur = currentLayer, cur.superlayer === self.layer { cur.removeFromSuperlayer() }
        currentLayer = layer
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.insertSublayer(layer, at: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let l = currentLayer, l.superlayer === self.layer { l.frame = bounds }
    }
}

struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
