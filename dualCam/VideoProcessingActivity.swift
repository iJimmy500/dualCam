import ActivityKit
import SwiftUI

// MARK: - Activity Attributes
// Shared definition — the widget extension has an identical copy.
// ActivityKit matches by struct name, so both targets wire up to the same live activity.
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Don't stack activities — end any existing one first
        if let existing = currentActivity {
            Task { await existing.end(nil, dismissalPolicy: .immediate) }
            currentActivity = nil
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
            await activity.update(.init(state: updatedState, staleDate: nil))
        }
    }

    func completeActivity() {
        guard let activity = currentActivity else { return }
        let finalState = VideoProcessingActivityAttributes.ContentState(
            progress: 1.0,
            statusMessage: "Video saved successfully!",
            videosInQueue: 0,
            isCompleted: true
        )
        Task {
            await activity.end(
                .init(state: finalState, staleDate: Date().addingTimeInterval(5)),
                dismissalPolicy: .after(.now.addingTimeInterval(3))
            )
            currentActivity = nil
        }
    }

    func cancelActivity() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
}
