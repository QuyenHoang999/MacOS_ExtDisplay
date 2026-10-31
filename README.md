# ExtDisplay — Low-Latency USB-C Extended Display for macOS & iPadOS/iOS

**ExtDisplay** turns an iPad or iPhone into a true hardware-accelerated **extended display** for macOS over a direct **USB-C (`usbmuxd`)** connection — with zero network setup, automatic plug-and-play connection, up to **120 Hz ProMotion**, Retina HiDPI scaling, and multi-touch / Apple Pencil input.

---

## ✨ Features

- **Direct USB-C (`usbmuxd`) Transport**: Connects over Apple's native USB multiplex daemon (`/var/run/usbmuxd` on macOS → TCP port `29480` on iOS/iPadOS) with sub-millisecond transport latency and no Wi-Fi dependence.
- **True Extended Desktop (`CGVirtualDisplay`)**: Creates a native virtual monitor in macOS `WindowServer` and automatically configures it as an extended workspace (never mirrored).
- **Hardware Video Pipeline (60 Hz / 120 Hz ProMotion)**:
  - **Capture**: `ScreenCaptureKit` (`SCStream`) zero-copy `IOSurface`-backed `CVPixelBuffer` capture (`NV12` / `420v`).
  - **Encode**: `VideoToolbox` (`VTCompressionSession`) real-time hardware HEVC (H.265) / H.264 encoding.
  - **Decode & Render**: `VTDecompressionSession` + custom `CAMetalLayer` BT.709 `NV12` shader (`MetalRenderer`) with `CVMetalTextureCache` zero-copy textures.
- **Touch & Apple Pencil Input (`CGEvent`)**: Maps single-finger drag, tap-to-click, two-finger scroll, and Apple Pencil pressure/tilt directly onto the virtual display's global coordinates.
- **Silent Background Agent & Auto-Start at Login**:
  - Starts hidden in the background on Mac power-on (`LSUIElement`) without opening a GUI window or cluttering the Dock.
  - Automatically installs to `/Applications/ExtDisplayHost.app` and registers in **System Settings → General → Login Items**.
  - Accessible anytime from the macOS menu bar icon, with on-demand GUI window (**Open ExtDisplay Window** / **Hide App**).
- **Plug-and-Play iOS/iPadOS Client**: Automatically listens and connects as soon as the USB-C cable is plugged in, transitioning to a clean full-screen display with no on-screen overlays.

---

## 🏗 Project Structure

```text
Ext_Display/
├── install.sh                      # One-command Release builder, /Applications installer & DMG packager
├── INSTALL.md                      # Detailed installation & distribution guide
├── Ext_Display.xcodeproj/          # Xcode project (ExtDisplayHost & ExtDisplayClient targets)
├── Config/
│   ├── Host-Info.plist             # macOS Host bundle configuration (LSUIElement, permissions)
│   └── Client-Info.plist           # iOS/iPadOS Client bundle & icon configuration
├── Packages/
│   └── ExtDisplayKit/              # Shared Swift package (protocol, framing, geometry, UI logo)
│       └── Sources/ExtDisplayKit/
│           ├── Protocol/           # Binary frame codec, ByteBuffer, Message definitions
│           ├── Transport/          # Framed socket/NWConnection & usbmuxd packet protocol
│           ├── Geometry/           # HiDPI VirtualMode & coordinate normalization helpers
│           ├── Video/              # CMFormatDescription & sample buffer helpers
│           └── UI/                 # Shared vector brand logo (ExtDisplayLogoView)
├── ExtDisplayHost/                 # macOS 14.0+ Host application
│   ├── HostApp.swift               # Menu bar agent + on-demand desktop GUI window
│   ├── HostController.swift        # USB device discovery, auto-connect & session lifecycle
│   ├── Session/HostSession.swift   # Per-device streaming & input pipeline coordinator
│   ├── VirtualDisplay/             # CGVirtualDisplay creation, HiDPI modes & un-mirroring
│   ├── Capture/ScreenCapturer.swift# ScreenCaptureKit (SCStream) display capture
│   ├── Video/VideoEncoder.swift    # VideoToolbox hardware HEVC / H.264 encoder
│   ├── Input/InputInjector.swift   # CGEvent mouse, scroll & tablet/Pencil injection
│   ├── Transport/USBMuxClient.swift# macOS /var/run/usbmuxd client
│   └── System/                     # /Applications installer & Login Items registration
├── ExtDisplayClient/               # iOS / iPadOS 17.0+ Client application
│   ├── ClientApp.swift             # iOS app entry point (idle timer disabled while active)
│   ├── ContentView.swift           # Auto-connect waiting screen & full-screen display view
│   ├── Network/ClientModel.swift   # USB loopback listener, handshake & stats
│   ├── Video/VideoReceiver.swift   # VideoToolbox hardware decoder
│   ├── Render/                     # Metal NV12 renderer (MetalRenderer + Shaders.metal)
│   └── Input/TouchInputView.swift  # Multi-touch & Apple Pencil gesture capture
└── ExtDisplayAndroid/              # Android 8.0+ (API 26+) Client application (Kotlin)
    └── app/src/main/java/com/qhpersonalteam/extdisplay/
        ├── MainActivity.kt         # Full-screen immersive activity & waiting screen
        ├── AndroidClientSession.kt # USB-C TCP 50505 listener & handshake engine
        ├── VideoDecoder.kt         # Low-latency MediaCodec HEVC/H.264 hardware decoder
        ├── TouchInputHandler.kt    # Multi-touch & Stylus/S-Pen input mapper
        └── Protocol.kt             # Binary wire protocol matching ExtDisplayKit
```

