import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Activity Attributes
struct VideoProcessingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double
        var statusMessage: String
        var videosInQueue: Int
        var isCompleted: Bool
    }
    
    var startTime: Date
}

// MARK: - Live Activity Manager
@MainActor
class LiveActivityManager: ObservableObject {
    private var currentActivity: Activity<VideoProcessingActivityAttributes>?
    
    func startVideoProcessingActivity(videosInQueue: Int = 1) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("Live Activities not enabled")
            return
        }
        
        let attributes = VideoProcessingActivityAttributes(startTime: Date())
        let initialState = VideoProcessingActivityAttributes.ContentState(
            progress: 0.0,
            statusMessage: "Starting video processing...",
            videosInQueue: videosInQueue,
            isCompleted: false
        )
        
        do {
            currentActivity = try Activity<VideoProcessingActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            print("✅ Live Activity started: \(String(describing: currentActivity?.id))")
        } catch {
            print("❌ Failed to start Live Activity: \(error)")
        }
    }
    
    func updateProgress(_ progress: Double, statusMessage: String, videosInQueue: Int = 0) {
        guard let activity = currentActivity else { return }
        
        let updatedState = VideoProcessingActivityAttributes.ContentState(
            progress: progress,
            statusMessage: statusMessage,
            videosInQueue: videosInQueue,
            isCompleted: false
        )
        
        Task {
            do {
                await activity.update(.init(state: updatedState, staleDate: nil))
            } catch {
                print("❌ Failed to update Live Activity: \(error)")
            }
        }
    }
    
    func completeActivity() {
        guard let activity = currentActivity else { return }
        
        let finalState = VideoProcessingActivityAttributes.ContentState(
            progress: 1.0,
            statusMessage: "Video processing completed!",
            videosInQueue: 0,
            isCompleted: true
        )
        
        Task {
            do {
                await activity.end(.init(state: finalState, staleDate: Date().addingTimeInterval(5)), dismissalPolicy: .after(.now.addingTimeInterval(3)))
                currentActivity = nil
                print("✅ Live Activity completed")
            } catch {
                print("❌ Failed to complete Live Activity: \(error)")
            }
        }
    }
    
    func cancelActivity() {
        guard let activity = currentActivity else { return }
        
        Task {
            do {
                await activity.end(nil, dismissalPolicy: .immediate)
                currentActivity = nil
                print("✅ Live Activity cancelled")
            } catch {
                print("❌ Failed to cancel Live Activity: \(error)")
            }
        }
    }
}

// MARK: - Live Activity Views
// Note: These views should be used in a Widget Extension target with ActivityConfiguration.
// In the Widget Extension, you would use them like this:
//
// struct VideoProcessingActivityWidget: Widget {
//     var body: some WidgetConfiguration {
//         ActivityConfiguration(for: VideoProcessingActivityAttributes.self) { context in
//             VideoProcessingActivityView(state: context.state, context: context.attributes)
//         } dynamicIsland: { context in
//             DynamicIsland {
//                 // Expanded view
//             } compactLeading: {
//                 // Compact leading view
//             } compactTrailing: {
//                 VideoProcessingActivityCompactView(state: context.state, context: context.attributes)
//             } minimal: {
//                 // Minimal view
//             }
//         }
//     }
// }

struct VideoProcessingActivityView: View {
    let state: VideoProcessingActivityAttributes.ContentState
    let context: VideoProcessingActivityAttributes
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "video.and.waveform")
                    .foregroundColor(.cyan)
                
                Text("DualCam")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if !state.isCompleted {
                    Text("\(Int(state.progress * 100))%")
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            
            if state.isCompleted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Video saved to Photos")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(state.statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    
                    ProgressView(value: state.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .cyan))
                    
                    if state.videosInQueue > 0 {
                        Text("\(state.videosInQueue) video\(state.videosInQueue == 1 ? "" : "s") in queue")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }
}

// For Dynamic Island compact view
struct VideoProcessingActivityCompactView: View {
    let state: VideoProcessingActivityAttributes.ContentState
    let context: VideoProcessingActivityAttributes
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.and.waveform")
                .foregroundColor(.cyan)
                .font(.system(size: 16))
            
            if state.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
            } else {
                ProgressView(value: state.progress)
                    .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                    .scaleEffect(0.8)
                
                Text("\(Int(state.progress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
        }
    }
}