//
//  SleepFeatureBuilder.swift
//  OpenRM
//
//  Builds the per-minute feature matrix that the TCN sleep-stage model
//  consumes. Mirrors `ml/features.py` exactly — same column order, same
//  rolling windows, same NaN-fill semantics — so the model sees the
//  same distribution at runtime as at training.
//
//  Inputs are one aligned 1-minute stream per BLE channel plus an
//  optional HR stream. Missing minutes (BLE dropout) should be passed
//  as `nil` so the centered rolling operators can skip them and the
//  `hk_available` flag is set correctly.
//
//  The output MLMultiArray is shape (1, T, F) with F = 87:
//    8 base channels (rr, tv, mv, mp, set_p, leak, coverage, hr)
//    + {rmean, rstd} at {3, 10, 30} min                 48
//    + slope at {5, 15} min                             16
//    + 3 cross-channel ratios (tv/rr, mv/rr, leak/mp)
//    + 3 session-architecture features (min_since_sess,
//      min_since_first, sess_idx)
//    + 8 per-night z-score columns
//    + 1 hk_available flag
//
//  The normalization (StandardScaler) is baked into the Core ML graph,
//  so the values emitted here are raw engineered features — do NOT
//  pre-scale.
//

import Foundation
import CoreML

enum SleepFeatureBuilder {

    /// One minute of aligned per-channel telemetry. `hr` is optional —
    /// pass nil when HealthKit didn't deliver a reading for that minute.
    struct MinuteInput {
        let timestampMinuteUTC: Date
        let rr: Double
        let tv: Double
        let mv: Double
        let mp: Double
        let setP: Double
        let leak: Double
        let coverage: Double   // 0..1 fraction of the minute with active therapy
        let hr: Double?
    }

    /// The full ordered list of columns the model expects. Kept in sync
    /// with `feature_spec.json` — if that file changes, this constant
    /// must change too. The loader validates this at startup.
    static let baseChannels = ["rr", "tv", "mv", "mp", "set_p", "leak", "coverage", "hr"]
    static let rollingWindowsMin = [3, 10, 30]
    static let slopeWindowsMin = [5, 15]
    static let sessionGapMin = 5

    /// Full ordered feature-column list (must match
    /// `FeatureSpec.column_names()` in Python).
    static var featureColumns: [String] {
        var cols: [String] = baseChannels
        for ch in baseChannels {
            for w in rollingWindowsMin {
                cols += ["\(ch)_rmean_\(w)", "\(ch)_rstd_\(w)"]
            }
            for w in slopeWindowsMin {
                cols.append("\(ch)_slope_\(w)")
            }
        }
        cols += ["tv_per_rr", "mv_per_rr", "leak_over_mp"]
        cols += ["min_since_sess", "min_since_first", "sess_idx"]
        for ch in baseChannels {
            cols.append("\(ch)_znight")
        }
        cols.append("hk_available")
        return cols
    }

    static let featureCount = featureColumns.count   // 87

    // MARK: - Public build

    /// Build the (1, T, F) MLMultiArray the Core ML model consumes.
    /// The caller owns the input array and may discard it after this
    /// returns — we copy into the MLMultiArray's backing buffer.
    static func build(from minutes: [MinuteInput]) throws -> MLMultiArray {
        precondition(!minutes.isEmpty, "need at least one minute of input")
        let T = minutes.count
        let F = featureCount

        // Extract base-channel vectors as Double arrays for easier math.
        var base: [String: [Double]] = [:]
        for ch in baseChannels { base[ch] = Array(repeating: 0, count: T) }
        var hkAvail = [Double](repeating: 0, count: T)
        for i in 0..<T {
            let m = minutes[i]
            base["rr"]![i] = m.rr
            base["tv"]![i] = m.tv
            base["mv"]![i] = m.mv
            base["mp"]![i] = m.mp
            base["set_p"]![i] = m.setP
            base["leak"]![i] = m.leak
            base["coverage"]![i] = m.coverage
            if let hr = m.hr {
                base["hr"]![i] = hr
                hkAvail[i] = 1
            } else {
                base["hr"]![i] = 0
                hkAvail[i] = 0
            }
        }

        // Per-channel rolling/slope/znight caches.
        var rollingMean: [String: [Int: [Double]]] = [:]
        var rollingStd: [String: [Int: [Double]]] = [:]
        var slope: [String: [Int: [Double]]] = [:]
        var znight: [String: [Double]] = [:]
        for ch in baseChannels {
            rollingMean[ch] = [:]
            rollingStd[ch] = [:]
            slope[ch] = [:]
            let v = base[ch]!
            for w in rollingWindowsMin {
                rollingMean[ch]![w] = centeredRollingMean(v, window: w)
                rollingStd[ch]![w] = centeredRollingStd(v, window: w)
            }
            for w in slopeWindowsMin {
                slope[ch]![w] = forwardMinusBackwardMean(v, window: w)
            }
            znight[ch] = perSeriesZScore(v)
        }

        // Cross-channel ratios.
        let tvPerRR = zip(base["tv"]!, base["rr"]!).map { ratio($0, $1) }
        let mvPerRR = zip(base["mv"]!, base["rr"]!).map { ratio($0, $1) }
        let leakOverMp = zip(base["leak"]!, base["mp"]!).map { ratio($0, $1) }

        // Session architecture.
        let (minSinceSess, minSinceFirst, sessIdx) = sessionArchitecture(
            timestamps: minutes.map { $0.timestampMinuteUTC },
            gapMinutes: sessionGapMin
        )

        // Pack into MLMultiArray row-by-row in the feature-column order.
        let array = try MLMultiArray(shape: [1, NSNumber(value: T), NSNumber(value: F)],
                                      dataType: .float32)
        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        // array strides: (T*F, F, 1) for (1, T, F)
        for t in 0..<T {
            var col = 0
            @inline(__always) func put(_ x: Double) {
                ptr[t * F + col] = Float32(x.isFinite ? x : 0)
                col += 1
            }

            for ch in baseChannels { put(base[ch]![t]) }
            for ch in baseChannels {
                for w in rollingWindowsMin {
                    put(rollingMean[ch]![w]![t])
                    put(rollingStd[ch]![w]![t])
                }
                for w in slopeWindowsMin {
                    put(slope[ch]![w]![t])
                }
            }
            put(tvPerRR[t])
            put(mvPerRR[t])
            put(leakOverMp[t])
            put(minSinceSess[t])
            put(minSinceFirst[t])
            put(sessIdx[t])
            for ch in baseChannels { put(znight[ch]![t]) }
            put(hkAvail[t])

            assert(col == F, "column count drift: emitted \(col) expected \(F)")
        }
        return array
    }

