import SwiftUI

struct ContentView: View {
    @StateObject private var capture  = CaptureManager()
    @StateObject private var settings = AppSettings()

    var body: some View {
        CameraView()
            .environmentObject(capture)
            .environmentObject(settings)
    }
}
