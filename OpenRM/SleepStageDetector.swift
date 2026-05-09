//
//  SleepStageDetector.swift
//  OpenRM
//
//  Classifies per-minute CPAP telemetry into sleep stages (Awake/Light/Deep/REM)
//  using cascading threshold rules derived from 14,169 validated minutes across
//  42 nights (Samsung Health vs CPAP PLD.edf cross-reference).
//
//  Feature averages per stage (from validation):
//
//                            Awake     Light      Deep       REM
//  RespRate                 16.09     15.91     16.17     17.52
//  RespRate_std              1.48      1.05      0.83      1.88
//  TidVol                    0.393     0.378     0.366     0.359
//  TidVol_std                0.059     0.039     0.028     0.048
//  MinVent_std               0.878     0.604     0.428     0.613
//  MaskPress                 6.70      6.41      6.18      7.00
//  MaskPress_std             0.052     0.039     0.027     0.055
//

import SwiftUI

/// Sleep stage classification from CPAP telemetry signals.
enum SleepStage: String, CaseIterable {
    case awake = "Awake"
    case light = "Light"
    case deep  = "Deep"
    case rem   = "REM"

    /// Display color for each stage.
    var color: Color {
        switch self {
        case .awake: return .red
        case .light: return .orange
        case .deep:  return .blue
        case .rem:   return .purple
        }
    }
}

/// Per-minute classifier and summary-level distribution estimator for
/// CPAP-derived sleep stages.
enum SleepStageDetector {

    /// One minute of CPAP telemetry features.
    ///
    /// From SD-card PLD.edf we got *within-minute* std dev (variance of
    /// 2-second samples aggregated into one minute). From the BLE per-
    /// minute spool we only have one value per minute, so the `std`
    /// fields here are computed as a **rolling cross-minute std** over
    /// a 5-minute centered window. It's a different metric (short-term
    /// drift vs within-minute breath variability) but the sleep-stage
    /// ranking preserves — stable → deep, variable → REM/awake.
    struct MinuteFeatures {
        let respRate: Double        // breaths/min
        let respRateStd: Double     // rolling std over ±2 min window
        let tidVol: Double          // liters
        let tidVolStd: Double       // rolling std
        let maskPress: Double       // cmH2O
        let maskPressStd: Double    // rolling std
        /// Unintentional leak in L/s. Optional — not all inputs carry it.
        /// High leak → high-specificity wake signal; low leak is
        /// non-informative (users can be awake with a stable mask).
        let leak: Double?
    }

    // MARK: - Per-minute classification

    /// Classify a single minute of telemetry into a sleep stage using
    /// cascading threshold rules ranked by discriminator F-score.
    ///
    /// Decision order:
    /// 0. Hard-wake:  Leak > 0.6 L/s (≈36 L/min) — mask adjustment, very
    ///                likely awake. Low leak is NOT counted as evidence of
    ///                sleep; see feedback_openrm_staging_clinical_nuance.
    /// 1. REM:   RespRate > 16.8 AND RespRate_std > 1.5
    /// 2. Deep:  MaskPress_std < 0.030 AND RespRate_std < 0.95
    /// 3. Awake: TidVol_std > 0.048 OR (RespRate_std > 1.2 AND MaskPress > 6.5)
    /// 4. Default: Light
    nonisolated static func classify(_ f: MinuteFeatures) -> SleepStage {
        // 0. Leak-spike wake — one-way gate. High leak is high-specificity
        //    for wake (mask adjustment / repositioning). Low leak is
        //    NOT used to infer sleep because users can be awake in bed
        //    with a stable mask for long stretches.
        if let leak = f.leak, leak > 0.6 {
            return .awake
        }

        // 1. REM — fastest respiration with highest variability
        if f.respRate > 16.8 && f.respRateStd > 1.5 {
            return .rem
        }

        // 2. Deep — very stable pressure and breathing rhythm
        if f.maskPressStd < 0.030 && f.respRateStd < 0.95 {
            return .deep
        }

        // 3. Awake — erratic tidal volume or variable breathing with elevated pressure
        if f.tidVolStd > 0.048 || (f.respRateStd > 1.2 && f.maskPress > 6.5) {
            return .awake
        }

        // 4. Light — everything else
        return .light
    }

    // MARK: - Per-minute classification from BLE telemetry

