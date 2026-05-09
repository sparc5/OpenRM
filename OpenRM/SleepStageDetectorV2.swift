//
//  SleepStageDetectorV2.swift
//  OpenRM
//
//  4-class sleep-stage classifier (Awake / Light / Deep / REM) using
//  the TCN model trained in `ml/train.py` and shipped as
//  `SleepModel.mlpackage` in the app bundle. Applies Viterbi smoothing
//  on top of per-minute softmax using the transition priors in
//  `transitions.json`.
//
//  Deploy-time CV performance on 77 Samsung-labeled CPAP nights:
//    accuracy  0.752
//    macro F1  0.645
//    per-class F1: Awake 0.46  Light 0.82  Deep 0.54  REM 0.76
//    ±3 min tolerance 0.87
//
//  Compared to the shipping 3-class `BLE3ClassClassifier` (v5,
//  HistGradientBoosting, 0.72 exact-match 3-class): this model
//  distinguishes 4 stages at the same or better accuracy, with
//  substantially better Awake detection driven by HealthKit HR input.
//  `BLE3ClassClassifier` is kept alongside for fallback/comparison
//  until this runtime is validated on held-out nights.
//
//  Usage:
//      let minutes: [SleepFeatureBuilder.MinuteInput] = ...
//      let stages = SleepStageDetectorV2.shared?.predict(minutes: minutes)
//
//  `minutes` is built from the BLE per-minute spool + HealthKit HR
//  samples aligned at the same 1-minute cadence. HR is optional per
//  minute; absent HR sets `hk_available=0` for that minute and the
//  model falls back to CPAP-only inference for it.
//

import Foundation
import CoreML
import os

private let sleepLog = Logger(subsystem: "com.openrm.cpap", category: "SleepStageV2")

final class SleepStageDetectorV2 {

    /// Lazily-loaded shared instance. Returns nil if the bundle
    /// doesn't contain the model or transitions — the caller should
    /// fall back to the v1 3-class classifier in that case.
    static let shared: SleepStageDetectorV2? = {
        do {
            return try SleepStageDetectorV2()
        } catch {
            sleepLog.error("v2 model unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    private let model: MLModel
    private let stages: [SleepStage]
    private let logTransition: [[Double]]

    enum LoadError: Error, LocalizedError {
        case modelMissing
        case transitionsMissing
        case stageMismatch(expected: [String], got: [String])

        var errorDescription: String? {
            switch self {
            case .modelMissing:       return "SleepModel.mlpackage not in bundle"
            case .transitionsMissing: return "transitions.json not in bundle"
            case .stageMismatch(let e, let g):
                return "transition stages \(g) don't match expected \(e)"
            }
        }
    }

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "SleepModel",
                                              withExtension: "mlpackage")
            ?? Bundle.main.url(forResource: "SleepModel", withExtension: "mlmodelc")
        else { throw LoadError.modelMissing }

        let config = MLModelConfiguration()
        // `.all` tries GPU, which fails hard on Macs / simulators whose
        // GPU lacks MTLResidencySet support — Core ML aborts with
        // "device does not support residency sets". Staying off the GPU
        // costs nothing for a 130K-param TCN: ANE handles it in <10 ms
        // on iPad, CPU in ~50 ms on a Mac. Both are fine for an
        // overnight-stage pipeline.
        config.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: modelURL, configuration: config)

        guard let transURL = Bundle.main.url(forResource: "transitions",
                                               withExtension: "json")
        else { throw LoadError.transitionsMissing }

        let (stageNames, logTrans) = try SleepViterbi.loadTransitions(from: transURL)
        let expectedStages = SleepStage.allCases.map(\.rawValue)
        guard stageNames == expectedStages else {
            throw LoadError.stageMismatch(expected: expectedStages, got: stageNames)
        }
        self.stages = stageNames.compactMap { SleepStage(rawValue: $0) }
        self.logTransition = logTrans
        sleepLog.info("SleepStageDetectorV2 loaded: \(stageNames.count) classes, TCN ready")
    }

    // MARK: - Public API

