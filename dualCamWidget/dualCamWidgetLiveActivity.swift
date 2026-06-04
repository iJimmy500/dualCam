import ActivityKit
import WidgetKit
import SwiftUI

// Must be identical to VideoProcessingActivityAttributes in the main app.
// ActivityKit matches by struct name, so both definitions wire up to the same live activity.
struct VideoProcessingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double
        var statusMessage: String
        var videosInQueue: Int
        var isCompleted: Bool
    }
    var startTime: Date
}

// MARK: - Widget

struct dualCamWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VideoProcessingActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(state: context.state)
                }
            } compactLeading: {
                CompactLeadingView()
            } compactTrailing: {
                CompactTrailingView(progress: context.state.progress, isCompleted: context.state.isCompleted)
            } minimal: {
                MinimalView(progress: context.state.progress, isCompleted: context.state.isCompleted)
            }
            .keylineTint(.cyan)
        }
    }
}

// MARK: - Lock Screen / Banner

struct LockScreenActivityView: View {
    let state: VideoProcessingActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            // Header row
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.cyan)
                }

                Text("DualCam")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                if state.isCompleted {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Text("\(Int(state.progress * 100))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.cyan)
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: state.isCompleted
                                    ? [.green, .green.opacity(0.7)]
                                    : [.cyan, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * state.progress, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: state.progress)
                }
            }
            .frame(height: 6)

            // Status row
            HStack {
                Text(state.isCompleted ? "Video saved to Photos" : state.statusMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)

                Spacer()

                if state.videosInQueue > 0 && !state.isCompleted {
                    Text("\(state.videosInQueue) in queue")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Dynamic Island Expanded

struct ExpandedLeadingView: View {
    let state: VideoProcessingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("DualCam")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(state.isCompleted ? "Done" : "Saving")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.leading, 4)
    }
}

struct ExpandedTrailingView: View {
    let state: VideoProcessingActivityAttributes.ContentState

    var body: some View {
        if state.isCompleted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.green)
                .padding(.trailing, 4)
        } else {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 3)
                    .frame(width: 36, height: 36)
                Circle()
                    .trim(from: 0, to: state.progress)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(state.progress * 100))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.trailing, 4)
        }
    }
}

struct ExpandedBottomView: View {
    let state: VideoProcessingActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: state.isCompleted
                                    ? [.green, .green.opacity(0.7)]
                                    : [.cyan, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * state.progress, height: 4)
                }
            }
            .frame(height: 4)

            HStack {
                Text(state.isCompleted ? "Saved to Photos" : state.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer()
                if state.videosInQueue > 0 && !state.isCompleted {
                    Text("\(state.videosInQueue) queued")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
    }
}

// MARK: - Dynamic Island Compact

struct CompactLeadingView: View {
    var body: some View {
        Image(systemName: "camera.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.cyan)
            .padding(.leading, 4)
    }
}

struct CompactTrailingView: View {
    let progress: Double
    let isCompleted: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 2)
                        .frame(width: 16, height: 16)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 16, height: 16)
                        .rotationEffect(.degrees(-90))
                }
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .padding(.trailing, 4)
    }
}

// MARK: - Dynamic Island Minimal

struct MinimalView: View {
    let progress: Double
    let isCompleted: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: isCompleted ? 1.0 : progress)
                .stroke(isCompleted ? Color.green : Color.cyan,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(3)
    }
}

// MARK: - Previews

extension VideoProcessingActivityAttributes {
    fileprivate static var preview: VideoProcessingActivityAttributes {
        VideoProcessingActivityAttributes(startTime: Date())
    }
}

extension VideoProcessingActivityAttributes.ContentState {
    fileprivate static var encoding: VideoProcessingActivityAttributes.ContentState {
        .init(progress: 0.62, statusMessage: "Encoding final video", videosInQueue: 1, isCompleted: false)
    }
    fileprivate static var done: VideoProcessingActivityAttributes.ContentState {
        .init(progress: 1.0, statusMessage: "Video saved successfully!", videosInQueue: 0, isCompleted: true)
    }
}

#Preview("Lock Screen", as: .content, using: VideoProcessingActivityAttributes.preview) {
    dualCamWidgetLiveActivity()
} contentStates: {
    VideoProcessingActivityAttributes.ContentState.encoding
    VideoProcessingActivityAttributes.ContentState.done
}

#Preview("Dynamic Island Compact", as: .dynamicIsland(.compact), using: VideoProcessingActivityAttributes.preview) {
    dualCamWidgetLiveActivity()
} contentStates: {
    VideoProcessingActivityAttributes.ContentState.encoding
    VideoProcessingActivityAttributes.ContentState.done
}

#Preview("Dynamic Island Expanded", as: .dynamicIsland(.expanded), using: VideoProcessingActivityAttributes.preview) {
    dualCamWidgetLiveActivity()
} contentStates: {
    VideoProcessingActivityAttributes.ContentState.encoding
    VideoProcessingActivityAttributes.ContentState.done
}
