# OpenRM

An unofficial iOS companion app for the **ResMed AirSense 11** CPAP. OpenRM
talks to the device over BLE, decodes its therapy spools, runs an on-device
sleep-staging model, and writes sessions into Apple Health.

> **Not affiliated with, endorsed by, or supported by ResMed Inc.**
> AirSense and myAir are trademarks of ResMed. This is independent
> research code; use at your own risk and do not expect parity with
> the official myAir app.

## What it does

- **Pairs and authenticates** with an AirSense 11 over BLE using the
  device's FIG framing layer + SRP-6a key exchange + AES session crypto.
- **Pulls therapy spools** (per-day Summary, per-minute therapy data,
  diagnostic 10-minute periodic, GUI activity events, cellular activity,
  setting profiles).
- **Decodes them** into Swift structs whose field semantics are mapped
  against the open-source [OSCAR](https://gitlab.com/CrimsonNape/OSCAR-code)
  ResMed loader. Wire-format details (protobuf containers, second-order
  predictive coding + zigzag + Rice-k=2 for the per-minute spool) were
  reverse-engineered from BLE captures.
- **Stages sleep** (Awake / Light / Deep / REM) via a TCN classifier
  shipped as a CoreML `.mlpackage`, with Viterbi smoothing over learned
  transition priors. Also keeps a fallback 3-class classifier for
  comparison.
- **Syncs sessions** to HealthKit as per-session `sleepAnalysis` samples,
  deduped by an external UUID so repeat syncs don't double-count.
- **Refreshes in the background** via `BGTaskScheduler` so a freshly-woken
  user opens the app to today's data already populated.

## Architecture

```
                ┌─────────────────────────────────────────┐
   AirSense 11  │  CoreBluetooth  →  FigFrame (framing)   │
       BLE  ───►│  SRPClient (auth)  →  FigCrypto (AES)   │
                │  CPAPController (high-level API)        │
                └────────────┬────────────────────────────┘
                             │
                             ▼
                ┌─────────────────────────────────────────┐
                │  Spool decoders                         │
                │   • SpoolDecoder (Summary)              │
                │   • PerMinuteSpoolDecoder               │
                │   • DiagnosticTenMinutePeriodic…        │
                │   • GUIActivityEvents…                  │
                │   • CellularActivityEvents…             │
                │   • SettingProfilesCollection…          │
                └────────────┬────────────────────────────┘
                             │
                             ▼
                ┌──────────────────────┐    ┌─────────────────┐
                │ SleepFeatureBuilder  │    │ HealthKitSync   │
                │  → SleepStageDetector│    │  (per-session)  │
                │     (CoreML + Viterbi)│   └─────────────────┘
                └──────────────────────┘
```

## Requirements

- Xcode **26.0** or newer (project is on the iOS 26 / macOS 26.4 SDKs)
- An iPhone running **iOS 26+** for full BLE + HealthKit functionality
  (Mac Catalyst and native macOS targets build, but HealthKit writes are
  iOS-only by Apple framework limitation)
- A real **AirSense 11** to pair with — there is no simulator path
- Your own Apple Developer team for signing (the public source has
  `DEVELOPMENT_TEAM = ""` — set yours in Signing & Capabilities)

The only third-party dependency is
[attaswift/BigInt](https://github.com/attaswift/BigInt), wired in via
Swift Package Manager and resolved automatically by Xcode on first build.

## Getting started

```bash
git clone https://github.com/sparc5/OpenRM.git
cd OpenRM
open OpenRM.xcodeproj
```

In Xcode:

1. Select the **OpenRM** target → **Signing & Capabilities** → set your
   Apple Developer team.
2. Plug in an iPhone, select it as the run destination, and build.
3. On first launch the app will scan for an AirSense 11. If the device
   has never been paired, OpenRM walks you through pairing with the
   4-digit PIN shown on the CPAP screen. Subsequent sessions resume
   silently with the persisted SRP key.

## Project layout

```
OpenRM/
├── OpenRMApp.swift              — @main + UIApplicationDelegate
├── ContentView.swift            — root view
├── DashboardView.swift          — main screen (LEDs, gauges, metrics)
├── HistoryView.swift            — past nights
├── SessionDetailView.swift      — drill-down for one session
│
├── BLEManager.swift             — CoreBluetooth wrapper
├── FigFrame.swift               — FIG framing layer
├── FigCrypto.swift              — AES session crypto
├── SRPClient.swift              — SRP-6a key exchange
├── CPAPController.swift         — high-level pairing/session API
├── CredentialStore.swift        — Keychain persistence
│
├── SpoolDecoder.swift                          — Summary
├── PerMinuteSpoolDecoder.swift                 — therapy minute-by-minute
├── DiagnosticTenMinutePeriodicSpoolDecoder.swift
├── GUIActivityEventsSpoolDecoder.swift
├── CellularActivityEventsSpoolDecoder.swift
├── SettingProfilesCollectionSpoolDecoder.swift
│
├── SleepFeatureBuilder.swift    — feature pipeline
├── SleepStageDetector.swift     — legacy 3-class
├── SleepStageDetectorV2.swift   — TCN 4-class + Viterbi
├── BLE3ClassClassifier.swift    — fallback gradient-boosted classifier
├── SleepViterbi.swift           — transition-prior smoothing
│
├── HealthKitSync.swift          — sleepAnalysis samples → Health
├── BackgroundSync.swift         — BGTaskScheduler integration
├── CleaningReminder.swift       — periodic cleaning notifications
├── LEDDisplay.swift, NeedleGauge.swift  — dashboard widgets
│
├── Assets.xcassets/             — app icon, launch screen, colors
└── Resources/
    ├── SleepModel.mlpackage     — TCN sleep-stage model
    ├── feature_spec.json        — model input contract
    └── transitions.json         — Viterbi transition priors
```

## Acknowledgments

- The [OSCAR project](https://gitlab.com/CrimsonNape/OSCAR-code), whose
  `resmed_loader.cpp` was the Rosetta Stone for AirSense 11 field names.
  OpenRM does not include any OSCAR code; it only references field
  semantics that OSCAR documents from the SD-card EDF format.
- The CoreBluetooth and HealthKit teams at Apple, for APIs that make
  this kind of side-project tractable.

## Status

Pre-release research code. Pairing, session resume, summary decoding,
per-minute decoding, sleep staging, and HealthKit sync all work end-to-end
on the author's device, but the protocol surface is large and edge cases
absolutely exist. Issues and PRs welcome.

## License

TBD. Treat this as "all rights reserved" until a license file is added.
Do not redistribute decoded ResMed firmware or proprietary protocol
specifications via PRs.
