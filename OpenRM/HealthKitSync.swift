//
//  HealthKitSync.swift
//  OpenRM
//
//  Push decoded CPAP Summary records into Apple Health.
//
//  Platform gating: native macOS cannot WRITE to HealthKit (Apple framework
//  limitation — confirmed in the Xcode 26 headers: core write APIs are
//  `API_UNAVAILABLE(macos)`). We gate the entire module on
//  `!os(macOS)` so the native Mac target builds without any HealthKit
//  references, while iOS/iPadOS/Mac Catalyst builds get the real thing.
//  (`os(iOS)` is also true on Mac Catalyst, so Catalyst builds pass this
//  guard too.)
//
//  What we write:
//    - One `HKCategoryType.sleepAnalysis` sample PER REAL THERAPY
//      SESSION (not per day). Each DaySummary may contain multiple
//      sessions decoded from the spool's field-6 list. A night with
//      two sleep blocks (e.g. bathroom break) produces two samples
//      with correct start/end times, not one fabricated combined block.
//    - Value is `.asleepUnspecified` (the CPAP can't distinguish
//      sleep stages so we pick the generic "asleep" category value).
//    - Each sample is tagged with an `openrm-sess-<start_ms>` external
//      UUID in metadata so repeat syncs dedupe cleanly.
//
//  Legacy cleanup:
//    An earlier version of this module wrote one sample per day with
//    a fabricated "07:00 local wake time". Those samples carry an
//    `openrm-day-*` ID instead of `openrm-sess-*`. `cleanupLegacySamples`
//    deletes them so they don't double-count with the new per-session
//    samples. Call it once per sync — it's cheap after the first run
//    because there's nothing left to delete.
//

#if canImport(HealthKit) && !os(macOS)

import Foundation
import HealthKit
import os

private let log = Logger(subsystem: "com.openrm.cpap", category: "HealthKitSync")

private extension Date {
    /// Truncate to the enclosing UTC minute boundary. Used everywhere
    /// we need to snap heterogeneous timestamps (HealthKit samples, BLE
    /// spool minutes, our own per-minute features) onto a shared key.
    func floorToMinute() -> Date {
        Date(timeIntervalSince1970:
            (self.timeIntervalSince1970 / 60.0).rounded(.down) * 60.0)
    }
}

/// Metadata key used to dedupe OpenRM-sourced sleep samples on re-sync.
/// One stable UUID per CPAP day → Health stores it alongside the sample,
/// and we query by it before inserting.
private let openrmSyncIDKey = "com.openrm.cpap.syncId"

@MainActor
enum HealthKitSync {

    /// Singleton store. Apple's own docs explicitly say to keep a single
    /// `HKHealthStore` around for the life of the app.
    static let store = HKHealthStore()

    /// Have we already asked the user for permission this session?
    /// `HKHealthStore.authorizationStatus(for:)` only tells us whether
    /// the user denied sharing, not whether they granted it — Apple's
    /// privacy model. So we track it ourselves.
    private(set) static var authorized = false

