import UIKit
import BackgroundTasks
import AVFoundation

/// Manages background app refresh and camera session warming
@MainActor
final class BackgroundManager: NSObject, ObservableObject {
    static let shared = BackgroundManager()
    
    // MARK: - Constants
    private static let backgroundTaskIdentifier = "com.phushsia.dualcam.warm-camera"
    
    // MARK: - Published Properties
    @Published var isBackgroundRefreshEnabled: Bool = false
    @Published var lastBackgroundRefresh: Date?
    
    // MARK: - Private Properties
    private weak var captureManager: CaptureManager?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var sessionKeepAliveTimer: Timer?
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupBackgroundTasks()
        updateBackgroundRefreshStatus()
    }
    
    // MARK: - Public Methods
    func register(captureManager: CaptureManager) {
        self.captureManager = captureManager
        AppLogger.shared.log("BackgroundManager: Registered with CaptureManager")
    }
    
    func applicationDidEnterBackground() {
        AppLogger.shared.log("BackgroundManager: App entering background")
        startBackgroundTask()
        scheduleSessionKeepAlive()
    }
    
    func applicationWillEnterForeground() {
        AppLogger.shared.log("BackgroundManager: App entering foreground")
        endBackgroundTask()
        stopSessionKeepAlive()
    }
    
    func warmCameraSession() {
        guard isBackgroundRefreshEnabled else {
            AppLogger.shared.log("BackgroundManager: Background refresh not available")
            return
        }
        
        Task {
            await captureManager?.prepareSessionForQuickStart()
            lastBackgroundRefresh = Date()
            AppLogger.shared.log("BackgroundManager: Camera session warmed")
        }
    }
    
    // MARK: - Private Methods
    private func setupBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    private func updateBackgroundRefreshStatus() {
        isBackgroundRefreshEnabled = UIApplication.shared.backgroundRefreshStatus == .available
    }
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CameraSessionWarmup") { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    private func scheduleSessionKeepAlive() {
        guard isBackgroundRefreshEnabled else { return }
        
        // Keep session warm for up to 30 seconds in background
        sessionKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.warmCameraSession()
        }
        
        // Stop after 30 seconds to preserve battery
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.stopSessionKeepAlive()
        }
    }
    
    private func stopSessionKeepAlive() {
        sessionKeepAliveTimer?.invalidate()
        sessionKeepAliveTimer = nil
    }
    
    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.shared.log("BackgroundManager: Scheduled background refresh")
        } catch {
            AppLogger.shared.log("BackgroundManager: Failed to schedule background refresh: \(error)")
        }
    }
    
    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        AppLogger.shared.log("BackgroundManager: Handling background refresh")
        
        // Schedule next refresh
        scheduleBackgroundRefresh()
        
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        // Warm the camera session if needed
        Task {
            if await captureManager?.needsSessionWarmup() == true {
                await captureManager?.prepareSessionForQuickStart()
                lastBackgroundRefresh = Date()
            }
            task.setTaskCompleted(success: true)
        }
    }
}

// MARK: - CaptureManager Extension for Background Support
extension CaptureManager {
    func prepareSessionForQuickStart() async {
        guard !session.isRunning else { return }
        
        // Briefly start session to keep it warm
        await MainActor.run {
            session.startRunning()
        }
        
        // Stop after a moment to preserve battery
        try? await Task.sleep(for: .seconds(2))
        
        await MainActor.run {
            session.stopRunning()
        }
        
        AppLogger.shared.log("CaptureManager: Session warmed for quick start")
    }
    
    func needsSessionWarmup() async -> Bool {
        // Check if session needs warming (hasn't been used recently)
        return !session.isRunning
    }
}