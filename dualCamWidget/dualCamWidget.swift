import WidgetKit
import SwiftUI

// MARK: - Lock Screen Widgets

struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: Date())
    }
    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> Void) {
        completion(LockScreenEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        // Static widget — no data to refresh, just re-fire once a day to stay alive
        let next = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        completion(Timeline(entries: [LockScreenEntry(date: Date())], policy: .after(next)))
    }
}

struct LockScreenEntry: TimelineEntry {
    let date: Date
}

// Circular lock screen widget — camera aperture icon
struct CircularLockScreenView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "camera.aperture")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// Rectangular lock screen widget — icon + label
struct RectangularLockScreenView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("DualCam")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Open camera")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
    }
}

struct DualCamCircularWidget: Widget {
    let kind = "com.personal.dualCam.lockscreen.circular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenProvider()) { _ in
            CircularLockScreenView()
                .widgetURL(URL(string: "dualcam://open"))
        }
        .configurationDisplayName("DualCam")
        .description("Open DualCam from your lock screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct DualCamRectangularWidget: Widget {
    let kind = "com.personal.dualCam.lockscreen.rectangular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenProvider()) { _ in
            RectangularLockScreenView()
                .widgetURL(URL(string: "dualcam://open"))
        }
        .configurationDisplayName("DualCam")
        .description("Open DualCam from your lock screen.")
        .supportedFamilies([.accessoryRectangular])
    }
}
