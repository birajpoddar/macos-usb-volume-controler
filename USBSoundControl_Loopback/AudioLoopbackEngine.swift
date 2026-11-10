import Foundation
import CoreAudio
import AudioToolbox
import Combine

final class AudioLoopbackEngine: ObservableObject {
    static let shared = AudioLoopbackEngine()
    
    private let volumeKey = "SavedOutputVolume"
    private let muteKey = "SavedMuteState"
    private let deviceKey = "SavedTargetDeviceUID"
    
    private let transitionQueue = DispatchQueue(label: "com.usbsoundcontrol.transitionQueue", qos: .userInitiated)
    
    private var atomicVolumeBits: UInt32 = (0.8 as Float).bitPattern
    private var atomicMuteState: UInt32 = 0
    
    // Guard against echo loops when syncing CoreAudio <-> SwiftUI slider
    private var isUpdatingFromSystem: Bool = false
    
    @Published var volume: Float = 0.8 {
        didSet {
            let clamped = max(0.0, min(1.0, volume))
            if clamped != volume {
                volume = clamped
                return
            }
            OSAtomicCompareAndSwap32Barrier(Int32(bitPattern: atomicVolumeBits),
                                           Int32(bitPattern: clamped.bitPattern),
                                           UnsafeMutablePointer<Int32>(bitPattern: UInt(bitPattern: UnsafeMutablePointer(&atomicVolumeBits))))
            UserDefaults.standard.set(clamped, forKey: volumeKey)
            
            // Push volume change to BlackHole so native macOS HUD stays in sync
            if !isUpdatingFromSystem, let bhID = inputDeviceID {
                setSystemVolume(deviceID: bhID, volume: clamped)
            }
        }
    }
    
    @Published var isMuted: Bool = false {
        didSet {
            let stateVal: UInt32 = isMuted ? 1 : 0
            OSAtomicCompareAndSwap32Barrier(Int32(bitPattern: atomicMuteState),
                                           Int32(stateVal),
                                           UnsafeMutablePointer<Int32>(bitPattern: UInt(bitPattern: UnsafeMutablePointer(&atomicMuteState))))
            UserDefaults.standard.set(isMuted, forKey: muteKey)
            
            if !isUpdatingFromSystem, let bhID = inputDeviceID {
                setSystemMute(deviceID: bhID, isMuted: isMuted)
            }
        }
    }
    
    @Published var availableOutputs: [AudioDeviceItem] = []
    @Published var selectedOutputID: AudioDeviceID? {
        didSet {
            if oldValue != selectedOutputID {
                if let newID = selectedOutputID, let uid = AudioDeviceHelper.getDeviceUID(deviceID: newID) {
                    UserDefaults.standard.set(uid, forKey: deviceKey)
                }
                restartEngine()
            }
        }
    }
    
    @Published var isRunning: Bool = false
    @Published var statusMessage: String = "Initializing..."
    
    private var inputDeviceID: AudioDeviceID?
    private var activeOutputDeviceID: AudioDeviceID?
    private var inputIOProcID: AudioDeviceIOProcID?
    private var outputIOProcID: AudioDeviceIOProcID?
    
    // CoreAudio Property Listener references
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    
    private let ringBufferSize: Int = 65536
    private let ringBufferMask: Int = 65535
    private var ringBuffer: UnsafeMutablePointer<Float>
    
    private var writeSampleIndex: Int64 = 0
    private var readSampleIndex: Int64 = 0
    
    var effectiveGain: Float {
        let isMutedNow = (atomicMuteState != 0)
        guard !isMutedNow else { return 0.0 }
        let currentVol = Float(bitPattern: atomicVolumeBits)
        return pow(currentVol, 3.0)
    }
    
    init() {
        self.ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: ringBufferSize)
        self.ringBuffer.initialize(repeating: 0.0, count: ringBufferSize)
        
        let savedVol = UserDefaults.standard.object(forKey: volumeKey) as? Float ?? 0.8
        let savedMute = UserDefaults.standard.bool(forKey: muteKey)
        
        self.volume = savedVol
        self.isMuted = savedMute
        self.atomicVolumeBits = savedVol.bitPattern
        self.atomicMuteState = savedMute ? 1 : 0
        