    /// Run the full pipeline: engineer features → Core ML softmax →
    /// Viterbi smooth → stage labels. Returns one stage per input
    /// minute, or an empty array on failure (check the log for detail).
    func predict(minutes: [SleepFeatureBuilder.MinuteInput]) -> [SleepStage] {
        guard !minutes.isEmpty else { return [] }
        do {
            let features = try SleepFeatureBuilder.build(from: minutes)
            let softmax = try runModel(features: features)
            let logProbs = makeLogProbs(softmax: softmax, T: minutes.count)
            let path = SleepViterbi.decode(logEmission: logProbs, logTransition: logTransition)
            return path.map { stages[$0] }
        } catch {
            sleepLog.error("predict failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Minimum session length accepted by the current Core ML model.
    /// Must match the `lower_bound` set in `ml/export.py` when the
    /// mlpackage was built — Core ML rejects inputs shorter than this
    /// with an MLFeatureTypeMultiArray constraint error. Sessions
    /// shorter than this get `nil` back from `predict(perMinute:...)`
    /// so the caller can fall through to the template.
    static let minimumSessionMinutes = 30

    /// Fraction of a session's minutes that must have HealthKit HR data
    /// for the model's Light/Deep distinction to be trusted. Below
    /// this, the classifier performs near the CPAP-only ceiling where
    /// Light and Deep aren't separable — so we collapse Deep → Light,
    /// producing an effective 3-class output (Awake / Light / REM).
    ///
    /// 0.90 is strict by design: any non-trivial HR gap collapses the
    /// whole session to 3-class, matching the product rule "only show
    /// 4 stages when we actually trust all 4." HealthKit HR is
    /// forward-filled up to 5 minutes in the sync layer, so a
    /// continuously-worn Apple Watch clears this bar easily; a watch
    /// that came off in the middle of the night does not.
    static let minimumHRCoverage = 0.90

    /// Adapt a `PerMinuteSession` + per-minute HR dictionary into the
    /// `MinuteInput` form the model expects, then classify.
    ///
    /// Channel padding: any channel shorter than RR is extended with
    /// its last known value (avoids rolling-std artifacts that zero-
    /// padding would cause). Missing channels contribute 0.
    ///
    /// Coverage at runtime is binary per minute — the BLE per-minute
    /// spool emits one value per minute, so within-minute mask-off
    /// gaps aren't observable. We set coverage=1 for minutes where
    /// both rr>0 and mp>0, else 0. Matches the Python loader's rule.
    func predict(
        perMinute: PerMinuteSession,
        heartRate hrByMinute: [Date: Double]
    ) -> [SleepStage] {
        let inputs = Self.buildMinuteInputs(
            perMinute: perMinute, heartRate: hrByMinute
        )
        guard inputs.count >= Self.minimumSessionMinutes else {
            sleepLog.info(
                "skipping session: \(inputs.count) min < minimum \(Self.minimumSessionMinutes)"
            )
            return []
        }
        let raw = predict(minutes: inputs)
        let hrCollapsed = Self.collapseIfLowHRCoverage(stages: raw, minutes: inputs)
        // Settle-in pass runs before the external-sleep override (in
        // the caller) so Apple HealthKit retains final say when it
        // has actigraphy-based stage data for the same minutes. If
        // Apple says asleep in the first hour we respect that; if
        // Apple has nothing, the settle-in pass catches the
        // sleep-onset oscillation pattern and calls it Awake.
        return Self.collapseSleepOnsetAndOffset(stages: hrCollapsed)
    }

    /// Minimum continuous non-Awake block length (minutes) required to
    /// call the user "asleep" at the start or end of a session. Until
    /// this threshold is met, Light/Deep/REM predictions at the edges
    /// get rewritten to Awake — this catches the sleep-onset latency
    /// pattern (user lying in bed with the mask on, drifting in and
    /// out of micro-sleep) that the frame-level model calls as
    /// oscillating Awake/Light.
    ///
    /// 30 minutes is deliberately strict: on real data the TCN emits
    /// 10-to-15-minute Light bouts during the onset-latency window
    /// that a 10-min threshold would wrongly accept as "settled
    /// sleep." A user going to bed with a CPAP mask isn't
    /// power-napping, so discarding sub-30-min sleep runs at the
    /// session edges is safer than accepting them. Moving threshold
    /// from 10 → 30 fixed the screenshot case where an hour of
    /// pre-sleep oscillation showed up as alternating Light / Awake.
    static let persistentSleepMinutes = 30

    /// Collapse sleep-onset and sleep-offset oscillations into Awake.
    ///
    /// When someone puts the mask on and settles in, or wakes up and
    /// lies in bed for a few minutes before taking it off, the TCN
    /// sees mildly-regular breathing + mask pressure holding steady
    /// and calls it Light. Viterbi smooths single-minute flips but
    /// not minute-scale oscillations. Apple Health's actigraphy
    /// handles this correctly — it watches motion and sees the user
    /// is awake — so in sessions where Apple HealthKit has stage data
    /// the external-sleep override below will do the job. This pass
    /// is the fallback for sessions without external stage data:
    /// anything before the first persistent-sleep run, and anything
    /// after the last, becomes Awake.
    static func collapseSleepOnsetAndOffset(
        stages: [SleepStage],
        persistentMinutes: Int = persistentSleepMinutes
    ) -> [SleepStage] {
        guard stages.count >= persistentMinutes else { return stages }

        // Find every run of consecutive non-Awake minutes at or above
        // the persistent-sleep threshold. First such run's start is
        // the sleep-onset boundary; last such run's end is the
        // sleep-offset boundary. Everything outside those is Awake.
        var persistentRuns: [(start: Int, end: Int)] = []
        var i = 0
        while i < stages.count {
            if stages[i] != .awake {
                let runStart = i
                while i < stages.count && stages[i] != .awake { i += 1 }
                let runEnd = i - 1
                if runEnd - runStart + 1 >= persistentMinutes {
                    persistentRuns.append((runStart, runEnd))
                }
            } else {
                i += 1
            }
        }

        guard let first = persistentRuns.first,
              let last = persistentRuns.last else {
            // No persistent sleep anywhere — user wore the mask awake
            // for the whole session (test-run, insomnia, or just never
            // fell asleep).
            sleepLog.info("settle-in: no persistent sleep in \(stages.count)-min session → all Awake")
            return Array(repeating: .awake, count: stages.count)
        }

        guard first.start > 0 || last.end < stages.count - 1 else {
            return stages   // already clean — no edges to trim
        }

        var out = stages
        for k in 0..<first.start { out[k] = .awake }
        for k in (last.end + 1)..<stages.count { out[k] = .awake }
        let rewrote = first.start + (stages.count - 1 - last.end)
        if rewrote > 0 {
            let onset = first.start
            let offset = stages.count - 1 - last.end
            sleepLog.info("settle-in: rewrote \(rewrote) edge minute(s) (onset: \(onset) min, offset: \(offset) min)")
        }
        return out
    }

    /// Override per-minute Awake predictions with an external (Apple
    /// HealthKit / watch-sourced) sleep stage when one exists for that
    /// minute. Rationale: when the CPAP mask slips off or seal breaks,
    /// the airway signal spikes and coverage drops, both of which our
    /// model treats as wake cues. But the user's Apple Watch reads HR,
    /// HRV, and actigraphy and is a more direct measure of "awake vs
    /// asleep" — so if Apple says the user was asleep during that
    /// minute, we trust Apple and map our Awake to whichever specific
    /// stage Apple recorded (or Light as a fallback for asleepUnspecified).
    ///
    /// Only .awake predictions are candidates for override. All other
    /// stages (Light/Deep/REM) pass through untouched — Apple's and
    /// our CPAP-based model can legitimately disagree on those and we
    /// let our CPAP-informed answer stand.
    static func overrideWakeWithExternalSleep(
        stages: [SleepStage],
        minutes: [SleepFeatureBuilder.MinuteInput],
        externalStages: [Date: SleepStage]
    ) -> [SleepStage] {
        guard !externalStages.isEmpty, stages.count == minutes.count else {
            return stages
        }
        var out = stages
        var overridden = 0
        for i in 0..<stages.count {
            guard stages[i] == .awake else { continue }
            let bucket = Date(timeIntervalSince1970:
                (minutes[i].timestampMinuteUTC.timeIntervalSince1970 / 60.0).rounded(.down) * 60.0)
            if let ext = externalStages[bucket], ext != .awake {
                out[i] = ext
                overridden += 1
            }
        }
        if overridden > 0 {
            sleepLog.info("external sleep override: \(overridden) Awake → sleep minute(s)")
        }
        return out
    }

    /// If fewer than `minimumHRCoverage` of the input minutes carried a
    /// HealthKit HR reading, map Deep → Light in the output sequence.
    /// The model's Light/Deep separation is HR-driven; without HR,
    /// emitting confident Deep blocks misleads the user into thinking
    /// we can distinguish stages we can't. The result is effectively
    /// a 3-class output (Awake / Light / REM). Users with an Apple
    /// Watch or other HR source get the full 4-class split.
    static func collapseIfLowHRCoverage(
        stages: [SleepStage],
        minutes: [SleepFeatureBuilder.MinuteInput]
    ) -> [SleepStage] {
        guard !stages.isEmpty, stages.count == minutes.count else { return stages }
        let covered = minutes.reduce(0) { $0 + ($1.hr != nil ? 1 : 0) }
        let coverage = Double(covered) / Double(minutes.count)
        if coverage >= minimumHRCoverage { return stages }
        sleepLog.info(
            "HR coverage \(String(format: "%.0f%%", coverage * 100)) below \(String(format: "%.0f%%", minimumHRCoverage * 100)) — collapsing Deep → Light"
        )
        return stages.map { $0 == .deep ? .light : $0 }
    }

    /// Public for tests + callers that want to inspect the assembled
    /// inputs without running the model.
    static func buildMinuteInputs(
        perMinute: PerMinuteSession,
        heartRate hrByMinute: [Date: Double]
    ) -> [SleepFeatureBuilder.MinuteInput] {
        func values(_ kind: PerMinuteChannel.Kind) -> [Double] {
            perMinute.channel(field: kind.rawValue)?.physicalValues ?? []
        }
        let rr    = values(.respRate)
        let tv    = values(.tidalVolume)
        let mv    = values(.minuteVent)
        let mp    = values(.maskPressure)
        let setP  = values(.setPressure)
        let leak  = values(.leak)
        let n = rr.count
        guard n > 0 else { return [] }

        @inline(__always) func pad(_ a: [Double]) -> [Double] {
            if a.count >= n { return Array(a.prefix(n)) }
            let fill = a.last ?? 0
            return a + Array(repeating: fill, count: n - a.count)
        }
        let tvP = pad(tv), mvP = pad(mv), mpP = pad(mp), setPP = pad(setP), leakP = pad(leak)

        var out: [SleepFeatureBuilder.MinuteInput] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let minute = perMinute.startDate.addingTimeInterval(Double(i) * 60)
            let bucket = Date(timeIntervalSince1970:
                (minute.timeIntervalSince1970 / 60.0).rounded(.down) * 60.0)
            let coverage: Double = (rr[i] > 0 && mpP[i] > 0) ? 1.0 : 0.0
            out.append(.init(
                timestampMinuteUTC: minute,
                rr: rr[i], tv: tvP[i], mv: mvP[i],
                mp: mpP[i], setP: setPP[i], leak: leakP[i],
                coverage: coverage,
                hr: hrByMinute[bucket]
            ))
        }
        return out
    }

    // MARK: - Run grouping (for HealthKit export)

    /// Group a per-minute stage sequence into (stage, start, end) runs.
    /// One entry per contiguous same-stage block — suitable for
    /// writing to HealthKit as one HKCategorySample per run.
    static func runs(
        stages: [SleepStage], startDate: Date
    ) -> [(stage: SleepStage, startDate: Date, endDate: Date)] {
        guard !stages.isEmpty else { return [] }
        var out: [(SleepStage, Date, Date)] = []
        var runStart = 0
        for i in 1...stages.count {
            if i == stages.count || stages[i] != stages[runStart] {
                let s = startDate.addingTimeInterval(Double(runStart) * 60)
                let e = startDate.addingTimeInterval(Double(i) * 60)
                out.append((stages[runStart], s, e))
                runStart = i
            }
        }
        return out
    }

    // MARK: - Inference plumbing

    /// Run the Core ML model and return the softmax multiarray of
    /// shape (1, T, C).
    private func runModel(features: MLMultiArray) throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["features": MLFeatureValue(multiArray: features)]
        )
        let out = try model.prediction(from: provider)
        guard let probs = out.featureValue(for: "stage_probs")?.multiArrayValue else {
            throw NSError(
                domain: "SleepStageDetectorV2", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "stage_probs output missing"]
            )
        }
        return probs
    }

    /// Unpack the (1, T, C) softmax into a [T][C] log-prob matrix for
    /// Viterbi. Softmax may contain zeros from numerical rounding; we
    /// add a tiny floor before log.
    private func makeLogProbs(softmax: MLMultiArray, T: Int) -> [[Double]] {
        let C = stages.count
        let ptr = softmax.dataPointer.assumingMemoryBound(to: Float32.self)
        var out = Array(repeating: Array(repeating: 0.0, count: C), count: T)
        for t in 0..<T {
            for c in 0..<C {
                let v = Double(ptr[t * C + c])
                out[t][c] = Foundation.log(max(v, 1e-9))
            }
        }
        return out
    }
}
