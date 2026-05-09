//
//  BLE3ClassClassifier.swift
//  OpenRM
//
//  3-class sleep-stage classifier (Awake / NREM / REM) trained on
//  CPAP per-minute telemetry against Samsung Health Connect labels.
//
//  Data: 30,225 labeled minutes from 85 nights, group-k-fold CV.
//  Result: 0.72 per-minute exact, 0.79 within ±2 min, 0.81 within ±3
//  min agreement vs Samsung wrist-based stages. The 3-class collapse
//  (Light + Deep → NREM) is forced by the data — CPAP cannot reliably
//  distinguish Light from Deep because both present as "stable mask,
//  regular breathing" from the airway sensors' perspective. See
//  literature review: respiratory-only 4-class staging tops out at
//  ~70% (RF) / 77% (biLSTM); 3-class collapse hits the 80% bar.
//
//  Model: HistGradientBoostingClassifier, 522 iterations, 3 trees per
//  iteration (one per class), 95,526 total decision nodes. Shipped as
//  BLE3ClassModel.json in the app bundle and walked at inference time.
//
//  Features (97 total) computed in Swift from the BLE per-minute spool:
//     - rr, tv, mp, leak               (per-minute means)
//     - rolling mean & std at 3, 10, 30 min
//     - slope at 5, 15, 30 min
//     - lags at -30, -15, -5, +5, +15, +30 min
//     - cross-channel: tv/rr, leak/mp
//     - sleep architecture: min_since_sess, min_since_first, sess_idx
//     - per-session z-score versions of the above
//

import Foundation
import SwiftUI

/// 3-state sleep stage. Matches the trained model's class labels.
enum SleepStage3: String, CaseIterable {
    case awake = "Awake"
    case nrem  = "NREM"
    case rem   = "REM"

    /// Display color (kept on-brand with the existing 4-class scheme:
    /// red=awake, blue=nrem (was deep), purple=rem).
    var color: Color {
        switch self {
        case .awake: return .red
        case .nrem:  return .blue
        case .rem:   return .purple
        }
    }
}

/// HGBT inference engine over the v5 BLE-portable model. Loaded once
/// from the bundle and reused.
final class BLE3ClassClassifier {

    static let shared: BLE3ClassClassifier? = {
        guard let url = Bundle.main.url(forResource: "BLE3ClassModel",
                                         withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(ModelJSON.self, from: data)
        else {
            return nil
        }
        return BLE3ClassClassifier(model: m)
    }()

    /// Compact JSON layout matching `export_model.py`.
    struct ModelJSON: Decodable {
        let version: Int
        let feature_cols: [String]
        let stages: [String]
        let baseline_prediction: [Double]
        let learning_rate: Double
        let n_iter: Int
        let iterations: [[Tree]]
    }
    struct Tree: Decodable {
        // Each node is encoded as a 7-element array:
        //   [feature_idx, threshold, missing_left, left, right, value, is_leaf]
        let nodes: [[Double]]
    }

    let model: ModelJSON
    /// `feature_cols` flattened to (kind, baseChan, param) for fast lookup
    /// during feature-vector assembly.
    private let featurePlan: [FeatureSpec]

    private init(model: ModelJSON) {
        self.model = model
        self.featurePlan = model.feature_cols.map { Self.parseFeatureName($0) }
    }

    // MARK: - Public API

    /// Classify each minute of a session into a 3-class stage. The
    /// returned array has one element per input minute (any element
    /// can be `nil` if the input had no usable signal).
    ///
    /// Assumes a single session — `min_since_sess` and `min_since_first`
    /// are both set to the minute index. For multi-session nights the
    /// caller can stitch results from multiple invocations together.
    func classifySession(rr: [Double], tv: [Double],
                          mp: [Double], leak: [Double?]) -> [SleepStage3] {
        let n = min(min(rr.count, tv.count), mp.count)
        guard n > 0 else { return [] }

        // 1. Build per-minute feature engineering buffers.
        let bundle = FeatureBundle(rr: Array(rr.prefix(n)),
                                    tv: Array(tv.prefix(n)),
                                    mp: Array(mp.prefix(n)),
                                    leak: Array(leak.prefix(n)
                                        .map { $0 ?? Double.nan }))

        // 2. Per-minute classification: pack feature vector, walk trees.
        var out: [SleepStage3] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let x = featureVector(at: i, bundle: bundle, sessionLength: n)
            let stageStr = predict(x)
            out.append(SleepStage3(rawValue: stageStr) ?? .nrem)
        }
        return out
    }