        refreshDevices()
    }
    
    deinit {
        stop()
        removeSystemVolumeListeners()
        ringBuffer.deallocate()
    }
    
    func refreshDevices() {
        let devices = AudioDeviceHelper.getDevices().filter {
            !$0.name.localizedCaseInsensitiveContains("BlackHole")
        }
        
        let savedUID = UserDefaults.standard.string(forKey: deviceKey)
        let resolvedID: AudioDeviceID?
        
        if let uid = savedUID,
           let savedID = AudioDeviceHelper.getDeviceID(forUID: uid),
           devices.contains(where: { $0.id == savedID }) {
            resolvedID = savedID
        } else if let dac = devices.first(where: {
            $0.name.localizedCaseInsensitiveContains("FiiO") ||
            $0.name.localizedCaseInsensitiveContains("DAC") ||
            $0.name.localizedCaseInsensitiveContains("K7")
        }) {
            resolvedID = dac.id
        } else {
            resolvedID = devices.first?.id
        }
        
        if Thread.isMainThread {
            self.availableOutputs = devices
            if self.selectedOutputID == nil {
                self.selectedOutputID = resolvedID
            }
        } else {
            DispatchQueue.main.async {
                self.availableOutputs = devices
                if self.selectedOutputID == nil {
                    self.selectedOutputID = resolvedID
                }
            }
        }
    }
    
    func start() {
        transitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.startSynchronously()
        }
    }
    
    private func startSynchronously() {
        let blackholeID = AudioDeviceHelper.getDeviceID(byNameSubstring: "BlackHole")
        let outDevID = self.selectedOutputID
        
        guard let bhID = blackholeID else {
            DispatchQueue.main.async {
                self.statusMessage = "BlackHole 2ch not detected. Run: brew install blackhole-2ch"
                self.isRunning = false
            }
            return
        }
        
        guard let targetID = outDevID else {
            DispatchQueue.main.async {
                self.statusMessage = "No output device selected"
                self.isRunning = false
            }
            return
        }
        
        stopSynchronously()
        
        self.inputDeviceID = bhID
        self.activeOutputDeviceID = targetID
        self.writeSampleIndex = 0
        self.readSampleIndex = 0
        
        // Read current volume from BlackHole to initialize the slider
        if let initialVol = getSystemVolume(deviceID: bhID) {
            DispatchQueue.main.async {
                self.isUpdatingFromSystem = true
                self.volume = initialVol
                self.isUpdatingFromSystem = false
            }
        }
        
        // Attach listener so external changes (Control Center, keys) sync our slider
        attachSystemVolumeListeners(deviceID: bhID)
        
        // 1. Input Callback
        let inputCallback: AudioDeviceIOProc = { (inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData) -> OSStatus in
            guard let clientData = inClientData else { return noErr }
            let engine = Unmanaged<AudioLoopbackEngine>.fromOpaque(clientData).takeUnretainedValue()
            
            let bufferList = inInputData.pointee
            guard bufferList.mNumberBuffers > 0, let rawPtr = bufferList.mBuffers.mData else { return noErr }
            
            let floatSamples = rawPtr.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            
            var writeIdx = engine.writeSampleIndex
            let mask = engine.ringBufferMask
            let buf = engine.ringBuffer
            
            for i in 0..<sampleCount {
                buf[Int(writeIdx & Int64(mask))] = floatSamples[i]
                writeIdx &+= 1
            }
            
            OSMemoryBarrier()
            engine.writeSampleIndex = writeIdx
            return noErr
        }
        
        // 2. Output Callback
        let outputCallback: AudioDeviceIOProc = { (inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData) -> OSStatus in
            guard let clientData = inClientData else { return noErr }
            let engine = Unmanaged<AudioLoopbackEngine>.fromOpaque(clientData).takeUnretainedValue()
            
            let bufferList = outOutputData.pointee
            guard bufferList.mNumberBuffers > 0, let rawPtr = bufferList.mBuffers.mData else { return noErr }
            
            let outSamples = rawPtr.assumingMemoryBound(to: Float.self)
            let neededSamples = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            let gain = engine.effectiveGain
            
            OSMemoryBarrier()
            let currentWrite = engine.writeSampleIndex
            var currentRead = engine.readSampleIndex
            
            let available = currentWrite - currentRead
            let mask = engine.ringBufferMask
            let buf = engine.ringBuffer
            
            if available < Int64(neededSamples) || available > Int64(engine.ringBufferSize / 2) {
                currentRead = max(0, currentWrite - 2048)
            }
            
            for i in 0..<neededSamples {
                if currentRead < currentWrite {
                    outSamples[i] = buf[Int(currentRead & Int64(mask))] * gain
                    currentRead &+= 1
                } else {
                    outSamples[i] = 0.0
                }
            }
            
            engine.readSampleIndex = currentRead
            return noErr
        }
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        var inProc: AudioDeviceIOProcID?
        var outProc: AudioDeviceIOProcID?
        
        let statusIn = AudioDeviceCreateIOProcID(bhID, inputCallback, selfPointer, &inProc)
        let statusOut = AudioDeviceCreateIOProcID(targetID, outputCallback, selfPointer, &outProc)
        
        guard statusIn == noErr, statusOut == noErr, let validIn = inProc, let validOut = outProc else {
            if let p = inProc { AudioDeviceDestroyIOProcID(bhID, p) }
            if let p = outProc { AudioDeviceDestroyIOProcID(targetID, p) }
            
            DispatchQueue.main.async {
                self.statusMessage = "Failed binding device. Error: \(statusOut)"
                self.isRunning = false
            }
            return
        }
        
        self.inputIOProcID = validIn
        self.outputIOProcID = validOut
        
        let startIn = AudioDeviceStart(bhID, validIn)
        let startOut = AudioDeviceStart(targetID, validOut)
        
        if startIn == noErr && startOut == noErr {
            let devName = AudioDeviceHelper.getDeviceName(deviceID: targetID) ?? "Output"
            DispatchQueue.main.async {
                self.isRunning = true
                self.statusMessage = "Bridging BlackHole -> \(devName)"
            }
        } else {
            DispatchQueue.main.async {
                self.statusMessage = "AudioDeviceStart failed: in(\(startIn)) out(\(startOut))"
                self.isRunning = false
            }
        }
    }
    
    func stop() {
        transitionQueue.async { [weak self] in
            self?.stopSynchronously()
        }
    }
    
    private func stopSynchronously() {
        removeSystemVolumeListeners()
        
        if let inID = inputDeviceID, let inProc = inputIOProcID {
            AudioDeviceStop(inID, inProc)
            AudioDeviceDestroyIOProcID(inID, inProc)
            self.inputIOProcID = nil
        }
        if let outID = activeOutputDeviceID, let outProc = outputIOProcID {
            AudioDeviceStop(outID, outProc)
            AudioDeviceDestroyIOProcID(outID, outProc)
            self.outputIOProcID = nil
        }
        
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }
    
    func restartEngine() {
        transitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopSynchronously()
            usleep(100_000)
            self.startSynchronously()
        }
    }
    
    func adjustVolume(by delta: Float) {
        DispatchQueue.main.async {
            self.volume += delta
        }
    }
    
    func toggleMute() {
        DispatchQueue.main.async {
            self.isMuted.toggle()
        }
    }
    
    // MARK: - CoreAudio Volume Listeners & Synchronization
    
    private func attachSystemVolumeListeners(deviceID: AudioDeviceID) {
        removeSystemVolumeListeners()
        
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        if !AudioObjectHasProperty(deviceID, &volAddress) {
            volAddress.mSelector = kAudioDevicePropertyVolumeScalar
        }
        
        let volBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, let devID = self.inputDeviceID else { return }
            if let newVol = self.getSystemVolume(deviceID: devID) {
                DispatchQueue.main.async {
                    self.isUpdatingFromSystem = true
                    self.volume = newVol
                    self.isUpdatingFromSystem = false
                }
            }
        }
        
        self.volumeListenerBlock = volBlock
        AudioObjectAddPropertyListenerBlock(deviceID, &volAddress, DispatchQueue.global(qos: .userInteractive), volBlock)
        
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let mBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, let devID = self.inputDeviceID else { return }
            if let newMute = self.getSystemMute(deviceID: devID) {
                DispatchQueue.main.async {
                    self.isUpdatingFromSystem = true
                    self.isMuted = newMute
                    self.isUpdatingFromSystem = false
                }
            }
        }
        
        self.muteListenerBlock = mBlock
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.global(qos: .userInteractive), mBlock)
    }
    
    private func removeSystemVolumeListeners() {
        guard let devID = inputDeviceID else { return }
        
        if let block = volumeListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if !AudioObjectHasProperty(devID, &addr) {
                addr.mSelector = kAudioDevicePropertyVolumeScalar
            }
            AudioObjectRemovePropertyListenerBlock(devID, &addr, DispatchQueue.global(qos: .userInteractive), block)
            volumeListenerBlock = nil
        }
        
        if let block = muteListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(devID, &addr, DispatchQueue.global(qos: .userInteractive), block)
            muteListenerBlock = nil
        }
    }
    
    private func getSystemVolume(deviceID: AudioDeviceID) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(deviceID, &addr) {
            addr.mSelector = kAudioDevicePropertyVolumeScalar
        }
        var vol: Float32 = 0.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol)
        return (status == noErr) ? vol : nil
    }
    
    private func setSystemVolume(deviceID: AudioDeviceID, volume: Float) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(deviceID, &addr) {
            addr.mSelector = kAudioDevicePropertyVolumeScalar
        }
        var vol: Float32 = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
    }
    
    private func getSystemMute(deviceID: AudioDeviceID) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted)
        return (status == noErr) ? (muted != 0) : nil
    }
    
    private func setSystemMute(deviceID: AudioDeviceID, isMuted: Bool) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = isMuted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &muted)
    }
}
