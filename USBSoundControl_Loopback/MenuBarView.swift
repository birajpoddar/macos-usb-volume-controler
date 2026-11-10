import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var engine = AudioLoopbackEngine.shared
    @State private var startOnLogin: Bool = (SMAppService.mainApp.status == .enabled)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header with Device Info
            HStack {
                Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                    .foregroundColor(engine.isMuted ? .red : .accentColor)
                    .font(.title2)
                
                VStack(alignment: .leading) {
                    Text("USBVolumeController")
                        .font(.headline)
                    Text(engine.statusMessage)
                        .font(.caption2)
                        .foregroundColor(engine.isRunning ? .green : .secondary)
                }
                
                Spacer()
                
                Button(engine.isMuted ? "Unmute" : "Mute") {
                    engine.toggleMute()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            
            // Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Volume")
                        .font(.subheadline)
                    Spacer()
                    Text(engine.isMuted ? "Muted" : "\(Int(engine.volume * 100))%")
                        .font(.subheadline)
                        .bold()
                }
                Slider(value: $engine.volume, in: 0.0...1.0)
                    .disabled(engine.isMuted)
            }
            
            Divider()
            
            // Target DAC selection
            VStack(alignment: .leading, spacing: 6) {
                Text("Target Output Device (DAC)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("", selection: $engine.selectedOutputID) {
                    ForEach(engine.availableOutputs) { item in
                        Text(item.name).tag(Optional(item.id))
                    }
                }
                .pickerStyle(.menu)
            }
            
            Divider()
            
            // Start on Login Toggle
            Toggle("Start on Login", isOn: $startOnLogin)
                .font(.subheadline)
                .onChange(of: startOnLogin) { _, newValue in
                    do {
                        if newValue {
                            if SMAppService.mainApp.status != .enabled {
                                try SMAppService.mainApp.register()
                            }
                        } else {
                            if SMAppService.mainApp.status == .enabled {
                                try SMAppService.mainApp.unregister()
                            }
                        }
                    } catch {
                        print("Failed to update SMAppService: \(error.localizedDescription)")
                    }
                }
            
            Divider()
            
            // Footer
            HStack {
                Text("Hardware keys: F11 / F12")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 290)
    }
}