---

## 📋 Requirements

- **macOS Host (`ExtDisplayHost`)**: macOS 14.0 (Sonoma) or later, Apple Silicon or Intel Mac.
- **iOS/iPadOS Client (`ExtDisplayClient`)**: iOS / iPadOS 17.0 or later.
- **Xcode**: Xcode 16+ / 26+ with an Apple Development signing certificate.
- **Cable**: USB-C data cable connecting the Mac and iPad/iPhone.

---

## 🚀 Installation & Getting Started

See [`INSTALL.md`](INSTALL.md) for full details.

### 1. Quick Install on macOS (`install.sh`)

Run the included [`install.sh`](install.sh) script from Terminal to build `ExtDisplayHost.app` in `Release` mode, install it into `/Applications/ExtDisplayHost.app`, configure background auto-start on login, and launch it in the background:

```bash
chmod +x ./install.sh
./install.sh
```

To also package a distributable drag-and-drop `.dmg` installer (`dist/ExtDisplayHost.dmg`):

```bash
./install.sh --dmg
```

To build the iOS/iPadOS Client (`dist/ExtDisplayClient.ipa`) and automatically install it onto a USB-connected iPad or iPhone:

```bash
./install.sh --client
```

To build both `dist/ExtDisplayHost.dmg` and `dist/ExtDisplayClient.ipa` at once:

```bash
./install.sh --all
```

### 2. Build & Run via Xcode

1. **Open the Project**:
   ```bash
   open Ext_Display.xcodeproj
   ```
2. **macOS Host (`ExtDisplayHost`)**:
   - Select the **`ExtDisplayHost`** scheme and target **My Mac**, then press **Run (`⌘R`)**.
   - Click the **ExtDisplay** icon in the macOS top menu bar (and optionally click **Open ExtDisplay Window**) to grant:
     - **Screen Recording** permission (required to capture the virtual display).
     - **Accessibility** permission (required to inject touch and Apple Pencil input).
3. **iOS/iPadOS Client (`ExtDisplayClient`)**:
   - Connect your iPad or iPhone via USB-C, select the **`ExtDisplayClient`** scheme with your device as the destination, and press **Run (`⌘R`)**.
   - Once opened, `ExtDisplayClient` automatically connects over USB-C and begins streaming your extended Mac desktop.
4. **Android Phone / Tablet Client (`ExtDisplayAndroid`)**:
   - Open [`ExtDisplayAndroid/`](ExtDisplayAndroid) in **Android Studio**.
   - Enable **USB Debugging** on your Android phone (**Settings → Developer options → USB debugging**) and connect it to your Mac via USB-C.
   - Click **Run (`⌃R`)** in Android Studio to install and launch `ExtDisplay` on your Android phone — `ExtDisplayHost` on macOS automatically detects the Android phone over ADB USB-C and extends your Mac desktop onto it.

---

## 🖥 Background & Window Controls (macOS)

- **Silent Startup at Power-On**: When your Mac boots and logs in, `ExtDisplayHost` launches silently in the background (no Dock icon and no popup window) and immediately listens for USB-C devices.
- **Show GUI Window**: Click the **ExtDisplay** icon in the top menu bar → **Open ExtDisplay Window**.
- **Hide to Background**: Click **Hide App**, close the window (`X`), or select **Quit** on the Dock icon (`⌘Q`) to remove the window and Dock icon while keeping the background service and active display sessions running.
- **Full Quit**: Click the **ExtDisplay** menu bar icon → **Quit** to disconnect all displays and exit the background process.
