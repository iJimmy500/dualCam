import SwiftUI

struct ProcessingProgressView: View {
    let progress: Double      // real progress from exporter (0–1)
    let statusMessage: String
    let isConfiguring: Bool

    @State private var displayPct: Int = 0
    @State private var ringFill: Double = 0
    @State private var spinAngle: Double = 0
    @State private var fakeTask: Task<Void, Never>?

    // Status label driven by fake progress so it feels responsive
    private var phaseLabel: String {
        switch displayPct {
        case 0..<20:  return "Compositing cameras…"
        case 20..<45: return "Rendering video layers…"
        case 45..<75: return "Encoding final video…"
        case 75..<95: return "Finalizing export…"
        default:      return "Saving to Photos…"
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 4)
                    .frame(width: 72, height: 72)

                // Filled progress arc
                Circle()
                    .trim(from: 0, to: ringFill)
                    .stroke(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: ringFill)

                // Continuously spinning tick mark — gives "active" feel
                Circle()
                    .trim(from: 0.0, to: 0.08)
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(spinAngle))

                if isConfiguring {
                    ProgressView()
                        .tint(.white.opacity(0.8))
                        .scaleEffect(0.9)
                } else {
                    Text("\(displayPct)%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: false))
                        .animation(.spring(response: 0.25), value: displayPct)
                }
            }

            VStack(spacing: 6) {
                Text(isConfiguring ? "Starting cameras…" : phaseLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: phaseLabel)

                BouncingDots()
            }
        }
        .padding(.horizontal, 40)
        .onAppear {
            startSpin()
            if !isConfiguring { startFakeProgress() }
        }
        .onDisappear {
            fakeTask?.cancel()
        }
        .onChange(of: progress) { _, p in
            if p >= 1.0 { finishProgress() }
        }
    }

    // Drives the percentage counter and ring fill, faking smooth progress
    private func startFakeProgress() {
        fakeTask = Task { @MainActor in
            // Ease through 0 → 88% over ~22 seconds in variable-speed steps
            // Faster at start (feels responsive), slower near end (feels realistic)
            let steps: [(to: Int, msDelay: Int)] = [
                // Quick burst to 30% (feels instant pickup)
                (5,  80), (10, 90), (15, 100), (20, 110), (25, 120), (30, 140),
                // Steady climb to 65%
                (35, 180), (40, 200), (45, 220), (50, 240), (55, 260),
                (60, 280), (65, 300),
                // Slow approach to 88% (makes 100% feel like a real jump)
                (70, 380), (75, 420), (80, 480), (84, 560), (88, 700)
            ]
            for step in steps {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(step.msDelay))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    displayPct = step.to
                    ringFill   = Double(step.to) / 100.0
                }
            }
            // Hold at 88% until real completion signals us via onChange(of: progress)
        }
    }

    private func finishProgress() {
        fakeTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
            displayPct = 100
            ringFill   = 1.0
        }
    }

    private func startSpin() {
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            spinAngle = 360
        }
    }
}

// Three dots that bounce in sequence
struct BouncingDots: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.45))
                    .frame(width: 5, height: 5)
                    .offset(y: phase == i ? -4 : 0)
                    .animation(
                        .easeInOut(duration: 0.35)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .onAppear {
            phase = 0
            // Cycle the "active" dot every 0.45s
            Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
                Task { @MainActor in
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

// Queue view for background processing
struct ProcessingQueueView: View {
    @ObservedObject var captureManager: CaptureManager

    var body: some View {
        if !captureManager.processingQueue.isEmpty || captureManager.isProcessingVideo {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "video.and.waveform")
                        .foregroundColor(.cyan)
                    Text("Processing Queue")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button("Clear All") {
                        captureManager.clearProcessingQueue()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }

                if captureManager.isProcessingVideo {
                    HStack {
                        ProgressView(value: captureManager.processingProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .cyan))
                        Text("\(Int(captureManager.processingProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.white)
                            .monospacedDigit()
                    }
                    Text(captureManager.processingStatusMessage)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                if !captureManager.processingQueue.isEmpty {
                    Text("\(captureManager.processingQueue.count) video\(captureManager.processingQueue.count == 1 ? "" : "s") in queue")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            .padding(.horizontal)
        }
    }
}

#Preview {
    ProcessingProgressView(progress: 0.0, statusMessage: "", isConfiguring: false)
        .background(Color.black)
}
