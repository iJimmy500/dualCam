import UIKit
import Foundation
import Combine

/// Monitors device system state and provides recommendations for camera performance
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    
    // MARK: - Published Properties
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var lowPowerModeEnabled: Bool = false
    @Published var backgroundAppRefreshStatus: UIBackgroundRefreshStatus = .available
    @Published var batteryLevel: Float = 1.0
    @Published var batteryState: UIDevice.BatteryState = .unknown
    
    // MARK: - Computed Properties
    var shouldReducePerformance: Bool {
        thermalState.isAtLeastSevere || lowPowerModeEnabled
    }
    
    var thermalWarningMessage: String? {
        switch thermalState {
        case .serious:
            return "Device is warm. Consider reducing video quality or taking a break."
        case .critical:
            return "Device is very hot. Recording may be automatically paused to prevent overheating."
        default:
            return nil
        }
    }
    
    var powerOptimizationMessage: String? {
        if lowPowerModeEnabled {
            return "Low Power Mode is on. Some features may be limited to preserve battery."
        }
        if batteryLevel < 0.15 {
            return "Battery is low (\(Int(batteryLevel * 100))%). Consider reducing video quality."
        }
        return nil
    }
    
    var recommendedCodec: RecordingCodec {
        if shouldReducePerformance {
            return .hevcSave  // Most power-efficient
        }
        return .hevcSafe  // Default efficient codec
    }
    
    var recommendedQuality: VideoQuality {
        if thermalState.isAtLeastSevere || (lowPowerModeEnabled && batteryLevel < 0.2) {
            return .low  // Reduce heat and power consumption
        }
        if shouldReducePerformance {
            return .medium
        }
        return .medium  // Default recommendation
    }
    
    // MARK: - Private Properties
    private var cancellables = Set<AnyCancellable>()
    private var thermalObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    private init() {
        setupMonitoring()
        updateInitialValues()
    }
    
    deinit {
        // Clean up observers directly since deinit can't call MainActor methods
        cancellables.removeAll()
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Public Methods
    func startMonitoring() {
        setupMonitoring()
    }
    
    func stopMonitoring() {
        cancellables.removeAll()
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
    }
    
    func checkBackgroundAppRefresh() -> Bool {
        backgroundAppRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        return backgroundAppRefreshStatus == .available
    }
    
    // MARK: - Private Methods
    private func setupMonitoring() {
        // Enable battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        // Monitor thermal state
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateThermalState()
        }
        
        // Monitor power state changes
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePowerState()
            }
            .store(in: &cancellables)
        
        // Monitor battery state
        NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateBatteryState()
            }
            .store(in: &cancellables)
        
        // Monitor battery level
        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateBatteryLevel()
            }
            .store(in: &cancellables)
        
        // Monitor background app refresh status changes
        NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateBackgroundRefreshStatus()
            }
            .store(in: &cancellables)
    }
    
    private func updateInitialValues() {
        updateThermalState()
        updatePowerState()
        updateBatteryState()
        updateBatteryLevel()
        updateBackgroundRefreshStatus()
    }
    
    private func updateThermalState() {
        let newState = ProcessInfo.processInfo.thermalState
        if newState != thermalState {
            AppLogger.shared.log("SystemMonitor: Thermal state changed to \(newState)")
            thermalState = newState
        }
    }
    
    private func updatePowerState() {
        let newLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if newLowPowerMode != lowPowerModeEnabled {
            AppLogger.shared.log("SystemMonitor: Low power mode \(newLowPowerMode ? "enabled" : "disabled")")
            lowPowerModeEnabled = newLowPowerMode
        }
    }
    
    private func updateBatteryState() {
        batteryState = UIDevice.current.batteryState
    }
    
    private func updateBatteryLevel() {
        batteryLevel = UIDevice.current.batteryLevel
    }
    
    private func updateBackgroundRefreshStatus() {
        backgroundAppRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    }
}

// MARK: - Extensions

extension ProcessInfo.ThermalState {
    var description: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    
    var systemImage: String {
        switch self {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "thermometer.high"
        @unknown default: return "thermometer"
        }
    }
    
    var color: UIColor {
        switch self {
        case .nominal: return .systemGreen
        case .fair: return .systemYellow
        case .serious: return .systemOrange
        case .critical: return .systemRed
        @unknown default: return .systemGray
        }
    }
    
    /// Returns true if the thermal state is serious or critical
    var isAtLeastSevere: Bool {
        switch self {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return false
        }
    }
}

extension UIBackgroundRefreshStatus {
    var description: String {
        switch self {
        case .available: return "Available"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
}