    // MARK: - Inference

    /// Sum of (learning_rate × tree_value) per class plus baseline,
    /// then argmax. Bypasses softmax — it's monotonic for argmax.
    private func predict(_ x: [Double]) -> String {
        var scores = model.baseline_prediction
        for itTrees in model.iterations {
            for (k, tree) in itTrees.enumerated() {
                scores[k] += model.learning_rate * walk(tree.nodes, x: x)
            }
        }
        var bestIdx = 0; var best = scores[0]
        for i in 1..<scores.count where scores[i] > best {
            best = scores[i]; bestIdx = i
        }
        return model.stages[bestIdx]
    }

    /// Walk one tree to a leaf value. Node format:
    ///   [feature_idx, threshold, missing_left, left, right, value, is_leaf]
    private func walk(_ nodes: [[Double]], x: [Double]) -> Double {
        var idx = 0
        while true {
            let n = nodes[idx]
            if n[6] != 0 { return n[5] }   // is_leaf
            let feat = Int(n[0])
            let thr  = n[1]
            let missLeft = n[2] != 0
            let left = Int(n[3]); let right = Int(n[4])
            let v = x[feat]
            if v.isNaN {
                idx = missLeft ? left : right
            } else {
                idx = v <= thr ? left : right
            }
        }
    }

    // MARK: - Feature engineering

    /// Compact representation of a feature's identity, parsed once
    /// from its column name so `featureVector` can dispatch fast.
    enum FeatureSpec {
        case raw(Channel)                       // "rr", "tv", "mp", "leak"
        case rmean(Channel, Int)                // _rmean_3, _rmean_10, _rmean_30
        case rstd(Channel, Int)                 // _rstd_*
        case slope(Channel, Int)                // _slope_5, _slope_15, _slope_30
        case lag(Channel, Int)                  // _lag_-30 ... _lag_30
        case tvPerRr
        case leakOverMp
        case minSinceSess
        case minSinceFirst
        case sessIdx
        case zRaw(Channel)                      // "rr__z"
        case zRmean(Channel, Int)               // "rr_rmean_3__z"
        case zSlope(Channel, Int)               // "rr_slope_5__z"
        case unknown(String)
    }
    enum Channel: String { case rr, tv, mp, leak }

    static func parseFeatureName(_ name: String) -> FeatureSpec {
        // Architecture features
        switch name {
        case "min_since_sess":  return .minSinceSess
        case "min_since_first": return .minSinceFirst
        case "sess_idx":        return .sessIdx
        case "tv_per_rr":       return .tvPerRr
        case "leak_over_mp":    return .leakOverMp
        default: break
        }

        let isZ = name.hasSuffix("__z")
        let stripped = isZ ? String(name.dropLast(3)) : name

        // Identify base channel (longest match wins so "leak" beats "tv")
        let channels: [(String, Channel)] = [
            ("leak", .leak), ("rr", .rr), ("tv", .tv), ("mp", .mp)
        ]
        var ch: Channel?
        var rest = ""
        for (prefix, c) in channels where stripped.hasPrefix(prefix + "_") || stripped == prefix {
            ch = c
            rest = String(stripped.dropFirst(prefix.count))
            break
        }
        guard let chan = ch else { return .unknown(name) }

        // rest is "" (raw), or "_rmean_3", "_rstd_30", "_slope_5", "_lag_-15", etc.
        if rest.isEmpty {
            return isZ ? .zRaw(chan) : .raw(chan)
        }
        let parts = rest.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        if parts.count == 2 {
            let kind = parts[0]
            let n = Int(parts[1]) ?? 0
            switch kind {
            case "rmean": return isZ ? .zRmean(chan, n) : .rmean(chan, n)
            case "rstd":  return .rstd(chan, n)
            case "slope": return isZ ? .zSlope(chan, n) : .slope(chan, n)
            case "lag":   return .lag(chan, n)
            default: return .unknown(name)
            }
        }
        return .unknown(name)
    }

    /// Buffers shared across all minutes of one session — we compute
    /// rolling stats once, then index into them per minute.
    private struct FeatureBundle {
        let rr: [Double]
        let tv: [Double]
        let mp: [Double]
        let leak: [Double]    // may contain NaN

        let rrPerNightZ: ZScale
        let tvPerNightZ: ZScale
        let mpPerNightZ: ZScale
        let leakPerNightZ: ZScale