    /// Ask the user for write permission for sleep samples and read
    /// permission for heart rate (used as input to the TCN sleep-stage
    /// model). Safe to call multiple times — iOS shows the sheet only
    /// on first grant. Adding a new type here won't re-prompt; older
    /// grants stay in effect.
    static func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            log.error("HealthKit not available on this device")
            return
        }
        let writeTypes: Set<HKSampleType> = [
            HKCategoryType(.sleepAnalysis),
        ]
        let readTypes: Set<HKObjectType> = [
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.heartRate),
        ]
        try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        authorized = true
        log.info("HealthKit authorization granted (or already granted)")
    }

    /// Fetch heart-rate samples over `[from, to]` and reduce to one
    /// value per UTC minute (mean of all samples that started in that
    /// minute). Returns `[:]` if HealthKit isn't available or the user
    /// hasn't granted read access — callers should treat that as "no
    /// HR signal for this night" and let the model fall back to its
    /// CPAP-only path.
    ///
    /// Keys are `Date` values snapped to the minute boundary (seconds
    /// and sub-seconds zeroed) so the caller can line them up with
    /// per-minute CPAP telemetry using exact equality.
    static func fetchHeartRatePerMinute(from: Date, to: Date) async -> [Date: Double] {
        if !authorized {
            do { try await requestAuthorization() } catch { return [:] }
        }
        let hrType = HKQuantityType(.heartRate)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let predicate = HKQuery.predicateForSamples(
            withStart: from, end: to,
            options: [.strictStartDate, .strictEndDate]
        )
        let samples: [HKQuantitySample]
        do {
            samples = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: hrType, predicate: predicate,
                    limit: HKObjectQueryNoLimit, sortDescriptors: nil
                ) { _, result, error in
                    if let error = error {
                        continuation.resume(throwing: error); return
                    }
                    continuation.resume(returning: (result as? [HKQuantitySample]) ?? [])
                }
                store.execute(query)
            }
        } catch {
            log.error("HR fetch failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        var sums: [Date: (sum: Double, n: Int)] = [:]
        for s in samples {
            let bucket = Date(timeIntervalSince1970:
                (s.startDate.timeIntervalSince1970 / 60.0).rounded(.down) * 60.0)
            let value = s.quantity.doubleValue(for: bpm)
            let prev = sums[bucket] ?? (0, 0)
            sums[bucket] = (prev.sum + value, prev.n + 1)
        }
        let perMinute = sums.mapValues { $0.sum / Double($0.n) }

        // Forward-fill small gaps. Apple Watch in sleep mode samples HR
        // roughly every 3–5 minutes, so a continuously-worn watch
        // produces per-minute coverage of ~20–30% without interpolation.
        // HR moves slowly during stable sleep; carrying the most recent
        // reading forward a few minutes is a safe approximation. Larger
        // gaps (watch off, session outside wearable window) stay nil so
        // the runtime can still detect "no HR at all for this stretch"
        // and fall back to 3-class output.
        return forwardFill(perMinute, fromStart: from, toEnd: to, maxCarryMinutes: 5)
    }

    /// Fetch existing sleep-analysis samples from HealthKit over a
    /// window and return them keyed by UTC-minute. Samples authored by
    /// OpenRM itself are filtered out so re-syncing doesn't cause us
    /// to override our own predictions with our own older predictions.
    ///
    /// Apple's stage values map to our enum:
    ///     .awake              → .awake
    ///     .asleepCore         → .light
    ///     .asleepDeep         → .deep
    ///     .asleepREM          → .rem
    ///     .asleepUnspecified  → .light  (generic "asleep" fallback)
    ///     .inBed              → skipped (not a stage)
    static func fetchExternalSleepStagesPerMinute(
        from: Date, to: Date
    ) async -> [Date: SleepStage] {
        if !authorized {
            do { try await requestAuthorization() } catch { return [:] }
        }
        let sleepType = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(
            withStart: from, end: to,
            options: [.strictStartDate, .strictEndDate]
        )
        let samples: [HKCategorySample]
        do {
            samples = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: sleepType, predicate: predicate,
                    limit: HKObjectQueryNoLimit, sortDescriptors: nil
                ) { _, result, error in
                    if let error = error {
                        continuation.resume(throwing: error); return
                    }
                    continuation.resume(returning: (result as? [HKCategorySample]) ?? [])
                }
                store.execute(query)
            }
        } catch {
            log.error("sleep-stage fetch failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        var out: [Date: SleepStage] = [:]
        for s in samples {
            if s.metadata?[openrmSyncIDKey] is String { continue }   // our own write
            guard let stage = appleSleepValueToStage(s.value) else { continue }
            // Expand the sample over its minute range. HK samples have
            // arbitrary minute-crossing boundaries; we snap to minute
            // buckets. If two sources conflict on the same minute,
            // whichever we iterate last wins — samples are typically
            // non-overlapping per source, and cross-source collision
            // is rare on a real device.
            let startBucket = s.startDate.floorToMinute()
            let endBucket = s.endDate.floorToMinute()
            var cursor = startBucket
            while cursor <= endBucket {
                out[cursor] = stage
                cursor = cursor.addingTimeInterval(60)
            }
        }
        return out
    }

    /// Sum of non-awake sleep-sample durations we've written to
    /// HealthKit (filtered by the openrm-sync-id metadata key, so
    /// this counts just our own classifier output and doesn't
    /// double-count samples other apps may have written). Used by
    /// the dashboard for a "TOTAL ASLEEP" metric that sits next to
    /// LIFETIME USE — lifetime mask-on minus lifetime awake-on-mask.
    ///
    /// Returns seconds. Zero if no samples qualify or HealthKit
    /// read access is denied.
    static func fetchLifetimeTimeAsleepSeconds() async -> Int {
        if !authorized {
            do { try await requestAuthorization() } catch { return 0 }
        }
        let sleepType = HKCategoryType(.sleepAnalysis)
        // Wide net — we don't know the earliest CPAP session date,
        // and iOS doesn't charge for scanning an empty time range.
        let fiveYearsAgo = Date().addingTimeInterval(-5 * 365 * 86400)
        let predicate = HKQuery.predicateForSamples(
            withStart: fiveYearsAgo, end: Date(), options: []
        )
        let samples: [HKCategorySample]
        do {
            samples = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: sleepType, predicate: predicate,
                    limit: HKObjectQueryNoLimit, sortDescriptors: nil
                ) { _, result, error in
                    if let error = error {
                        continuation.resume(throwing: error); return
                    }
                    continuation.resume(returning: (result as? [HKCategorySample]) ?? [])
                }
                store.execute(query)
            }
        } catch {
            log.error("lifetime-asleep fetch failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        let awake = HKCategoryValueSleepAnalysis.awake.rawValue
        var total: TimeInterval = 0
        for s in samples {
            // Only our own writes
            guard s.metadata?[openrmSyncIDKey] is String else { continue }
            if s.value == awake { continue }
            total += s.endDate.timeIntervalSince(s.startDate)
        }
        return Int(total)
    }

    private static func appleSleepValueToStage(_ raw: Int) -> SleepStage? {
        switch raw {
        case HKCategoryValueSleepAnalysis.awake.rawValue:             return .awake
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:        return .light
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:        return .deep
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:         return .rem
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: return .light
        default: return nil   // .inBed and unknown values fall through
        }
    }

    private static func forwardFill(
        _ hr: [Date: Double],
        fromStart: Date,
        toEnd: Date,
        maxCarryMinutes: Int
    ) -> [Date: Double] {
        guard !hr.isEmpty else { return hr }
        let firstBucket = Date(timeIntervalSince1970:
            (fromStart.timeIntervalSince1970 / 60.0).rounded(.down) * 60.0)
        let lastBucket = Date(timeIntervalSince1970:
            (toEnd.timeIntervalSince1970 / 60.0).rounded(.down) * 60.0)
        guard firstBucket <= lastBucket else { return hr }

        var out = hr
        var lastSeen: (minute: Date, value: Double)?
        var cursor = firstBucket
        while cursor <= lastBucket {
            if let v = out[cursor] {
                lastSeen = (cursor, v)
            } else if let seen = lastSeen,
                      Int(cursor.timeIntervalSince(seen.minute) / 60) <= maxCarryMinutes {
                out[cursor] = seen.value
            }
            cursor = cursor.addingTimeInterval(60)
        }
        return out
    }

    // MARK: - Stage-block sync

    /// One per-minute-model-output run: one stage, start, end.
    struct StageRun {
        let stage: SleepStage
        let startDate: Date
        let endDate: Date
    }

    /// Map one of our stages to Apple's sleep-analysis category value.
    /// iOS 16+ introduced the stage-specific values; earlier iOS would
    /// only support `.asleep` / `.inBed` / `.awake`. The app deployment
    /// target is iOS 16 so we assume the modern enum throughout.
    private static func categoryValue(for stage: SleepStage) -> Int {
        switch stage {
        case .awake: return HKCategoryValueSleepAnalysis.awake.rawValue
        case .light: return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case .deep:  return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        case .rem:   return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        }
    }

    /// Write per-stage HKCategorySample entries for one therapy
    /// session, one sample per run of consecutive same-stage minutes.
    /// Dedup key extends the session-level scheme:
    ///     openrm-sess-<rawMs>-stage-<startEpochSeconds>-<stage>
    /// so re-running the classifier on the same session won't
    /// double-insert.
    ///
    /// `rawStartMs` should be the session's raw CPAP timestamp
    /// (DaySummary.Session.rawStartMs) so the key stays stable even
    /// if the CPAP clock drifts between syncs.
    @discardableResult
    static func syncStageRuns(
        rawStartMs: UInt64,
        runs: [StageRun]
    ) async throws -> (inserted: Int, duplicates: Int) {
        if !authorized {
            try await requestAuthorization()
        }
        guard !runs.isEmpty else { return (0, 0) }
        let existingIds = try await existingOpenRMSyncIds()

        var toInsert: [HKCategorySample] = []
        var duplicates = 0
        for run in runs {
            let syncId = makeStageRunSyncId(rawStartMs: rawStartMs, run: run)
            if existingIds.contains(syncId) {
                duplicates += 1
                continue
            }
            let metadata: [String: Any] = [
                openrmSyncIDKey: syncId,
                HKMetadataKeyExternalUUID: syncId,
                HKMetadataKeyWasUserEntered: false,
            ]
            let sample = HKCategorySample(
                type: HKCategoryType(.sleepAnalysis),
                value: categoryValue(for: run.stage),
                start: run.startDate,
                end: run.endDate,
                metadata: metadata
            )
            toInsert.append(sample)
        }
        if !toInsert.isEmpty {
            try await store.save(toInsert)
            log.info("HealthKit: inserted \(toInsert.count) stage run(s)")
        }
        return (toInsert.count, duplicates)
    }

    private static func makeStageRunSyncId(
        rawStartMs: UInt64, run: StageRun
    ) -> String {
        let startEpoch = Int(run.startDate.timeIntervalSince1970)
        return "openrm-sess-\(rawStartMs)-stage-\(startEpoch)-\(run.stage.rawValue)"
    }

    /// Push a batch of `DaySummary`s into HealthKit as sleep samples,
    /// one sample per real therapy session. Sessions shorter than
    /// `minSessionMinutes` are treated as pressure-test / mask-fit
    /// blips and skipped. Duplicates are detected by the
    /// `openrmSyncIDKey` metadata — if a matching sample already
    /// exists from a previous run, we leave it alone.
    ///
    /// Returns (inserted, skippedAsDuplicates, skippedAsTooShort).
    @discardableResult
    static func sync(_ days: [DaySummary],
                     minSessionMinutes: Int = 5) async throws -> (inserted: Int, duplicates: Int, tooShort: Int) {
        if !authorized {
            try await requestAuthorization()
        }

        // Query existing openrm-tagged samples so we don't insert twice.
        let existingSyncIds = try await existingOpenRMSyncIds()

        var inserted = 0, duplicates = 0, tooShort = 0
        var toInsert: [HKCategorySample] = []

        for day in days {
            for session in day.sessions {
                guard session.durationMinutes >= minSessionMinutes else {
                    tooShort += 1
                    continue
                }
                let syncId = makeSessionSyncId(session: session)
                if existingSyncIds.contains(syncId) {
                    duplicates += 1
                    continue
                }
                toInsert.append(makeSleepSample(session: session, syncId: syncId))
                inserted += 1
            }
        }

        if !toInsert.isEmpty {
            try await store.save(toInsert)
            log.info("HealthKit: inserted \(toInsert.count) session sample(s)")
        }
        log.info("HealthKit sync: \(inserted) new, \(duplicates) dupes, \(tooShort) skipped (too short)")
        return (inserted, duplicates, tooShort)
    }

    /// Delete all legacy `openrm-day-*` sleep samples written by the
    /// earlier version of this module (one fabricated 9-hour block
    /// per night with a fake 07:00 wake time). Call once per sync —
    /// it's a no-op after the first successful cleanup.
    @discardableResult
    static func cleanupLegacySamples() async throws -> Int {
        let oneYearAgo = Date().addingTimeInterval(-365 * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: oneYearAgo, end: Date(), options: [])
        let sleepType = HKCategoryType(.sleepAnalysis)

        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }

        let toDelete = samples.filter {
            guard let id = $0.metadata?[openrmSyncIDKey] as? String else { return false }
            return id.hasPrefix("openrm-day-")
        }
        guard !toDelete.isEmpty else { return 0 }

        try await store.delete(toDelete)
        log.info("HealthKit cleanup: deleted \(toDelete.count) legacy day sample(s)")
        return toDelete.count
    }

    // MARK: - Private helpers

    /// Stable ID string for one therapy session. Uses the **raw**
    /// millisecond timestamp as stored by the CPAP — NOT the corrected
    /// `startDate`. This matters when the user travels timezones or
    /// when the CPAP's clock drift changes between runs: the raw value
    /// stays identical across resyncs even if the display date shifts,
    /// so dedup keeps working.
    private static func makeSessionSyncId(session: DaySummary.Session) -> String {
        return "openrm-sess-\(session.rawStartMs)"
    }

    /// Build one HKCategorySample representing a single therapy
    /// session with real start/end times from the spool data.
    private static func makeSleepSample(session: DaySummary.Session, syncId: String) -> HKCategorySample {
        let metadata: [String: Any] = [
            openrmSyncIDKey: syncId,
            HKMetadataKeyExternalUUID: syncId,
            HKMetadataKeyWasUserEntered: false,
        ]
        return HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            start: session.startDate,
            end: session.endDate,
            metadata: metadata
        )
    }

    /// Fetch the set of `openrmSyncId` values already stored in
    /// HealthKit so we can skip duplicates. Looks back 365 days.
    private static func existingOpenRMSyncIds() async throws -> Set<String> {
        let now = Date()
        let oneYearAgo = now.addingTimeInterval(-365 * 86400)
        let predicate = HKQuery.predicateForSamples(
            withStart: oneYearAgo,
            end: now,
            options: []
        )
        let sleepType = HKCategoryType(.sleepAnalysis)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                var ids: Set<String> = []
                for s in samples ?? [] {
                    if let id = s.metadata?[openrmSyncIDKey] as? String {
                        ids.insert(id)
                    }
                }
                continuation.resume(returning: ids)
            }
            store.execute(query)
        }
    }
}

