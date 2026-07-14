# Fight HR — native iOS app

A native SwiftUI rewrite of the Fight HR web app that talks to your COROS / any
standard Bluetooth heart-rate monitor **directly via the iPhone's own Bluetooth
(CoreBluetooth)** — no Bluefy required.

Feature parity with the web app: live HR + zone, training zones (% max HR or
Karvonen), Keytel calories, round timer (Muay Thai / BJJ defaults) with bells,
10-second warning, per-round stats + 60-second recovery HR, session history with an
8-week trend chart, and CSV export. Sauna and ice-bath therapy can also be recorded
as continuous heart-rate sessions with their own history filters and summaries.

## Requirements
- A Mac with **full Xcode** installed (App Store, ~7 GB). Command Line Tools alone is
  not enough.
- An **Apple Developer account** (you have one) signed into Xcode.
- An iPhone running **iOS 16 or later** and a Lightning/USB-C cable.

## First-time setup
1. Install Xcode from the Mac App Store, then point the toolchain at it:
   ```
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. Open the project:
   ```
   open ios/FightHR.xcodeproj
   ```
   (If it ever fails to open or you add/rename files, regenerate it with
   [XcodeGen](https://github.com/yonatans/XcodeGen): `brew install xcodegen` then
   `cd ios && xcodegen generate`. `project.yml` is the source of truth.)
3. In Xcode, select the **FightHR** target → **Signing & Capabilities**:
   - Check **Automatically manage signing**.
   - Set **Team** to your Apple Developer account.
   - If the bundle id `com.fighthr.app` is taken, change it to something unique
     (e.g. `com.yourname.fighthr`).

## Run it on your iPhone
1. Plug the iPhone into the Mac; tap **Trust** on the phone if prompted.
2. In Xcode's top toolbar, choose your iPhone as the run destination.
3. Press **▶ Run** (Cmd-R). Xcode builds, signs, installs, and launches it.
4. First launch only: the app is from a "developer," so approve it on the phone:
   **Settings → General → VPN & Device Management → (your developer cert) → Trust**,
   then reopen the app.
5. In the app: **Train** tab → choose an activity → **Connect HR Monitor** → approve
   the Bluetooth permission prompt → wake the COROS. Live BPM should stream with no
   Bluefy. Choose **Sauna** or **Ice Bath** to record a continuous therapy session.

Tip: use **Demo mode** (bottom of the Train tab) to exercise the UI without a strap.

## Run model tests
```bash
cd ios
xcrun swiftc FightHR/Sources/{Activity,Profile,Session,Store}.swift \
  FightHRTests/ActivityModelTests.swift \
  -o /tmp/fighthr-activity-tests && /tmp/fighthr-activity-tests
```

## Share it with others
- **TestFlight** (recommended): in Xcode, **Product → Archive**, then distribute to
  App Store Connect → TestFlight, and invite testers by email. Needs an App Store
  Connect app record (free with your developer account).
- **Direct install**: with your paid account, a device-installed build is signed for
  ~1 year before it needs re-signing.

## Project layout
```
ios/
  FightHR.xcodeproj/        generated Xcode project (open this)
  project.yml               XcodeGen spec (regenerate the project from this)
  FightHR/
    Info.plist              Bluetooth usage string, display name, orientation
    Assets.xcassets/        app icon (boxing glove + HR pulse)
    Sources/
      FightHRApp.swift       app entry + Train/History/Settings tabs
      Theme.swift            colors/card matching the web app
      Profile.swift          user profile model
      Zones.swift            zone bounds + Keytel calories (pure logic)
      Activity.swift         sports + per-sport timer config
      Session.swift          completed-session + round models
      Store.swift            persistence (UserDefaults + JSON) + CSV
      HeartRateMonitor.swift CoreBluetooth HRM client + demo mode
      SessionEngine.swift    1Hz tick loop, round state machine, finalize
      Bells.swift            round bells + warning tones + haptics
      Components.swift       zone bars, HR chart, share sheet helpers
      TrainView.swift        main training screen
      HistoryView.swift      history list + 8-week trend
      SettingsView.swift     profile / mode / zones / data
      SummarySheet.swift     post-session summary
```

## Notes
- HR decoding matches the Bluetooth Heart Rate Service spec (service `0x180D`,
  measurement `0x2A37`); zones/calories are ported 1:1 from the web app so numbers
  agree.
- Data is on-device only (UserDefaults + a JSON file in the app's Documents). No
  account, no cloud. Reinstalling clears it; export CSV first if you want a backup.
- The web app (`../index.html`) remains the cross-platform / shareable version; this
  native app is the iPhone-direct-Bluetooth version.
