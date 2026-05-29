import Foundation
import Combine

public final class AppLogger: ObservableObject {
    public static let shared = AppLogger()
    
    @Published public private(set) var logs: [String] = []
    
    private init() {
        log("App logger initialized")
    }
    
    public func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        print(line)
        
        DispatchQueue.main.async {
            self.logs.append(line)
            if self.logs.count > 1000 {
                self.logs.removeFirst()
            }
        }
    }
    
    public func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
            self.log("Logs cleared")
        }
    }
    
    public func exportString() -> String {
        return logs.joined(separator: "\n")
    }
}