        let rmean3:  [Channel: [Double]]
        let rmean10: [Channel: [Double]]
        let rmean30: [Channel: [Double]]
        let rstd3:   [Channel: [Double]]
        let rstd10:  [Channel: [Double]]
        let rstd30:  [Channel: [Double]]
        let slope5:  [Channel: [Double]]
        let slope15: [Channel: [Double]]
        let slope30: [Channel: [Double]]

        struct ZScale { let mean: Double; let std: Double
            func apply(_ v: Double) -> Double {
                guard std != 0 else { return 0 }
                return (v - mean) / std
            }
        }

        init(rr: [Double], tv: [Double], mp: [Double], leak: [Double]) {
            self.rr = rr; self.tv = tv; self.mp = mp; self.leak = leak
            let chans: [(Channel, [Double])] = [
                (.rr, rr), (.tv, tv), (.mp, mp), (.leak, leak)
            ]
            var rm3: [Channel: [Double]] = [:]
            var rm10: [Channel: [Double]] = [:]
            var rm30: [Channel: [Double]] = [:]
            var rs3: [Channel: [Double]] = [:]
            var rs10: [Channel: [Double]] = [:]
            var rs30: [Channel: [Double]] = [:]
            var sl5: [Channel: [Double]] = [:]
            var sl15: [Channel: [Double]] = [:]
            var sl30: [Channel: [Double]] = [:]
            for (c, arr) in chans {
                rm3[c]  = Self.rollingMean(arr, window: 3,  centered: true)
                rm10[c] = Self.rollingMean(arr, window: 10, centered: true)
                rm30[c] = Self.rollingMean(arr, window: 30, centered: true)
                rs3[c]  = Self.rollingStd(arr,  window: 3,  centered: true)
                rs10[c] = Self.rollingStd(arr,  window: 10, centered: true)
                rs30[c] = Self.rollingStd(arr,  window: 30, centered: true)
                sl5[c]  = Self.trailingMinusLeading(arr, window: 5)
                sl15[c] = Self.trailingMinusLeading(arr, window: 15)
                sl30[c] = Self.trailingMinusLeading(arr, window: 30)
            }
            rmean3 = rm3; rmean10 = rm10; rmean30 = rm30
            rstd3  = rs3; rstd10  = rs10; rstd30  = rs30
            slope5 = sl5; slope15 = sl15; slope30 = sl30
            rrPerNightZ   = Self.zScale(rr)
            tvPerNightZ   = Self.zScale(tv)
            mpPerNightZ   = Self.zScale(mp)
            leakPerNightZ = Self.zScale(leak)
        }

        // ---- helpers -----------------------------------------------------

        static func rollingMean(_ a: [Double], window w: Int, centered: Bool) -> [Double] {
            let n = a.count
            var out = [Double](repeating: .nan, count: n)
            for i in 0..<n {
                let lo: Int; let hi: Int
                if centered {
                    let half = w / 2
                    lo = max(0, i - half)
                    hi = min(n, i + half + 1)
                } else {
                    lo = max(0, i - w + 1); hi = i + 1
                }
                var sum = 0.0; var k = 0
                for j in lo..<hi where !a[j].isNaN {
                    sum += a[j]; k += 1
                }
                out[i] = k > 0 ? sum / Double(k) : .nan
            }
            return out
        }

        static func rollingStd(_ a: [Double], window w: Int, centered: Bool) -> [Double] {
            let n = a.count
            var out = [Double](repeating: .nan, count: n)
            for i in 0..<n {
                let lo: Int; let hi: Int
                if centered {
                    let half = w / 2
                    lo = max(0, i - half); hi = min(n, i + half + 1)
                } else {
                    lo = max(0, i - w + 1); hi = i + 1
                }
                var vals: [Double] = []
                vals.reserveCapacity(hi - lo)
                for j in lo..<hi where !a[j].isNaN { vals.append(a[j]) }
                guard vals.count >= 2 else { continue }
                let mean = vals.reduce(0, +) / Double(vals.count)
                let v = vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count - 1)
                out[i] = v.squareRoot()
            }
            return out
        }