#else

// Native macOS stub — just provides the call site so `CPAPController`
// doesn't need its own `#if` guards. All methods are no-ops that log.
import Foundation
import os

private let log = Logger(subsystem: "com.openrm.cpap", category: "HealthKitSync")

@MainActor
enum HealthKitSync {
    struct StageRun {
        let stage: SleepStage
        let startDate: Date
        let endDate: Date
    }

    static var authorized: Bool { false }
    static func requestAuthorization() async throws {
        log.info("HealthKit unavailable on native macOS — skipping authorization")
    }
    static func fetchExternalSleepStagesPerMinute(
        from: Date, to: Date
    ) async -> [Date: SleepStage] { [:] }
    static func fetchLifetimeTimeAsleepSeconds() async -> Int { 0 }
    @discardableResult
    static func sync(_ days: [DaySummary],
                     minSessionMinutes: Int = 5) async throws -> (inserted: Int, duplicates: Int, tooShort: Int) {
        log.info("HealthKit unavailable on native macOS — skipping sync of \(days.count) day(s)")
        return (0, 0, 0)
    }
    @discardableResult
    static func cleanupLegacySamples() async throws -> Int { 0 }
    static func fetchHeartRatePerMinute(from: Date, to: Date) async -> [Date: Double] {
        [:]
    }
    @discardableResult
    static func syncStageRuns(
        rawStartMs: UInt64, runs: [StageRun]
    ) async throws -> (inserted: Int, duplicates: Int) {
        log.info("HealthKit unavailable on native macOS — skipping stage runs sync")
        return (0, 0)
    }
}

#endif
