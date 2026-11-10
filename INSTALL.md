# USBVolumeController - Installation & Setup Guide

**USBVolumeController** is a native macOS menu bar utility that bridges system audio output from **BlackHole 2ch** to external USB DACs (such as the FiiO K7) with synchronized hardware media keys (`F11`/`F12`), menu bar controls, and cubic volume attenuation.

---

## 1. System Requirements

* **Operating System**: macOS 14.0 (Sonoma) or macOS 15.0+ (Sequoia).
* **Architecture**: Universal (Apple Silicon `arm64` & Intel `x86_64`).
* **Tooling**: Xcode 15.0+ or Xcode Command Line Tools (`xcode-select --install`).
* **Virtual Loopback Driver**: BlackHole 2ch.

---

## 2. Install BlackHole 2ch

USBVolumeController captures system-level audio through BlackHole 2ch to maintain native volume key integration without kernel extensions.

Install via Homebrew:
```bash
brew install blackhole-2ch
```

*(Alternatively, download the signed installer `.pkg` directly from the [ExistentialAudio BlackHole Releases](https://github.com/ExistentialAudio/BlackHole/releases) page).*

---

## 3. Fast Automated Build & Install (Terminal)

From the project root directory where `USBSoundControl.xcodeproj` (or `USBVolumeController.xcodeproj`) resides, execute:

```bash
# 1. Build the Release application targeting macOS 14.0+
xcodebuild -project USBSoundControl.xcodeproj \
           -scheme USBSoundControl \
           -configuration Release \
           -derivedDataPath ./build \
           MACOSX_DEPLOYMENT_TARGET=14.0

# 2. Clean previous installations
sudo rm -rf /Applications/USBVolumeController.app

# 3. Copy to /Applications
sudo cp -R ./build/Build/Products/Release/USBSoundControl.app /Applications/USBVolumeController.app

# 4. Set directory ownership and permissions
sudo chown -R $(whoami):admin /Applications/USBVolumeController.app
sudo chmod -R 755 /Applications/USBVolumeController.app

# 5. Ad-hoc code sign with entitlement preservation
codesign --force --deep --sign - /Applications/USBVolumeController.app

# 6. Flush Finder metadata and launch
touch /Applications/USBVolumeController.app
killall Finder 2>/dev/null || true
open /Applications/USBVolumeController.app
```

---

## 4. Manual Xcode Export (GUI Method)

If building through Xcode:

### Step 1: Verify Deployment Target
1. In Xcode's Project Navigator, select the root project icon.
2. Under **Project** > **Info**, ensure **macOS Deployment Target** is set to **`14.0`**.
3. Under **Targets** > **General** > **Minimum Deployments**, verify **macOS** is set to **`14.0`**.

### Step 2: Configure Signing & Entitlements
1. Select the **Signing & Capabilities** tab.
2. Check **Automatically manage signing** and select your Team or Personal Apple ID.
3. Verify `App Sandbox` is disabled in `USBSoundControl.entitlements` (required for system-wide CoreAudio process access and hardware audio unit bindings).

### Step 3: Archive and Export
1. Set the destination device in the top toolbar to **My Mac**.
2. From the menu bar, select **Product** > **Archive**.
3. In the Organizer window:
   * Select your archive and click **Distribute App**.
   * Choose **Custom** > **Copy App**.
   * Export the output folder to your local disk.
4. Drag `USBVolumeController.app` into **`/Applications`**.

---

## 5. Required System Permissions

### Accessibility (Media Key Monitoring)
To intercept global volume keys (`F11`, `F12`, and `Mute`):

1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Locate **USBVolumeController** and toggle it **ON**.
3. If not listed, click the **`+`** button, navigate to `/Applications`, and select `USBVolumeController.app`.

---

## 6. System Audio Routing Configuration

To route audio through the controller:

1. Click the **Sound** icon in your macOS Menu Bar or Control Center.
2. Select **BlackHole 2ch** as your **Default Output Device**.
3. Open the **USBVolumeController** menu bar icon:
   * Verify your physical DAC (e.g., **FiiO K7**) is selected in the **Target Output Device (DAC)** dropdown.
   * Play audio from any application.
   * Adjust volume using your keyboard keys (`F11`/`F12`), the menu bar slider, or the Control Center slider; all controls remain bidirectionally synchronized.

---

## 7. Start on Login

Persistence across system restarts can be managed in two ways:

* **In-App Toggle (Recommended)**: Open the USBVolumeController menu window and toggle **Start on Login** to ON (uses `ServiceManagement.SMAppService`).
* **macOS Settings**: Open **System Settings** > **General** > **Login Items & Extensions**, click **`+`** under **Open at Login**, and select `/Applications/USBVolumeController.app`.

---

## 8. Uninstallation

To remove USBVolumeController and its configuration files completely:

```bash
# 1. Quit application
killall USBVolumeController 2>/dev/null || true

# 2. Unregister launch agent and remove application
sudo rm -rf /Applications/USBVolumeController.app

# 3. Remove persistent UserDefaults
defaults delete com.example.USBVolumeController 2>/dev/null || true
defaults delete com.example.USBSoundControl 2>/dev/null || true
```