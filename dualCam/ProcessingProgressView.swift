import SwiftUI

struct ProcessingProgressView: View {
    let progress: Double
    let statusMessage: String
    let isConfiguring: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            // Animated spinning indicator
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 4)
                    .frame(width: 64, height: 64)
                
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: progress)
                
                if isConfiguring {
                    Circle()
                        .stroke(Color.cyan, lineWidth: 2)
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(progress * 360))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: progress)
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            
            Text(statusMessage)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            
            // Show timing hint for processing operations
            if statusMessage.contains("Compositing") || statusMessage.contains("Rendering") || statusMessage.contains("Encoding") || statusMessage.contains("may take") {
                Text("This may take up to a minute")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
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
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal)
        }
    }
}

#Preview {
    ProcessingProgressView(
        progress: 0.65,
        statusMessage: "Merging video feeds... 65%",
        isConfiguring: false
    )
    .background(Color.black)
}