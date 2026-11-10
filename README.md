# USBVolumeController - BlackHole Loopback Edition

A lightweight, high-performance native macOS Menu Bar application that routes system audio through **BlackHole 2ch**, scales volume in real time using a perceptual cubic curve, and outputs to external USB DACs (such as the FiiO K7) with full **F11 / F12 / Mute** media keys, bidirectional slider synchronization, and login persistence.

---

## 1. System Requirements & Prerequisites

* **macOS Target**: macOS 14.0 (Sonoma) or macOS 15.0+ (Sequoia)
* **Architecture**: Universal (`arm64` Apple Silicon & `x86_64` Intel)
* **Xcode**: Xcode 15.0+
* **Virtual Loopback Driver**: BlackHole 2ch

### Install BlackHole 2ch (One-Time Setup)

Install via Homebrew:
```bash
brew install blackhole-2ch
```
*(Verify by launching **Audio MIDI Setup** — confirm that **BlackHole 2ch** appears in the device list).*

---

## 2. Architectural Overview

External USB DACs often lack USB Audio Class (UAC) hardware volume descriptors, prompting macOS to lock the system volume slider and ignore volume media keys. **USBVolumeController** restores full control using a zero-overhead userspace audio loopback bridge:

```
[macOS System Audio / Apps]
            │
            ▼
   [BlackHole 2ch Output]  ◄─── (Native volume keys F11/F12 & macOS HUD active)
            │
            ▼ (CoreAudio IOProc Input)
 [USBVolumeController Engine]
   ├── Lock-Free 64K Power-of-Two Ring Buffer (Drift Compensated)
   ├── Real-Time Perceptual Gain Scaling: gain = pow(volume, 3.0)
   ├── Bidirectional Volume Listener (CoreAudio VirtualMainVolume)
   └── Persistent Configuration (UserDefaults & SMAppService)
            │
            ▼ (CoreAudio IOProc Output)
 [Hardware USB DAC (FiiO K7)] ───► [Headphones / Speakers]
```

### Key Engineering Features
* **Lock-Free Atomic Buffer**: Eliminates real-time thread priority inversion and audio dropouts across independent hardware clocks using an atomic 64K sample buffer.
* **Bidirectional Volume Sync**: Adjusting volume via hardware keys (`F11`/`F12`), Control Center, Touch Bar, or the in-app slider syncs every control bidirectionally without feedback loops.
* **Source Switching Resilience**: Serialized hardware transitions cleanly unbind and rebind CoreAudio IOProcs when changing outputs without throwing `1852797029` (`'nope'`) errors.
* **Start on Login**: Uses macOS 14+ `ServiceManagement` (`SMAppService`) for background persistence without requiring launch daemon plists.

---

## 3. Quick Build & Run (Xcode)

1. Open `USBVolumeController.xcodeproj` (or `USBSoundControl.xcodeproj`) in Xcode.
2. In **Signing & Capabilities**, select your Team under **Signing**.
3. Verify that **macOS Deployment Target** is set to **14.0** or later.
4. Press **⌘R** (or click Run).
5. When prompted on first launch, grant **Accessibility** permissions under **System Settings > Privacy & Security > Accessibility** so the app can register media keys.

---

## 4. Setup & Usage

1. Open **Control Center** or **System Settings > Sound** and set the macOS **Default Output** to **BlackHole 2ch**.
2. Click the **USBVolumeController** menu bar icon (speaker icon):
   * Select your hardware DAC (e.g., **FiiO K7**) in the **Target Output Device (DAC)** dropdown.
   * Toggle **Start on Login** to enable automatic background startup.
3. Adjust audio volume freely using:
   * Keyboard media keys (**F11** for down, **F12** for up, **Mute**).
   * The in-app menu bar slider.
   * The native macOS Control Center volume slider.

---

## 5. Command-Line Release Deployment

To compile and install the application directly into `/Applications`:

```bash
# 1. Build release binary targeting macOS 14.0+
xcodebuild -project USBVolumeController.xcodeproj \
           -scheme USBVolumeController \
           -configuration Release \
           -derivedDataPath ./build \
           MACOSX_DEPLOYMENT_TARGET=14.0

# 2. Deploy to /Applications
sudo rm -rf /Applications/USBVolumeController.app
sudo cp -R ./build/Build/Products/Release/USBVolumeController.app /Applications/

# 3. Apply ownership and ad-hoc signature
sudo chown -R $(whoami):admin /Applications/USBVolumeController.app
sudo chmod -R 755 /Applications/USBVolumeController.app
codesign --force --deep --sign - /Applications/USBVolumeController.app

# 4. Flush Finder caches and launch
touch /Applications/USBVolumeController.app
killall Finder 2>/dev/null || true
open /Applications/USBVolumeController.app
```