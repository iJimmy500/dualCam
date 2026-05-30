import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isFinishing = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.08), Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 40) {
                    Spacer()
                    headerSection
                    featuresSection
                    Spacer()
                    footerSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Get Started") {
                        guard !isFinishing else { return }
                        isFinishing = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.hasSeenWelcome = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(isFinishing)
                    .opacity(isFinishing ? 0.6 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isFinishing)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 20) {
            if let appIcon = UIImage(named: "noticedicon") {
                Image(uiImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "camera.badge.ellipsis")
                            .font(.system(size: 48))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            }

            Text("Welcome to dualCam")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)

            Text("Capture life from multiple perspectives")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(spacing: 14) {
            featureRow(icon: "camera.badge.ellipsis", text: "Record from multiple cameras simultaneously")
            featureRow(icon: "rectangle.split.2x1",   text: "Choose from PiP, split, or spotlight layouts")
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 6) {
            Text("Copyright © 2026 iJimmy500")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            Link("github.com/iJimmy500/dualCam",
                 destination: URL(string: "https://github.com/iJimmy500/dualCam")!)
                .font(.system(size: 13))
                .foregroundStyle(.blue.opacity(0.9))

            Text("dualCam Community License v1.0")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

#Preview {
    WelcomeView()
        .environmentObject(AppSettings())
}
