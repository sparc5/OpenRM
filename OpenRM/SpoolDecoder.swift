//
//  SpoolDecoder.swift
//  OpenRM
//
//  Decoder for AirSense 11 `Summary` spool fragments.
//
//  The CPAP exposes per-day therapy summaries over BLE as protobuf-encoded
//  SpoolFragment notifications. The wire schema was reverse-engineered from
//  myAir captures (see reference_openrm_fig_protocol.md) and field
//  semantics were mapped against OSCAR's open-source ResMed STR.edf loader
//  (see reference_oscar_resmed.md for the field-by-field rationale).
//
//  OSCAR reads the same fields off the SD-card .edf file; the BLE protobuf
//  is a different container with the same physical quantities, so we trust
//  OSCAR's field name list but derive scale factors empirically by matching
//  raw varint values to physically-plausible ranges.
//
//  Dependencies: none. Adding SwiftProtobuf for one schema is overkill, so
//  this is a minimal hand-rolled wire-format walker.
//

import Foundation

/// A single day's therapy summary from a `Summary` spool. Field names
/// follow OSCAR's `resmed_loader.cpp` naming. Fields whose semantics are
/// still uncertain are exposed under `unknown` with their raw wire values
/// so we can correlate them against myAir UI values once OpenRM re-pairs.
struct DaySummary {
    /// Day-start timestamp from the CPAP (UTC millis since epoch).
    let startDate: Date
    /// Day-end timestamp, normally startDate + 24h.
    let endDate: Date
    /// Total mask-on duration for the day, in minutes.
    let maskDurationMinutes: Int
    /// Timestamp when the CPAP wrote this summary record.
    let recordGeneratedAt: Date

    /// AHI-related event indices in events-per-hour. Cross-verified
    /// against OSCAR/STR.edf on 2026-04-11: values decoded from fields
    /// 7..13 match the STR.edf signals `AHI / AI / HI / OAI / CAI /
    /// UAI / RIN` exactly (each raw varint is the event index × 100).
    let ahi: Double            // field  7 — combined apnea+hypopnea index
    let ai:  Double            // field  8 — apnea index
    let hi:  Double            // field  9 — hypopnea index
    let oai: Double            // field 10 — obstructive apnea index
    let cai: Double            // field 11 — clear-airway (central) apnea index
    let uai: Double            // field 12 — unclassified apnea index
    let rin: Double            // field 13 — RERA index ("RIN")

    /// Measured mask pressure percentiles, cmH₂O. Field 21 on the wire.
    let maskPressure: Percentiles?
    /// Target inspiratory pressure percentiles, cmH₂O. Field 15 on the wire.
    let targetIPAP: Percentiles?
    /// Target expiratory pressure percentiles, cmH₂O. Field 20 on the wire.
    let targetEPAP: Percentiles?
    /// Unintentional leak percentiles (L/s × 100), four levels —
    /// `.50`, `.70`, `.95`, `.max`. Field 14 on the wire. To display
    /// in L/min multiply each by 60.
    let leak: LeakPercentiles?
    /// Tidal volume percentiles, liters. Field 22 on the wire.
    let tidalVolume: Percentiles?
    /// Minute ventilation percentiles, L/min. Field 23 on the wire.
    let minuteVentilation: Percentiles?
    /// Respiratory rate percentiles, breaths/min. Field 25 on the wire.
    let respiratoryRate: Percentiles?

    /// Number of mask on/off transitions observed in the day.
    /// Field 39 on the wire (== STR.edf `MaskEvents`).
    let maskEventCount: Int

    /// Ambient humidity, median over the day (mg/L). Field 29 on the wire,
    /// sub-field 2 is the .50 percentile × 100.
    let ambientHumidity: Double?
    /// Heated tube temperature, median (°C). Field 31 sub-field 2 × 100.
    let heatedTubeTemp: Double?
    /// Humidifier power duty cycle, median (%). Field 32 sub-field 2 × 100.
    let humidifierPower: Double?
    /// Heated tube power duty cycle, median (%). Field 33 sub-field 2 × 100.
    let heatedTubePower: Double?