    /// Build a per-minute feature series from decoded BLE channels.
    /// Uses a centered rolling-std window of `window` minutes (default 5).
    /// Missing values at the head/tail of the series fall back to the
    /// in-range std on a truncated window.
    static func buildFeatures(
        respRate: [Double],
        tidVol: [Double],
        maskPress: [Double],
        leak: [Double]? = nil,
        window: Int = 5
    ) -> [MinuteFeatures] {
        let n = min(respRate.count, min(tidVol.count, maskPress.count))
        guard n > 0 else { return [] }
        let half = max(1, window / 2)
        var out: [MinuteFeatures] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            out.append(MinuteFeatures(
                respRate:     respRate[i],
                respRateStd:  rollingStd(respRate, lo: lo, hi: hi),
                tidVol:       tidVol[i],
                tidVolStd:    rollingStd(tidVol, lo: lo, hi: hi),
                maskPress:    maskPress[i],
                maskPressStd: rollingStd(maskPress, lo: lo, hi: hi),
                leak:         leak.flatMap { i < $0.count ? $0[i] : nil }
            ))
        }
        return out
    }

    /// Classify an entire session, then apply a minimum-block-length
    /// smoother so 1-minute outliers don't fragment the timeline into
    /// noise. Blocks shorter than `minBlock` are merged into the
    /// dominant adjacent stage.
    static func classifySession(
        _ features: [MinuteFeatures],
        minBlock: Int = 3
    ) -> [SleepStage] {
        let raw = features.map(classify)
        return smooth(raw, minBlock: minBlock)
    }

    /// Group consecutive same-stage minutes into `(stage, length)` runs.
    /// Convenience for rendering — callers can skip this and do their
    /// own grouping if they want sub-minute resolution.
    static func runs(_ stages: [SleepStage]) -> [(stage: SleepStage, length: Int)] {
        var out: [(SleepStage, Int)] = []
        for s in stages {
            if let last = out.last, last.0 == s {
                out[out.count - 1].1 += 1
            } else {
                out.append((s, 1))
            }
        }
        return out
    }

    // MARK: - Internals

    private static func rollingStd(_ a: [Double], lo: Int, hi: Int) -> Double {
        let n = hi - lo
        guard n > 1 else { return 0 }
        var mean = 0.0
        for k in lo..<hi { mean += a[k] }
        mean /= Double(n)
        var sq = 0.0
        for k in lo..<hi { let d = a[k] - mean; sq += d * d }
        return (sq / Double(n - 1)).squareRoot()
    }

    /// Merge runs shorter than `minBlock` minutes into the surrounding
    /// dominant stage — prevents the timeline from flickering between
    /// stages on borderline boundaries.
    private static func smooth(_ stages: [SleepStage], minBlock: Int) -> [SleepStage] {
        guard stages.count >= minBlock * 2 else { return stages }
        var result = stages
        var i = 0
        while i < result.count {
            var j = i
            while j < result.count && result[j] == result[i] { j += 1 }
            let runLength = j - i
            if runLength < minBlock && i > 0 && j < result.count {
                // Flanked on both sides — steal whichever neighbour is longer.
                let prev = result[i - 1]
                let next = result[j]
                let chosen: SleepStage = {
                    // If both neighbours agree, easy.
                    if prev == next { return prev }
                    // Otherwise pick the neighbour with the longer run.
                    var pl = 0, pi = i - 1
                    while pi >= 0 && result[pi] == prev { pl += 1; pi -= 1 }
                    var nl = 0, ni = j
                    while ni < result.count && result[ni] == next { nl += 1; ni += 1 }
                    return pl >= nl ? prev : next
                }()
                for k in i..<j { result[k] = chosen }
            }
            i = j
        }
        return result
    }

    // MARK: - Summary-level distribution estimation

    /// Estimate stage distribution from Summary-level percentiles when
    /// per-minute PLD data is not available.
    ///
    /// Uses the spread between p50 and p95/max to infer how much time
    /// was spent in each stage. Wider respiratory rate spread implies
    /// more REM (which drives the rate up); narrow spread with low
    /// pressure implies more deep sleep.
    ///
    /// Returns a dictionary mapping each `SleepStage` to its estimated
    /// fraction of total sleep time (values sum to 1.0).
    static func estimateDistribution(
        respRateP50: Double,
        respRateP95: Double,
        maskPressP50: Double,
        maskPressMax: Double
    ) -> [SleepStage: Double] {
        // Spread metrics: wider spreads indicate more time in extreme stages.
        let rrSpread = respRateP95 - respRateP50   // typical 1.0 – 3.0
        let mpSpread = maskPressMax - maskPressP50  // typical 0.5 – 3.0

        // REM fraction: driven by respiratory rate spread.
        // At the validated average, REM respRate is 17.52 vs Light 15.91,
        // so a large p95-p50 gap means significant REM time.
        // Clamp to [0.05, 0.35] — physiological range for REM.
        let remRaw = (rrSpread - 0.5) / 4.0  // 0 at spread=0.5, 1 at spread=4.5
        let remFrac = min(0.35, max(0.05, remRaw * 0.30 + 0.05))

        // Deep fraction: inversely related to pressure spread (deep has
        // the lowest, most stable pressure) and directly related to low
        // median pressure. Clamp to [0.10, 0.30].
        let pressureStability = max(0, 2.0 - mpSpread) / 2.0  // 1 when spread=0, 0 when spread>=2
        let lowPressureBonus = max(0, 7.0 - maskPressP50) / 3.0  // higher when p50 is low
        let deepRaw = (pressureStability * 0.6 + lowPressureBonus * 0.4)
        let deepFrac = min(0.30, max(0.10, deepRaw * 0.20 + 0.10))

        // Awake fraction: higher when both spreads are large (erratic
        // signals). Typical healthy night: 5-15% awake. Clamp to [0.03, 0.20].
        let awakeFactor = (rrSpread * mpSpread) / 6.0  // scaled product
        let awakeFrac = min(0.20, max(0.03, awakeFactor * 0.15 + 0.03))

        // Light fraction: remainder
        let lightFrac = max(0.0, 1.0 - remFrac - deepFrac - awakeFrac)

        return [
            .awake: awakeFrac,
            .light: lightFrac,
            .deep:  deepFrac,
            .rem:   remFrac,
        ]
    }
}
