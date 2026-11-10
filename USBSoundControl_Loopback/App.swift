import SwiftUI

@main
struct USBSoundControlApp: App {
    init() {
        MediaKeyMonitor.shared.start()
        // Allow macOS to finish audio subsystem initialization before starting the engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            AudioLoopbackEngine.shared.start()
        }
    }
    
    var body: some Scene {
        MenuBarExtra("USB Sound Control", systemImage: "hifispeaker.2.fill") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}