    /// Individual therapy sessions within this day, decoded from the
    /// per-session list at protobuf field 6. Each entry gives the
    /// session's absolute start time and its duration in minutes.
    ///
    /// Ground-truth note (2026-04-11 capture): the CPAP may emit more
    /// session entries than myAir/OSCAR display — it records every
    /// mask-on/off transition including micro-cycles (0-1 min blips)
    /// that myAir merges. Consumers of this list should filter by
    /// duration when they care about "real sleep sessions".
    let sessions: [Session]

    /// Raw wire values for fields whose meaning we haven't confirmed yet.
    /// Keyed by protobuf field number.
    let unknownFields: [Int: RawField]

    /// Percentile triple as reported by the CPAP.
    /// Wire sub-fields are always in strictly increasing value order (2 < 3 < 4),
    /// which matches the triple `{median, 95th percentile, max}` — the same
    /// three statistics OSCAR exposes via the STR.edf `.50` / `.95` / `.Max`
    /// signal labels. Cross-verified against SD-card STR.edf 2026-04-11.
    struct Percentiles {
        let p50: Double
        let p95: Double
        let max: Double
    }

    /// Leak percentile set — four levels unique to the leak signal
    /// (`.50`, `.70`, `.95`, `.Max`). Field 14 on the wire.
    struct LeakPercentiles {
        let p50: Double
        let p70: Double
        let p95: Double
        let max: Double
    }

    /// One therapy session (mask-on-to-mask-off period).
    struct Session {
        /// Corrected absolute UTC start — the CPAP's clock drift (if
        /// any) has already been subtracted, so this Date is ready to
        /// display in the user's local timezone or hand to HealthKit.
        let startDate: Date
        let durationMinutes: Int
        /// Raw millisecond timestamp as the CPAP stored it, BEFORE
        /// clock-drift correction. Used as the stable dedup key for
        /// HealthKit samples — survives the user travelling timezones
        /// (which would shift `startDate` on re-sync but leaves this
        /// untouched).
        let rawStartMs: UInt64
        var endDate: Date { startDate.addingTimeInterval(Double(durationMinutes) * 60) }
    }
}

/// Raw protobuf field value, preserved when we can't interpret the field.
enum RawField {
    case varint(UInt64)
    case fixed32(UInt32)
    case fixed64(UInt64)
    case bytes(Data)
    case message([Int: [RawField]])
}

enum SpoolDecoderError: Error {
    case truncated
    case invalidWireType(Int)
    case parseError(String)
}

/// Decodes a `Summary` SpoolFragment payload (the raw protobuf bytes
/// inside the base64-encoded `data` field of the JSON-RPC notification).
enum SummarySpoolDecoder {

    /// Parse a full `Summary` fragment into an array of `DaySummary`s.
    ///
    /// The top-level wire format is `repeated DayRecord records = 2;` — so
    /// we walk the outer message and decode each field-2 sub-message into
    /// one `DaySummary`.
    ///
    /// - Parameter clockOffsetSeconds: the drift of the CPAP's internal
    ///   UTC clock relative to real UTC. Session timestamps (and the
    ///   day boundary dates) get `-clockOffsetSeconds` applied before
    ///   being returned, so callers see real-UTC `Date` values they
    ///   can display in any timezone directly. Default 0 = no
    ///   correction. The raw stable millisecond value is still
    ///   preserved on each `Session` for dedup purposes.
    static func decode(_ data: Data, clockOffsetSeconds: TimeInterval = 0) throws -> [DaySummary] {
        let root = try parseMessage(data)
        var out: [DaySummary] = []
        guard let recordFields = root[2] else { return [] }
        for rec in recordFields {
            if case .message(let m) = rec {
                out.append(try buildDaySummary(from: m, clockOffsetSeconds: clockOffsetSeconds))
            }
        }
        return out
    }

    // MARK: - DayRecord assembly

