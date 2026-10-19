# MT760 Control

[简体中文](README.md) | **English**

**A third-party macOS driver / settings tool for the Rapoo MT760 mouse.**

A native macOS App (Swift + SwiftUI) for managing the MT760's settings: DPI, current DPI level, report rate and button mapping. The official A HUB Office does not need to be installed.

> This is an independently developed interoperability tool. It has no affiliation with or authorization from Rapoo, and contains no official binaries, firmware or source code.

## Why

The macOS version of Rapoo's official driver (A HUB Office) has many problems that have gone unfixed for a long time. This project re-implements the MT760's common settings on macOS, based on the official driver's communication protocol, as a replacement:

- Native Apple Silicon (arm64) build, no Rosetta required;
- Small, no third-party dependencies, no background services, kernel extensions or login items;
- Mouse settings only: no network access, no account sign-in, no data collection.

## Features

| Feature | Description |
|---|---|
| DPI | View the DPI values of all 7 levels; change the DPI of the current level (50–4000, in steps of 50) |
| Current level | Click a level card to switch the current DPI level |
| Report rate | 125 / 250 / 500 / 1000 Hz |
| Button mapping | Assign a function to each button: mouse buttons, DPI switching, sniper, rapid fire, scroll directions, multimedia keys, common shortcuts, “modifier + key” combinations, disable, restore default, and more |
| Device info | HID interface and descriptor details, raw configuration bytes, activity log, diagnostics JSON export |

When the mouse is plugged in, the App reads its current configuration automatically; changes are written immediately and then verified by reading them back. Settings are stored in the mouse, so they persist after unplugging or power loss, and keep working on computers that do not have this tool installed.

**Not supported yet:** macros, lighting, profile switching, pairing, firmware updates, factory reset.

## Compatibility

- **Mouse**: Rapoo MT760 (standard edition), wired USB connection (`24AE:4500`). Tested and working on firmware V0.1.4.4. Other firmware versions, the wireless receiver, Bluetooth, and other MT760 variants have not been verified.
- **System**: macOS 13 or later.
- **Architecture**: release packages support Apple Silicon (arm64) only; Intel compatibility is not supported.
- **Language**: The interface is available in English and Simplified Chinese. Switch instantly with the globe button in the toolbar (or View → Language in the menu bar); the choice is remembered. The default, “System Default”, follows the system language (Chinese if Chinese is preferred, otherwise English).

## Installation

Download the `macos_arm64` ZIP from this repository's **Releases** (Apple Silicon only). Extract it and drag `MT760 Control.app` to Applications. The archive also includes `mt760-diagnostics` and both README files. Release builds are ad-hoc signed, not notarized by Apple. Gatekeeper may block the first launch; after verifying the download source, follow macOS prompts in System Settings → Privacy & Security to allow opening. Input Monitoring permission may need to be granted again after updates.

Alternatively, build from source. Only the Xcode Command Line Tools (Swift 6 toolchain) are required — no full Xcode, Homebrew or administrator privileges.

```bash
xcode-select --install            # if the Command Line Tools are not installed yet
git clone <this repository URL>
cd MT760-driver
./scripts/build-app.sh
open "dist/MT760 Control.app"
```

After building, you can drag `dist/MT760 Control.app` into the Applications folder.

Code signing: `build-app.sh` signs with the first “Apple Development” certificate in your keychain by default, and falls back to ad-hoc signing if none is found. Use the `CODE_SIGN_IDENTITY` environment variable to choose a different identity. Build products are not notarized.

## First Launch: Input Monitoring Permission

The MT760's configuration interface is recognized by macOS as a “keyboard”-class HID device, so macOS requires the App to have the **Input Monitoring** permission before it can open it. (The App does not listen to any keyboard or mouse input.)

1. On first launch, the App automatically triggers the system permission prompt;
2. Turn on **MT760 Control** in “System Settings → Privacy & Security → Input Monitoring”;
3. Reopen the App as prompted.

The permission is tied to the signing identity:

- When signed with an Apple Development certificate, the permission survives rebuilds;
- When signed ad-hoc, the permission must be granted again after every rebuild.

If the permission stops working, reset it and grant it again:

```bash
tccutil reset ListenEvent local.mt760.control
```

## Usage

