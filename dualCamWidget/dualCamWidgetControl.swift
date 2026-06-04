import AppIntents
import SwiftUI
import WidgetKit

// MARK: - App Intent

struct OpenDualCamIntent: AppIntent {
    static let title: LocalizedStringResource = "Open DualCam"
    static let description = IntentDescription("Opens DualCam ready to record.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

// MARK: - Control Widget

struct DualCamControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.personal.dualCam.openCamera",
            provider: DualCamControlProvider()
        ) { _ in
            ControlWidgetButton(action: OpenDualCamIntent()) {
                Label("DualCam", systemImage: "camera.aperture")
            }
            .tint(.cyan)
        }
        .displayName("DualCam")
        .description("Open DualCam ready to record.")
    }
}

// MARK: - Provider

struct DualCamControlProvider: ControlValueProvider {
    typealias Value = Bool

    var previewValue: Bool { true }

    func currentValue() async throws -> Bool { true }
}