        /// Slope ≈ rolling_mean_trailing(window/2) shifted -window/2 minus
        /// rolling_mean_leading(window/2) — matches the Python construction.
        static func trailingMinusLeading(_ a: [Double], window w: Int) -> [Double] {
            let half = w / 2
            let n = a.count
            // Trailing rolling mean over `half` values, ending at i (inclusive)
            let trailing = rollingMean(a, window: half, centered: false)
            // Shift -half = look ahead `half` minutes
            var out = [Double](repeating: .nan, count: n)
            for i in 0..<n {
                let target = i + half
                guard target < n else { continue }
                let lead = trailing[target]
                let cur = trailing[i]
                if !lead.isNaN && !cur.isNaN {
                    out[i] = lead - cur
                }
            }
            return out
        }

        static func zScale(_ a: [Double]) -> ZScale {
            let valid = a.filter { !$0.isNaN }
            guard valid.count >= 2 else { return ZScale(mean: 0, std: 1) }
            let m = valid.reduce(0, +) / Double(valid.count)
            let v = valid.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(valid.count - 1)
            let s = v.squareRoot()
            return ZScale(mean: m, std: s == 0 ? 1 : s)
        }
    }

    /// Build the 97-element feature vector for minute `i`. Unknown
    /// features default to NaN so the trees route through their
    /// `missing_go_to_left` branch.
    private func featureVector(at i: Int, bundle: FeatureBundle, sessionLength n: Int) -> [Double] {
        var x = [Double](repeating: .nan, count: featurePlan.count)
        for (idx, spec) in featurePlan.enumerated() {
            x[idx] = value(for: spec, at: i, bundle: bundle, sessionLength: n)
        }
        return x
    }

    private func value(for spec: FeatureSpec,
                       at i: Int,
                       bundle b: FeatureBundle,
                       sessionLength n: Int) -> Double {
        func base(_ c: Channel) -> [Double] {
            switch c {
            case .rr: return b.rr
            case .tv: return b.tv
            case .mp: return b.mp
            case .leak: return b.leak
            }
        }
        func rolling(_ c: Channel, _ window: Int, isStd: Bool) -> Double {
            let arr: [Double]?
            if isStd {
                switch window {
                case 3:  arr = b.rstd3[c]
                case 10: arr = b.rstd10[c]
                case 30: arr = b.rstd30[c]
                default: return .nan
                }
            } else {
                switch window {
                case 3:  arr = b.rmean3[c]
                case 10: arr = b.rmean10[c]
                case 30: arr = b.rmean30[c]
                default: return .nan
                }
            }
            guard let a = arr, i < a.count else { return .nan }
            return a[i]
        }
        func slope(_ c: Channel, _ window: Int) -> Double {
            let arr: [Double]?
            switch window {
            case 5:  arr = b.slope5[c]
            case 15: arr = b.slope15[c]
            case 30: arr = b.slope30[c]
            default: return .nan
            }
            guard let a = arr, i < a.count else { return .nan }
            return a[i]
        }
        func zScale(_ c: Channel) -> FeatureBundle.ZScale {
            switch c {
            case .rr: return b.rrPerNightZ
            case .tv: return b.tvPerNightZ
            case .mp: return b.mpPerNightZ
            case .leak: return b.leakPerNightZ
            }
        }

        switch spec {
        case .raw(let c):
            let a = base(c); return i < a.count ? a[i] : .nan
        case .rmean(let c, let w): return rolling(c, w, isStd: false)
        case .rstd(let c, let w):  return rolling(c, w, isStd: true)
        case .slope(let c, let w): return slope(c, w)
        case .lag(let c, let lag):
            // Python lag convention: lag_-5 = m.shift(5), so value at t-5.
            // lag_5 = m.shift(-5), so value at t+5.
            let arr = base(c)
            let target = i - lag       // shift(-lag) so value(target = i - lag)
            guard target >= 0 && target < arr.count else { return .nan }
            return arr[target]
        case .tvPerRr:
            guard i < b.tv.count, i < b.rr.count, b.rr[i] != 0 else { return .nan }
            return b.tv[i] / b.rr[i]
        case .leakOverMp:
            guard i < b.leak.count, i < b.mp.count, b.mp[i] != 0 else { return .nan }
            return b.leak[i] / b.mp[i]
        case .minSinceSess:  return Double(i)
        case .minSinceFirst: return Double(i)
        case .sessIdx:       return 0
        case .zRaw(let c):
            let a = base(c)
            let v = i < a.count ? a[i] : Double.nan
            return zScale(c).apply(v)
        case .zRmean(let c, let w):
            return zScale(c).apply(rolling(c, w, isStd: false))
        case .zSlope(let c, let w):
            return zScale(c).apply(slope(c, w))
        case .unknown:
            return .nan
        }
    }
}