- **Automatic reading**: DPI, report rate and button configuration are read automatically when the mouse is plugged in. Press `⌘R`, or switch back to the App window (more than 5 seconds after the last read), to read again.
- **DPI**: Click a level card to switch the current level; adjust the current level's DPI with the slider, text field or stepper, then click “Apply” or press Return to write it.
- **Report rate**: Just click the desired report rate.
- **Buttons**: Choose a new function from the menu to the right of a button to write it. “Custom Key Combination…” sets one modifier plus one key. Invalid choices are shown as unavailable, e.g. removing the last left button.
- **Diagnostics export**: `⌘E`, or “Device Info → Export Diagnostics…”.

> Quit the official A HUB Office before using this tool; the two cannot access the device at the same time. While the official app is running, this tool refuses to operate and shows a message.

## How It Works & Safety Design

To minimize the risk of putting the mouse into an abnormal state, every change follows a fixed procedure:

1. **Fresh read**: First read the device's current data and compare it byte by byte with what the UI shows. If they differ (for example, the DPI button on the mouse was pressed in the meantime), the write is abandoned and the device is re-read.
2. **Single write**: Send exactly one corresponding write command from the official protocol, changing only the target bytes and preserving all others.
3. **Readback verification**: Read the data back and confirm that only the expected bytes changed.

On top of that:

- On failure there is **no retry and no rollback**; the App automatically re-reads the device to show its real state;
- All device access happens in a separate helper process (`mt760-read-helper`) with a time limit, and only one runs at a time;
- The device scan every 2 seconds only enumerates; it never opens the device;
- No system settings are modified, the official App is not modified, and no network requests are made;
- Exported diagnostics contain no serial numbers, Bluetooth addresses or input events, but do include product information, descriptors and raw communication bytes — please review them before sharing.

Protocol details (memory addresses, command formats, button encodings) are documented in the comments of the files in [`Sources/MT760Core/`](Sources/MT760Core/).

## Diagnostics Command-Line Tool

`mt760-diagnostics` only enumerates Rapoo (VID `24AE`) HID interfaces; it never opens or communicates with the device:

```bash
./dist/mt760-diagnostics --json > diagnostics.json
hidutil list --matching '{"VendorID":9390}'
```

When filing an issue, please attach the diagnostics JSON and the activity records exported from the App.

## Known Limitations

- Only the standard MT760 over a wired USB connection is supported.
- Only the DPI value of the **current** level can be changed; levels cannot be added or removed.
- Switching levels copies the official app's byte order, so two auxiliary bytes of unknown meaning are swapped (matching the official behavior); the activity log lists this change.

## Development

```text
Sources/MT760Core/        HID enumeration, descriptor parsing, protocol encoding/decoding, write plans and verification,
                          helper supervision, IOKit read/write transactions, localization (Localization.swift)
Sources/MT760App/         SwiftUI interface (AppModel device queue, one view file per page)
Sources/MT760ReadHelper/  Separate device-access process
Sources/MT760Diagnostics/ Enumeration-only command-line tool
Tests/                    Offline tests (no HID hardware access)
Resources/                Info.plist and App icon
scripts/                  Build, test and icon-generation scripts
```

```bash
swift build                     # Debug build
./scripts/test.sh               # Offline tests (Swift Testing, requires macOS 14+)
MT760_LANG=en ./scripts/test.sh # Run the tests with English messages
./scripts/build-app.sh          # Release build packaged as a .app
codesign --verify --deep --strict "dist/MT760 Control.app"
swift scripts/make-icon.swift   # Regenerate Resources/AppIcon.icns
```

`scripts/test.sh` automatically locates the Swift Testing macro plugin in the Command Line Tools; no system configuration changes are needed.

User-facing text is written as Chinese/English pairs with `L("中文", "English")` (see `Sources/MT760Core/Localization.swift`). When adding or changing text, please provide both languages. The in-app language choice is stored in the App's own preferences; with “System Default”, the environment variable `MT760_LANG=zh|en` overrides the system language (handy for tests).

Issues and PRs are welcome. If you have an MT760 with a different firmware version or a wireless edition, diagnostics reports are appreciated.

## Disclaimer

This tool works by sending configuration commands to the mouse; the command formats come from analysis of the official program. The author has limited the scope of writes as much as possible and verifies them byte by byte, but cannot guarantee safety on every device and firmware. Use at your own risk.

“Rapoo”, “雷柏” and “MT760” are trademarks of their respective owners. This project is not affiliated with Rapoo.
