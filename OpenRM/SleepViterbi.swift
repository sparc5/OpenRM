//
//  SleepViterbi.swift
//  OpenRM
//
//  HMM-style Viterbi decode over per-minute stage log-probabilities.
//  Mirrors `ml/smoothing.py` exactly: same algorithm, same log-space
//  math, same handling of the first timestep (uniform prior, emission
//  only). The transition matrix ships as `transitions.json` in the
//  app bundle — trained from Samsung sleep-stage label sequences so
//  the priors reflect real sleep architecture.
//
//  Why this exists: the TCN loss is frame-level, so the raw argmax
//  over per-minute softmax will happily emit single-minute stage
//  flips (`NREM → REM → NREM` across 3 minutes) that can't happen in
//  real sleep. Viterbi smooths those out without losing genuine
//  transitions.
//

import Foundation

enum SleepViterbi {

    struct TransitionsJSON: Decodable {
        let stages: [String]
        let transition_matrix: [[Double]]
    }

    static func loadTransitions(from url: URL) throws -> (stages: [String], logTransition: [[Double]]) {
        let data = try Data(contentsOf: url)
        let t = try JSONDecoder().decode(TransitionsJSON.self, from: data)
        // Add a tiny floor before log — keeps rare transitions (e.g.
        // Awake → Deep direct) crossable when evidence is strong,
        // matches the 1e-9 floor used in the Python smoother.
        let log = t.transition_matrix.map { row in
            row.map { Foundation.log($0 + 1e-9) }
        }
        return (t.stages, log)
    }

    /// Decode the most likely stage sequence given per-minute log-prob
    /// emissions and a stage-transition matrix.
    ///
    /// `logEmission` has shape (T, S): log-probability the model gave
    /// to each stage at each minute. `logTransition` has shape (S, S):
    /// log-probability of transitioning from stage i to stage j.
    static func decode(
        logEmission: [[Double]],
        logTransition: [[Double]]
    ) -> [Int] {
        let T = logEmission.count
        guard T > 0 else { return [] }
        let S = logEmission[0].count

        // dp[t, s] = best log-probability of any path ending in stage s at time t
        var dp = Array(repeating: Array(repeating: -Double.infinity, count: S), count: T)
        var back = Array(repeating: Array(repeating: 0, count: S), count: T)

        // Uniform initial prior; first timestep contributes emission only.
        for s in 0..<S { dp[0][s] = logEmission[0][s] }

        for t in 1..<T {
            for curr in 0..<S {
                var bestPrev = 0
                var bestScore = -Double.infinity
                for prev in 0..<S {
                    let score = dp[t - 1][prev] + logTransition[prev][curr]
                    if score > bestScore {
                        bestScore = score
                        bestPrev = prev
                    }
                }
                back[t][curr] = bestPrev
                dp[t][curr] = bestScore + logEmission[t][curr]
            }
        }

        // Traceback.
        var path = Array(repeating: 0, count: T)
        var best = 0
        var bestScore = dp[T - 1][0]
        for s in 1..<S where dp[T - 1][s] > bestScore {
            bestScore = dp[T - 1][s]; best = s
        }
        path[T - 1] = best
        for t in stride(from: T - 2, through: 0, by: -1) {
            path[t] = back[t + 1][path[t + 1]]
        }
        return path
    }
}
