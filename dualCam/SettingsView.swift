import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var capture: CaptureManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private let isPro = AppSettings.hasTelephoto

    @State private var showingHighQualityWarning = false

    var body: some View {
        NavigationStack {
            Form {
                cameraPairSection
                cameraSection
                captureSection
                generalSection
                experimentalSection
                proSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(LiquidGlassBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .preferredColorScheme(.dark)
            .alert("High Quality Warning", isPresented: $showingHighQualityWarning) {
                Button("Got it", role: .cancel) { }
            } message: {
                Text("High Quality exports require significantly more processing power and time. They may fail on older devices or with long recordings.")
            }
        }
    }

    // MARK: - Camera Pair

    private var cameraPairSection: some View {
        Section {
            ForEach(availablePairs) { pair in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    capture.switchPair(pair)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: pair.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(capture.currentPair == pair ? .blue : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pair.rawValue).foregroundStyle(.primary)
                            Text(pairDescription(pair))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if capture.currentPair == pair {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        } header: { Text("Camera Pair") }
    }

    private var availablePairs: [CameraPair] {
        CameraPair.allCases.filter { !$0.requiresTelephoto || isPro }
    }

    private func pairDescription(_ pair: CameraPair) -> String {
        switch pair {
        case .frontAndBack:          return "Classic dual — selfie + rear"
        case .wideAndUltrawide:      return "1× + 0.5× rear perspective"
        case .ultraAndFront:         return "Ultra-wide rear + selfie"
        case .wideAndTelephoto:      return "1× + zoom — great for subjects"
        case .telephotoAndFront:     return "Zoomed rear + selfie"
        case .ultrawideAndTelephoto: return "0.5× vs 3×+ — max contrast"
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        Section("Camera") {
            layoutModeRows
            pipShapeRows
            frameStyleRows
            frameColorRow
            Picker("Flash", selection: Binding(get: { capture.flashMode },
                                               set: { capture.setFlashMode($0) })) {
                Label("Off",  systemImage: "bolt.slash").tag(AVCaptureDevice.FlashMode.off)
                Label("Auto", systemImage: "bolt.badge.a").tag(AVCaptureDevice.FlashMode.auto)
                Label("On",   systemImage: "bolt.fill").tag(AVCaptureDevice.FlashMode.on)
            }
            .disabled(!capture.isFlashAvailable)
            settingsRow("Grid Overlay", icon: "grid", note: "Rule-of-thirds guide") {
                Toggle("", isOn: $settings.showGridOverlay).labelsHidden()
            }
        }
    }

    private var layoutModeRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture Layout").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(LayoutMode.allCases) { layoutModeCell($0) }
            }
            .padding(.bottom, 2)
        }
    }

    private func layoutModeCell(_ mode: LayoutMode) -> some View {
        let active = settings.layoutMode == mode
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            settings.layoutMode = mode
        } label: {
            VStack(spacing: 5) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(active ? Color.blue : Color.secondary)
                Text(mode.shortLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? Color.blue.opacity(0.15) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(active ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var pipShapeRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PiP Window Shape").font(.subheadline).foregroundStyle(.secondary).padding(.top, 2)
            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(PipShape.allCases) { shapeCell($0) }
            }
            .padding(.bottom, 2)
        }
        .opacity(settings.layoutMode == .pip ? 1 : 0.3)
        .animation(.easeInOut(duration: 0.18), value: settings.layoutMode == .pip)
    }

    private func shapeCell(_ shape: PipShape) -> some View {
        let active = settings.pipShape == shape
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            settings.pipShape = shape
        } label: {
            VStack(spacing: 4) {
                Image(systemName: shape.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(active ? Color.blue : Color.secondary)
                Text(shape.rawValue)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? Color.blue.opacity(0.15) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(active ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var frameStyleRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PiP Frame Style").font(.subheadline).foregroundStyle(.secondary).padding(.top, 2)
            let cols = [GridItem(.flexible()), GridItem(.flexible()),
                        GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(PipFrameStyle.allCases) { frameStyleCell($0) }
            }
            .padding(.bottom, 2)
        }
    }

    private func frameStyleCell(_ style: PipFrameStyle) -> some View {
        let active = settings.pipFrameStyle == style
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            settings.pipFrameStyle = style
        } label: {
            VStack(spacing: 4) {
                Image(systemName: style.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(active ? Color.blue : Color.secondary)
                Text(style.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? Color.blue.opacity(0.15) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(active ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var frameColorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Frame Color").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(PipFrameColor.allCases) { fc in
                    frameColorSwatch(fc)
                }
            }
            .padding(.bottom, 2)
        }
        .opacity(settings.pipFrameStyle == .none ? 0.3 : 1)
        .animation(.easeInOut(duration: 0.18), value: settings.pipFrameStyle == .none)
    }

    private func frameColorSwatch(_ fc: PipFrameColor) -> some View {
        let active = settings.pipFrameColor == fc
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            settings.pipFrameColor = fc
        } label: {
            ZStack {
                Circle()
                    .fill(fc.swatchColor)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                if active {
                    Circle()
                        .stroke(Color.white, lineWidth: 2.5)
                        .frame(width: 34, height: 34)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section("Capture") {
            settingsRow("Video Quality", icon: "film", note: "Export resolution") {
                Picker("", selection: $settings.videoQuality) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.rawValue).tag(q)
                    }
                }
                .onChange(of: settings.videoQuality) { newValue in
                    if newValue == .high {
                        showingHighQualityWarning = true
                    }
                }
            }
            settingsRow("Preview After Capture", icon: "photo.circle", note: "Review & share immediately") {
                Toggle("", isOn: $settings.showCapturePreview).labelsHidden()
            }
            settingsRow("Live Mode", icon: "livephoto",
                        note: capture.isLivePhotoAvailable
                              ? "Saves motion clip + dual composite"
                              : "Not supported on this camera pair") {
                Toggle("", isOn: $settings.liveMode)
                    .labelsHidden()
                    .disabled(!capture.isLivePhotoAvailable)
            }
            settingsRow("Capture Sound", icon: "speaker.wave.1", note: "Plays shutter sound") {
                Toggle("", isOn: $settings.soundOnCapture).labelsHidden()
            }
            settingsRow("Auto-Save Raw Feeds", icon: "square.and.arrow.down.on.square", note: "Saves both unedited camera feeds alongside the composite") {
                Toggle("", isOn: $settings.autoSaveRawFeeds).labelsHidden()
            }
            settingsRow("Branding Watermark", icon: "tag", note: "Adds logo watermark in corner") {
                Toggle("", isOn: $settings.showWatermark).labelsHidden()
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            settingsRow("Haptic Feedback", icon: "hand.tap", note: "Vibrate on shutter & countdown") {
                Toggle("", isOn: $settings.hapticFeedback).labelsHidden()
            }
            settingsRow("Keep Screen On", icon: "sun.max", note: "Prevents sleep while camera is open") {
                Toggle("", isOn: $settings.screenAlwaysOn).labelsHidden()
            }
            settingsRow("Reset Zoom on Swap", icon: "1.magnifyingglass", note: "Returns to 1× when double-tapping to swap") {
                Toggle("", isOn: $settings.zoomResetOnSwap).labelsHidden()
            }
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Saves to Photos")
                        Text("Always on").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "photo.on.rectangle")
                }
                Spacer()
                Text("Always").foregroundStyle(.secondary).font(.subheadline)
            }
        }
    }

    // MARK: - Experimental

    private var experimentalSection: some View {
        Section {
            settingsRow("Extended Recording", icon: "clock.arrow.circlepath", note: "Up to 10 min") {
                Toggle("", isOn: $settings.extendedRecording).labelsHidden()
            }
            settingsRow("Mirror Front Camera", icon: "camera.metering.center.weighted.average", note: "Flips front camera preview") {
                Toggle("", isOn: $settings.mirrorFrontCamera).labelsHidden()
            }
            settingsRow("Delayed Dual Capture", icon: "camera.badge.clock", note: "Primary fires instantly, secondary after countdown") {
                Toggle("", isOn: $settings.delayedDualCapture).labelsHidden()
            }
            settingsRow("Volume Button Shutter", icon: "speaker.wave.2", note: "Use volume buttons to shoot") {
                Toggle("", isOn: $settings.volumeShutter).labelsHidden()
            }
            settingsRow("Macro Mode", icon: "camera.macro", note: "Ultra-close focus on ultrawide") {
                Toggle("", isOn: $settings.macroMode).labelsHidden()
            }
            settingsRow("Debug Overlay", icon: "info.bubble", note: "Shows live camera stats") {
                Toggle("", isOn: $settings.showDebugInfo).labelsHidden()
            }
        } header: {
            HStack(spacing: 6) {
                Text("Experimental")
                betaBadge
            }
        }
    }

    // MARK: - Pro

    @ViewBuilder
    private var proSection: some View {
        Section {
            if isPro {
                settingsRow("High Frame Rate Video", icon: "film.stack", note: "60 fps recording") {
                    Toggle("", isOn: $settings.highFrameRate).labelsHidden()
                }
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Telephoto Pairs")
                            Text("Wide+Tele, Tele+Front, Ultra+Tele").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "camera.filters") }
                    Spacer()
                    Text("Available").foregroundStyle(.green).font(.subheadline)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pro features unavailable").font(.subheadline)
                        Text("Requires a telephoto camera (Pro Level iPhone).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack(spacing: 6) {
                Text("Pro Features")
                if isPro {
                    Text("UNLOCKED")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    // MARK: - Helpers

    private func settingsRow<C: View>(
        _ title: String, icon: String, note: String,
        @ViewBuilder control: () -> C
    ) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: icon) }
            Spacer()
            control()
        }
    }

    private var betaBadge: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
    }

    // MARK: - About & Credits
    
    private var aboutSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(alignment: .center, spacing: 8) {
                    if let appIcon = UIImage(named: "noticedicon") {
                        Image(uiImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                            .cornerRadius(13)
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    } else {
                        // Safe fallback in case asset catalog is loading
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 60, height: 60)
                            .overlay(
                                Image(systemName: "camera.badge.ellipsis")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                    
                    VStack(spacing: 2) {
                        Text("dualCam")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                        
                        Text("Version 1.0 (1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Link(destination: URL(string: "https://phushsia.com")!) {
                        if let logo = UIImage(named: "noticedicon") {
                            HStack(spacing: 8) {
                                Image(uiImage: logo)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)
                                    .cornerRadius(4)
                                    .shadow(color: .black.opacity(0.15), radius: 1.5, x: 0, y: 1)
                                
                                Text("by Phushsia")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.blue)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        } else {
                            Text("by Phushsia")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }
}

// MARK: - iOS 26 Liquid Glass Background

struct LiquidGlassBackground: View {
    var body: some View {
        if #available(iOS 18.0, *) {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let speed: Double = 0.4
                let t = Float(time * speed)
                
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], [
                            0.5 + 0.15 * sin(t * 1.0),
                            0.5 + 0.15 * cos(t * 0.7)
                        ], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        .black, Color(red: 0.04, green: 0.02, blue: 0.10), Color(red: 0.01, green: 0.04, blue: 0.08),
                        .black, Color(red: 0.06, green: 0.01, blue: 0.12), Color(red: 0.00, green: 0.03, blue: 0.08),
                        Color(red: 0.08, green: 0.01, blue: 0.14), .black, .black
                    ]
                )
                .ignoresSafeArea()
            }
        } else {
            LinearGradient(
                colors: [Color.black, Color(red: 0.06, green: 0.03, blue: 0.12), Color.black],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
}
