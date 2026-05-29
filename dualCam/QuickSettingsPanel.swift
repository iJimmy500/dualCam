import AVFoundation
import SwiftUI

struct QuickSettingsPanel: View {
    @EnvironmentObject var capture: CaptureManager
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            quickRow(icon: "aspectratio", title: "Ratio") {
                ForEach(AspectRatio.allCases) { ar in
                    chip(ar.rawValue, selected: settings.aspectRatio == ar) {
                        settings.aspectRatio = ar
                    }
                }
            }

            divider

            quickRow(icon: "bolt", title: "Flash") {
                chip("Off",  selected: capture.flashMode == .off)  { capture.setFlashMode(.off) }
                chip("Auto", selected: capture.flashMode == .auto) { capture.setFlashMode(.auto) }
                chip("On",   selected: capture.flashMode == .on)   { capture.setFlashMode(.on) }
            }
            .disabled(!capture.isFlashAvailable)
            .opacity(capture.isFlashAvailable ? 1 : 0.35)

            divider

            quickRow(icon: "timer", title: "Timer") {
                chip("Off", selected: settings.captureTimer == 0)  { settings.captureTimer = 0 }
                chip("3s",  selected: settings.captureTimer == 3)  { settings.captureTimer = 3 }
                chip("10s", selected: settings.captureTimer == 10) { settings.captureTimer = 10 }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 256)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
    }

    // MARK: - Row builder

    private func quickRow<C: View>(
        icon: String, title: String,
        @ViewBuilder chips: () -> C
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 20)

            HStack(spacing: 5) { chips() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    // MARK: - Chip button

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .black : .white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selected ? Color.white : Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}