    /// Field number → semantic meaning mapping. Every field was
    /// cross-verified against the CPAP's own SD-card `STR.edf` file
    /// on 2026-04-11 for the same day, confirming scale factors and
    /// semantic intent exactly. See memory/reference_openrm_fig_protocol.md.
    ///
    ///   1  — record version (always 1 in captures)
    ///   2  — start_ms (int64) — day boundary ≈ 1pm local
    ///   3  — end_ms   (int64) — start + 24h
    ///   4  — unknown, constant 599
    ///   5  — Duration (mask minutes) — matches STR.edf `Duration`
    ///   6  — repeated Session { ts_ms, duration_min }. NOTE: field 6
    ///        timestamps are ~1h later than STR.edf `MaskOn` times
    ///        (probably "first stable breath after ramp" vs
    ///        "mask-on moment"); durations match exactly.
    ///   7  — AHI × 100  (events/hr)
    ///   8  — AI  × 100  (apnea index)
    ///   9  — HI  × 100  (hypopnea index)
    ///   10 — OAI × 100  (obstructive apnea)
    ///   11 — CAI × 100  (clear airway / central apnea)
    ///   12 — UAI × 100  (unclassified apnea)
    ///   13 — RIN × 100  (RERA index)
    ///   14 — Leak percentiles × 100 L/s  { .50, .70, .95, .Max }
    ///   15 — TgtIPAP percentiles × 100 cmH₂O  { .50, .95, .Max }
    ///   16 — unknown, observed 0
    ///   20 — TgtEPAP percentiles × 100 cmH₂O
    ///   21 — MaskPress percentiles × 100 cmH₂O (actual measured)
    ///   22 — TidVol percentiles × 100 L  (tidal volume, not leak!)
    ///   23 — MinVent percentiles × 100 L/min
    ///   25 — RespRate percentiles × 100 br/min
    ///   29 — AmbHumidity.50 × 100 mg/L
    ///   30 — HumTemp.50 × 100 °C
    ///   31 — HTubeTemp.50 × 100 °C
    ///   32 — HumPow.50 × 100 %
    ///   33 — HTubePow.50 × 100 %
    ///   34 — unknown, constant 2
    ///   35 — unknown, constant 1
    ///   36 — BlowPress { .5, .95 } × 100 cmH₂O
    ///   37 — Flow { .5, .95 } × 100 L/s
    ///   38 — BlowFlow.50 × 100 L/s
    ///   39 — MaskEvents (int count, matches STR.edf)
    ///   40 — record_generated_ms (int64)
    ///   43 — device-reference ms (constant within a batch)
    private static func buildDaySummary(from m: [Int: [RawField]],
                                         clockOffsetSeconds: TimeInterval = 0) throws -> DaySummary {
        let startMs = firstVarint(m, field: 2) ?? 0
        let endMs = firstVarint(m, field: 3) ?? 0
        let maskDurMin = Int(firstVarint(m, field: 5) ?? 0)
        let generatedMs = firstVarint(m, field: 40) ?? 0

        // Fields 7..13 = seven AHI-component indices × 100.
        func indexField(_ fld: Int) -> Double {
            Double(firstVarint(m, field: fld) ?? 0) / 100.0
        }

        let targetIPAP = percentiles(m, field: 15, scale: 100.0)  // NOT MaskPress
        let targetEPAP = percentiles(m, field: 20, scale: 100.0)
        let mskPress   = percentiles(m, field: 21, scale: 100.0)  // measured
        let tidalVol   = percentiles(m, field: 22, scale: 100.0)  // L (not leak)
        let minuteVent = percentiles(m, field: 23, scale: 100.0)
        let respRate   = percentiles(m, field: 25, scale: 100.0)
        let leakPct    = leakPercentiles(m, field: 14, scale: 100.0)  // L/s × 100
        let sessions   = decodeSessions(m, clockOffsetSeconds: clockOffsetSeconds)
        let maskEvents = Int(firstVarint(m, field: 39) ?? 0)

        // Climate medians (each is a percentile sub-message; .50 lives
        // at inner sub-field 2, value × 100 for the real unit).
        func medianOf(_ field: Int, scale: Double) -> Double? {
            guard let submsg = m[field]?.first,
                  case .message(let sub) = submsg,
                  let v = firstVarint(sub, field: 2) else { return nil }
            return Double(v) / scale
        }
        let ambHum   = medianOf(29, scale: 100.0)  // mg/L
        let htubeTmp = medianOf(31, scale: 100.0)  // °C
        let humPow   = medianOf(32, scale: 100.0)  // %
        let htubePow = medianOf(33, scale: 100.0)  // %

        // Everything we didn't consume above goes into unknownFields for
        // later investigation. Skip the fields we already mapped.
        let mapped: Set<Int> = [2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13,
                                14, 15, 20, 21, 22, 23, 25, 29, 31, 32, 33, 39, 40]
        var unknown: [Int: RawField] = [:]
        for (fld, vals) in m where !mapped.contains(fld) {
            if let v = vals.first {
                unknown[fld] = v
            }
        }

        return DaySummary(
            startDate: Date(timeIntervalSince1970: Double(startMs) / 1000.0),
            endDate:   Date(timeIntervalSince1970: Double(endMs) / 1000.0),
            maskDurationMinutes: maskDurMin,
            recordGeneratedAt: Date(timeIntervalSince1970: Double(generatedMs) / 1000.0),
            ahi: indexField(7),
            ai:  indexField(8),
            hi:  indexField(9),
            oai: indexField(10),
            cai: indexField(11),
            uai: indexField(12),
            rin: indexField(13),
            maskPressure: mskPress,
            targetIPAP: targetIPAP,
            targetEPAP: targetEPAP,
            leak: leakPct,
            tidalVolume: tidalVol,
            minuteVentilation: minuteVent,
            respiratoryRate: respRate,
            maskEventCount: maskEvents,
            ambientHumidity: ambHum,
            heatedTubeTemp: htubeTmp,
            humidifierPower: humPow,
            heatedTubePower: htubePow,
            sessions: sessions,
            unknownFields: unknown
        )
    }

