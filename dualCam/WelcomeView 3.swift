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
                
                ScrollView {
                    VStack(spacing: 32) {
                        // Header
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
                        .padding(.top, 40)
                        
                        // Features
                        VStack(spacing: 24) {
                            FeatureRow(
                                icon: "camera.fill",
                                title: "Dual Camera Recording",
                                description: "Record from front and back cameras simultaneously"
                            )
                            
                            FeatureRow(
                                icon: "rectangle.split.2x1",
                                title: "Multiple Layouts",
                                description: "Choose from PiP, split, or spotlight layouts"
                            )
                            
                        }
                        .padding(.horizontal, 20)
                        
                        // Important Note
                        VStack(spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                Text("Important")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("• Dual camera recording requires significant processing power")
                                Text("• Battery usage will be higher than normal camera usage")
                                Text("• Ensure adequate storage space for dual recordings")
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(20)
                        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.yellow.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                        
                        // Copyright Information
                        VStack(spacing: 12) {
                            Text("Copyright (c) 2026 james006")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                            
                            Link("https://github.com/iJimmy500/dualCam", 
                                 destination: URL(string: "https://github.com/iJimmy500/dualCam")!)
                                .font(.system(size: 14))
                                .foregroundStyle(.blue)
                            
                            Text("Licensed under the dualCam Community License v1.0")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Get Started") {
                        guard !isFinishing else { return }
                        isFinishing = true
                        
                        // Add haptic feedback
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        
                        // Use animation to provide visual feedback
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.hasSeenWelcome = true
                        }
                        
                        // Delay dismiss slightly to prevent double-tap issues
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.blue)
                    .disabled(isFinishing)
                    .opacity(isFinishing ? 0.6 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isFinishing)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 40, alignment: .center)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.leading)
            }
            
            Spacer()
        }
    }
}

#Preview {
    WelcomeView()
        .environmentObject(AppSettings())
}