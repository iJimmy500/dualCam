import SwiftUI
import UserNotifications
import BackgroundTasks

@main
struct dualCamApp: App {

    init() {
        setupAppearance()
        requestNotificationPermission()
        registerBackgroundTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
    
    // MARK: - App Configuration
    private func setupAppearance() {
        if let iconPath = Bundle.main.path(forResource: "noticedicon", ofType: "png"),
           UIImage(contentsOfFile: iconPath) != nil {
            print("App icon found: noticedicon.png")
        } else {
            print("Warning: App icon not found. Please add noticedicon.png to your project.")
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    
    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.phushsia.dualcam.warm-camera",
            using: nil
        ) { task in
            BackgroundManager.shared.warmCameraSession()
            task.setTaskCompleted(success: true)
        }
    }
}