    /// Decode the 4-level leak percentile message at the given field.
    /// Sub-fields 2/3/4/5 carry {p50, p70, p95, max} as integer varints.
    private static func leakPercentiles(_ m: [Int: [RawField]], field: Int, scale: Double) -> DaySummary.LeakPercentiles? {
        guard let submsg = m[field]?.first,
              case .message(let sub) = submsg else { return nil }
        let p50 = Double(firstVarint(sub, field: 2) ?? 0) / scale
        let p70 = Double(firstVarint(sub, field: 3) ?? 0) / scale
        let p95 = Double(firstVarint(sub, field: 4) ?? 0) / scale
        let max = Double(firstVarint(sub, field: 5) ?? 0) / scale
        return DaySummary.LeakPercentiles(p50: p50, p70: p70, p95: p95, max: max)
    }

    /// Decode the per-session list from protobuf field 6.
    ///
    /// Wire format:
    ///   field 6: message {
    ///     repeated SessionEntry entry = 1;
    ///   }
    ///   SessionEntry { int64 ts_ms = 1; int32 duration_min = 2; }
    ///
    /// Ground-truth correspondence (2026-04-11 capture, NY user's
    /// April 10 night): durations 285/265 minutes in entries 1/2
    /// matched the user's two main sleep sessions (284/265 min)
    /// almost exactly. Timestamps are stored in the CPAP's internal
    /// UTC clock, which may drift from real UTC (seen ~1h drift
    /// when CPAP doesn't observe DST). `clockOffsetSeconds` shifts
    /// timestamps back to real UTC; the raw millisecond value is
    /// also preserved for stable dedup keys.
    private static func decodeSessions(_ m: [Int: [RawField]],
                                       clockOffsetSeconds: TimeInterval = 0) -> [DaySummary.Session] {
        guard let field6 = m[6]?.first,
              case .message(let inner) = field6,
              let entries = inner[1] else { return [] }
        var out: [DaySummary.Session] = []
        for entry in entries {
            guard case .message(let em) = entry,
                  let tsMs = firstVarint(em, field: 1),
                  let durMin = firstVarint(em, field: 2) else { continue }
            let rawDate = Date(timeIntervalSince1970: Double(tsMs) / 1000.0)
            out.append(DaySummary.Session(
                startDate: rawDate.addingTimeInterval(-clockOffsetSeconds),
                durationMinutes: Int(durMin),
                rawStartMs: tsMs
            ))
        }
        return out
    }

