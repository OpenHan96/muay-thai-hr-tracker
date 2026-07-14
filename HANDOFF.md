# US Muay Thai Heart HR Tracker — Development Handoff

Updated: 2026-07-14

## Canonical repository

- GitHub: `https://github.com/OpenHan96/muay-thai-hr-tracker.git`
- Branch: `main`
- iOS project to open: `ios/FightHR.xcodeproj`
- XcodeGen source of truth: `ios/project.yml`

This is the only active repository. Do not recreate or continue work in the old
`fight-hr-tracker` repository.

## Current state

The native SwiftUI app builds and supports:

- Muay Thai, Running, BJJ, Sauna, and Ice Bath activity selection.
- Direct Bluetooth heart-rate monitoring using the standard Heart Rate Service.
- Demo heart-rate signals tailored to each activity.
- Round timers and bells for combat activities.
- Continuous, silent tracking for Sauna and Ice Bath therapy sessions.
- Session persistence, activity-aware history filters and summaries, and CSV export.
- Training video recording with a heart-rate overlay.
- Protection against malformed 16-bit Bluetooth heart-rate packets.

Sauna and Ice Bath must remain continuous-only activities. They should not start
GPS, use round timers, or play bells.

## Latest verified work

- `1d9e795` — Add sauna and ice bath heart rate tracking.
- `c38ddfe` — Fix stale HR during recording and redesign the overlay badge.
- `755ec06` — Improve recording reliability, keep-awake behavior, and HR auto-connect.

Verification completed on 2026-07-14:

- Activity model tests passed.
- Full unsigned iOS Simulator build passed.
- Full Swift source type-check and device-target build passed during the build loop.
- The five activity choices were visually checked in the Simulator.
- Two final Codex reviews reported no actionable issues.

Run the model tests with:

```bash
cd ios
xcrun swiftc FightHR/Sources/{Activity,Profile,Session,Store}.swift \
  FightHRTests/ActivityModelTests.swift \
  -o /tmp/fighthr-activity-tests && /tmp/fighthr-activity-tests
```

Run a simulator build with:

```bash
xcodebuild -project ios/FightHR.xcodeproj \
  -scheme FightHR \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## Branding note

The canonical product name is **US Muay Thai Heart HR Tracker**, and the repository
is `muay-thai-hr-tracker`. The existing Xcode project, target, source directory,
bundle identifier, and some user-facing strings are still internally named
`FightHR` or `Fight HR`. This is why the correct project file is currently named
`FightHR.xcodeproj`; it is not the deleted old repository.

If a complete internal rename is requested, update `ios/project.yml` first, then
regenerate the Xcode project and verify signing, bundle identifiers, tests, and data
compatibility as a dedicated change.

## Continue on another computer

For an existing clone:

```bash
git fetch origin
git switch main
git pull --ff-only origin main
open ios/FightHR.xcodeproj
```

For a new computer without the repository:

```bash
git clone https://github.com/OpenHan96/muay-thai-hr-tracker.git
cd muay-thai-hr-tracker
open ios/FightHR.xcodeproj
```

When starting a new Codex task, say: **Read `HANDOFF.md`, inspect the current git
status, and continue from the latest `main` branch.**

Before editing, preserve any local changes on the new computer and confirm the
working tree state with `git status --short --branch`.
