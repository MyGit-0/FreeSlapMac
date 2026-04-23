# FreeSlapMac

A free, open menu-bar app inspired by [slapmac.com](https://slapmac.com/). Slap your Apple Silicon MacBook, it yells back. Need a break? Hit **Rage Quit** and the Mac locks itself while a relaxing track plays.

Detection technique is borrowed from [taigrr/spank](https://github.com/taigrr/spank): read the IMU accelerometer directly over IOKit HID, then run an STA/LTA + peak/MAD pipeline to distinguish a real impact from everyday vibration.

> Apple Silicon only (M1 and newer). Requires macOS 14 (Sonoma) or later.

## How it works

```
┌────────────────────────────┐     XPC (mach)      ┌──────────────────────────┐
│ com.freeslapmac.helper     │ ───── events ─────▶ │ FreeSlapMac.app          │
│ LaunchDaemon (runs as root)│                     │ SwiftUI menu-bar app     │
│ reads SPU accelerometer    │                     │ plays sounds, locks,     │
│ runs slap detector         │                     │ offers Rage Quit         │
└────────────────────────────┘                     └──────────────────────────┘
```

The GUI stays unprivileged. A tiny signed helper runs as root (via `SMAppService.daemon`) and streams slap events over XPC. Approve it once in **System Settings → General → Login Items** and it keeps running across reboots.

## Project layout

| Path | Purpose |
|---|---|
| `App/` | SwiftUI menu-bar app — `FreeSlapMacApp.swift`, `MenuBarView.swift`, `SettingsView.swift`, `SlapEngine.swift`, `Info.plist`, `FreeSlapMac.entitlements` |
| `Helper/` | Privileged daemon — `main.swift`, `HIDSensor.swift`, `SlapDetector.swift`, `com.freeslapmac.helper.plist`, `Info.plist` |
| `Shared/` | `XPCProtocol.swift` used by both targets |
| `Resources/Sounds/Reactions/` | Drop `.mp3` reaction clips here (bundled into the app) |
| `Resources/Sounds/Relax/` | `relax.mp3` played during Rage Quit |
| `Tests/` | `SlapDetectorTests.swift` (Swift Testing) |
| `Packaging/build.sh` | Compile + ad-hoc sign + build `.dmg` |

## Build

### One-shot DMG

```bash
./Packaging/build.sh
```

Produces `build/FreeSlapMac.dmg`. Uses `swiftc` + `hdiutil` (or `create-dmg` if installed). Ad-hoc signed with identity `-`, no Apple Developer account required.

### Run unit tests

```bash
swift test                     # requires Xcode (for Testing framework)
```

### Opening in Xcode

Open the working directory with `xed .` — Xcode will index it. Create a workspace with two targets matching `App/` and `Helper/` if you want to use Xcode's build system end-to-end.

## First run (for users of the DMG)

1. Mount `FreeSlapMac.dmg`, drag the app to Applications.
2. Ad-hoc signed apps are blocked by Gatekeeper the first time:
   **Right-click the app → Open → Open Anyway.**
3. The app asks permission to install its helper — approve in
   **System Settings → General → Login Items**.
4. Slap the chassis. Menu-bar icon turns solid when detection is active.

## Permissions & hardware access

| What | Why | How |
|---|---|---|
| IOKit HID (seize) on the motion accelerometer | Read impact samples | Helper runs as root; no entitlement needed |
| Screen lock | Rage Quit | Shells out to `/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession -suspend` |
| Audio playback | Reaction + relax sounds | `AVAudioPlayer`, no entitlement |
| Login items / daemon install | Approve helper at boot | `SMAppService` (macOS 13+) |
| Custom Rage-Quit track | User picks their own song | `NSOpenPanel` + security-scoped bookmark |

**Not required:** Accessibility, Input Monitoring, Screen Recording, Camera, Microphone.

The app bundle is **not** sandboxed. The Mac App Store is not a viable distribution path because raw HID access to the SPU device isn't granted to sandboxed apps.

## Future paid-Developer-ID distribution

The source is ready for notarization. Swap two lines in `Packaging/build.sh`:

```bash
codesign --force --sign "Developer ID Application: Your Name (TEAMID)" \
    --options runtime \
    --entitlements App/FreeSlapMac.entitlements --deep "$APP_BUNDLE"

xcrun notarytool submit build/FreeSlapMac.dmg --apple-id … --team-id … --password … --wait
xcrun stapler staple build/FreeSlapMac.dmg
```

## Roadmap (not in v1)

- Lid-open/close "creak" reactions (IOKit power-mgmt notifications)
- USB plug/unplug "moaner" (`IOServiceAddMatchingNotification`)
- Voice-pack manager with multiple bundled packs
- Sparkle auto-update
- Homebrew cask

## Credits

- Detection approach & accelerometer reverse-engineering: [taigrr/spank](https://github.com/taigrr/spank)
- Inspiration & feature set: [slapmac.com](https://slapmac.com/)
- Swift tooling guidance: [hmohamed01/swift-development](https://github.com/hmohamed01/swift-development)