    /// Extract a `Percentiles` triple from a nested-message field whose
    /// sub-fields 2/3/4 carry p50/max/p95 raw int values. Scale factor
    /// converts raw to physical units (e.g. 100 for cmH₂O × 100).
    private static func percentiles(_ m: [Int: [RawField]], field: Int, scale: Double) -> DaySummary.Percentiles? {
        guard let submsg = m[field]?.first,
              case .message(let sub) = submsg else { return nil }
        let p50 = Double(firstVarint(sub, field: 2) ?? 0) / scale
        let p95 = Double(firstVarint(sub, field: 3) ?? 0) / scale
        let max = Double(firstVarint(sub, field: 4) ?? 0) / scale
        return DaySummary.Percentiles(p50: p50, p95: p95, max: max)
    }

    private static func firstVarint(_ m: [Int: [RawField]], field: Int) -> UInt64? {
        guard let v = m[field]?.first else { return nil }
        if case .varint(let u) = v { return u }
        return nil
    }

    // MARK: - Generic protobuf wire walker

    /// Parse a protobuf message into a field-number → values dictionary.
    /// Recursively interprets length-delimited fields as either messages
    /// or raw bytes: a blob is treated as a message iff it parses cleanly
    /// end-to-end, otherwise it's kept as `.bytes`.
    private static func parseMessage(_ data: Data) throws -> [Int: [RawField]] {
        var out: [Int: [RawField]] = [:]
        var i = 0
        while i < data.count {
            let (tag, nextI) = try readVarint(data, at: i)
            i = nextI
            let field = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            if field == 0 {
                throw SpoolDecoderError.parseError("field number 0")
            }
            let value: RawField
            switch wireType {
            case 0: // varint
                let (v, n) = try readVarint(data, at: i); i = n
                value = .varint(v)
            case 1: // fixed64
                guard i + 8 <= data.count else { throw SpoolDecoderError.truncated }
                var u: UInt64 = 0
                for byte in (0..<8).reversed() {
                    u = (u << 8) | UInt64(data[data.startIndex + i + byte])
                }
                i += 8
                value = .fixed64(u)
            case 2: // length-delimited
                let (length, n) = try readVarint(data, at: i); i = n
                let end = i + Int(length)
                guard end <= data.count else { throw SpoolDecoderError.truncated }
                let blob = data.subdata(in: (data.startIndex + i)..<(data.startIndex + end))
                i = end
                if let sub = try? parseMessage(blob) {
                    value = .message(sub)
                } else {
                    value = .bytes(blob)
                }
            case 5: // fixed32
                guard i + 4 <= data.count else { throw SpoolDecoderError.truncated }
                var u: UInt32 = 0
                for byte in (0..<4).reversed() {
                    u = (u << 8) | UInt32(data[data.startIndex + i + byte])
                }
                i += 4
                value = .fixed32(u)
            default:
                throw SpoolDecoderError.invalidWireType(wireType)
            }
            out[field, default: []].append(value)
        }
        return out
    }

    /// Decode one varint starting at `offset`, returning the value and
    /// the offset one byte past its last byte.
    private static func readVarint(_ data: Data, at offset: Int) throws -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset
        while i < data.count {
            let byte = data[data.startIndex + i]
            result |= UInt64(byte & 0x7f) << shift
            i += 1
            if (byte & 0x80) == 0 {
                return (result, i)
            }
            shift += 7
            if shift >= 64 {
                throw SpoolDecoderError.parseError("varint overflow")
            }
        }
        throw SpoolDecoderError.truncated
    }
}
