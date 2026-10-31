# Installation Guide (`INSTALL.md`)

You can install **ExtDisplay** either using the one-command installer script (`install.sh`), a packaged `.dmg` installer, or directly from Xcode.

---

## Option 1: One-Command Mac Installer (`install.sh`)

Run the included [`install.sh`](install.sh) script from Terminal to build `ExtDisplayHost.app` in `Release` mode, install it into `/Applications/ExtDisplayHost.app`, configure silent background startup on Mac login, and launch it in the background:

```bash
chmod +x ./install.sh
./install.sh
```

### Build a Distributable `.dmg` Installer
To generate a drag-and-drop `dist/ExtDisplayHost.dmg` file (for sharing or uploading to GitHub Releases):

```bash
./install.sh --dmg
```

### Build & Install the iOS/iPadOS Client (`--client`)
To build `dist/ExtDisplayClient.ipa` in `Release` mode (and automatically install it onto a connected iPad or iPhone over USB-C):

```bash
./install.sh --client
```

### Build Both Host `.dmg` and Client `.ipa` (`--all`)
```bash
./install.sh --all
```

---

## Option 2: Install on iPad / iPhone (`ExtDisplayClient`)

1. Plug your iPad or iPhone into your Mac with a **USB-C** cable.
2. Open `Ext_Display.xcodeproj` in Xcode:
   ```bash
   open Ext_Display.xcodeproj
   ```
3. Select the **`ExtDisplayClient`** scheme at the top of Xcode, choose your connected iPad or iPhone as the run destination, and press **Run (`⌘R`)**.
4. If prompted on your iPad/iPhone for **Untrusted Developer**, open **Settings → General → VPN & Device Management**, tap your developer certificate, and tap **Trust**.

---

## Option 3: Uploading an Installer to GitHub Releases

If you want users to download a ready-to-install `.dmg` from your GitHub repository:

1. Build the `.dmg` package:
   ```bash
   ./install.sh --dmg
   ```
2. Open your repository's Releases page:
   `https://github.com/QuyenHoang999/MacOS_ExtDisplay/releases/new`
3. Enter a tag (e.g. `v1.0.0`) and title (`ExtDisplay v1.0.0`).
4. Drag and drop `dist/ExtDisplayHost.dmg` into the **Attach binaries** box and click **Publish release**.

