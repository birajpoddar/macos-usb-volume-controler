import Cocoa

final class MediaKeyMonitor {
    static let shared = MediaKeyMonitor()
    private var eventMonitor: Any?
    
    func start() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
        
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleKeyEvent(event)
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }
        let keyCode = ((event.data1 & 0xFFFF0000) >> 16)
        let keyFlags = (event.data1 & 0x0000FFFF)
        let isKeyDown = (((keyFlags & 0xFF00) >> 8)) == 0xA
        
        guard isKeyDown else { return }
        
        DispatchQueue.main.async {
            switch Int32(keyCode) {
            case NX_KEYTYPE_SOUND_UP:
                AudioLoopbackEngine.shared.adjustVolume(by: 0.0625)
            case NX_KEYTYPE_SOUND_DOWN:
                AudioLoopbackEngine.shared.adjustVolume(by: -0.0625)
            case NX_KEYTYPE_MUTE:
                AudioLoopbackEngine.shared.toggleMute()
            default:
                break
            }
        }
    }
    
    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