    // MARK: - Primitives

    /// Centered rolling mean with min_periods=2 semantics (pandas
    /// default when `min_periods` is set). Returns 0 where the window
    /// contains fewer than 2 valid samples — matches Python's NaN → 0
    /// fill at the end of `build_features`.
    private static func centeredRollingMean(_ v: [Double], window: Int) -> [Double] {
        let n = v.count
        var out = [Double](repeating: 0, count: n)
        let half = window / 2
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i - half + window)
            let w = hi - lo
            guard w >= 2 else { continue }
            var s = 0.0
            for k in lo..<hi { s += v[k] }
            out[i] = s / Double(w)
        }
        return out
    }

    /// Centered rolling sample std (N-1 denominator), min_periods=2.
    private static func centeredRollingStd(_ v: [Double], window: Int) -> [Double] {
        let n = v.count
        var out = [Double](repeating: 0, count: n)
        let half = window / 2
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i - half + window)
            let w = hi - lo
            guard w >= 2 else { continue }
            var mean = 0.0
            for k in lo..<hi { mean += v[k] }
            mean /= Double(w)
            var sq = 0.0
            for k in lo..<hi { let d = v[k] - mean; sq += d * d }
            out[i] = (sq / Double(w - 1)).squareRoot()
        }
        return out
    }

    /// Slope = rolling-mean(half, shifted -half) - rolling-mean(half).
    /// Python uses `.rolling(half).mean()` which is backward-looking
    /// with min_periods=half, then `.shift(-half)` to move it forward.
    /// We match that: positions where either side has fewer than `half`
    /// samples get 0.
    private static func forwardMinusBackwardMean(_ v: [Double], window: Int) -> [Double] {
        let n = v.count
        let half = window / 2
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            // backward mean: samples (i - half + 1 ... i)
            let blo = i - half + 1
            let bhi = i + 1
            // forward mean: samples (i + 1 ... i + half)  (shift -half on backward window ending at i + half)
            let flo = i + 1
            let fhi = i + half + 1
            guard blo >= 0, fhi <= n, half >= 1 else { continue }
            var b = 0.0
            for k in blo..<bhi { b += v[k] }
            var f = 0.0
            for k in flo..<fhi { f += v[k] }
            out[i] = (f - b) / Double(half)
        }
        return out
    }

    private static func perSeriesZScore(_ v: [Double]) -> [Double] {
        guard v.count >= 2 else { return Array(repeating: 0, count: v.count) }
        var mean = 0.0
        for x in v { mean += x }
        mean /= Double(v.count)
        var sq = 0.0
        for x in v { let d = x - mean; sq += d * d }
        let std = (sq / Double(v.count - 1)).squareRoot()
        guard std.isFinite, std > 0 else { return Array(repeating: 0, count: v.count) }
        return v.map { ($0 - mean) / std }
    }

    private static func ratio(_ num: Double, _ den: Double) -> Double {
        guard den != 0, den.isFinite else { return 0 }
        let r = num / den
        return r.isFinite ? r : 0
    }

    /// Detect session boundaries from time-index gaps > `gapMinutes`
    /// and annotate each minute with its position metadata. Returns
    /// three arrays length T: (min_since_sess, min_since_first, sess_idx).
    private static func sessionArchitecture(
        timestamps: [Date],
        gapMinutes: Int
    ) -> ([Double], [Double], [Double]) {
        let n = timestamps.count
        guard n > 0 else { return ([], [], []) }
        var sessIdx = [Int](repeating: 0, count: n)
        var sessionStarts: [Date] = [timestamps[0]]
        for i in 1..<n {
            let gapMin = timestamps[i].timeIntervalSince(timestamps[i - 1]) / 60.0
            if gapMin > Double(gapMinutes) {
                sessionStarts.append(timestamps[i])
            }
            sessIdx[i] = sessionStarts.count - 1
        }
        let first = timestamps[0]
        var sinceSess = [Double](repeating: 0, count: n)
        var sinceFirst = [Double](repeating: 0, count: n)
        var idx = [Double](repeating: 0, count: n)
        for i in 0..<n {
            sinceSess[i] = timestamps[i].timeIntervalSince(sessionStarts[sessIdx[i]]) / 60.0
            sinceFirst[i] = timestamps[i].timeIntervalSince(first) / 60.0
            idx[i] = Double(sessIdx[i])
        }
        return (sinceSess, sinceFirst, idx)
    }
}
