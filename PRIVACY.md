# Privacy Policy

_Last updated: 2026-05-16_

OpenRM is an open-source, on-device application. Its design goal is that
**your health data never leaves your control.** This policy explains, in
plain terms, what the app touches and where that data goes.

## Summary

- OpenRM has **no servers**. The authors operate no backend, no cloud,
  and no account system.
- OpenRM performs **no analytics, telemetry, crash reporting, or
  tracking**. There are no third-party SDKs that collect data. (The sole
  third-party dependency, `BigInt`, is a pure-math library with no
  networking.)
- OpenRM makes **no network requests of its own**. It communicates only
  with your CPAP device over local Bluetooth, and with Apple Health on
  your device.
- All processing — protocol decoding, sleep staging, feature extraction
  — happens **locally on your iPhone**.

## What data OpenRM handles

When you pair OpenRM with a ResMed AirSense 11, the app reads:

- Therapy summaries (per-day and per-session usage, pressure, leak,
  events such as apneas/hypopneas)
- Per-minute and periodic diagnostic therapy data
- Device activity logs (UI events, cellular-modem lifecycle, setting
  profile history) used for sleep staging and diagnostics
- A locally computed sleep-stage estimate (Awake / Light / Deep / REM)

This is **your** health data, retrieved from **your** device, on **your**
phone.

## Where that data goes

- **Stays on device.** Decoded therapy data and intermediate features
  are held in app memory and local app storage on your iPhone.
- **Apple Health.** With your explicit permission, OpenRM writes sleep
  sessions to Apple Health (HealthKit) as `sleepAnalysis` samples.
  Once written, that data is governed by
  [Apple's Health privacy model](https://support.apple.com/en-us/HT203037)
  and your iOS settings — not by OpenRM. OpenRM only reads existing
  sleep samples to avoid creating duplicates.
- **Nowhere else.** OpenRM does not transmit your data to the authors,
  to ResMed, or to any third party.

## Bluetooth

OpenRM communicates with your CPAP over Bluetooth Low Energy. This is a
direct, local radio link between your phone and your device. Pairing
uses the device's own SRP key exchange and encrypted session; the
resulting credential is stored in the **iOS Keychain** on your device
and is never exported.

## Background activity

OpenRM may schedule background refreshes (via iOS `BGTaskScheduler`) so
that recent therapy data is ready when you open the app. This runs
entirely on your device and follows the same "stays local" rules above.

## Your controls

- **Revoke Health access** at any time in iOS Settings → Privacy &
  Security → Health → OpenRM.
- **Delete the app** to remove all OpenRM-held local data and the stored
  Bluetooth pairing credential. Data already written to Apple Health is
  managed by the Health app and is not removed by deleting OpenRM; you
  can delete it from within Apple Health.
- **Unpair the device** in iOS Bluetooth settings to sever the link.

## Children

OpenRM is not directed at children and collects no data from anyone.

## Changes to this policy

Because OpenRM is open source, any change to this policy is a public,
version-controlled commit in this repository. The "Last updated" date
above reflects the most recent change.

## Not a clinical product

OpenRM is independent research software and is **not** affiliated with,
endorsed by, or supported by ResMed Inc. It is **not** a medical device
and is **not** intended for clinical use or therapy decisions. See the
project [README](README.md) and [LICENSE](LICENSE) for the full
disclaimer and warranty terms.

## Contact

Questions about privacy can be raised as an issue in this repository:
<https://github.com/sparc5/OpenRM/issues>.
