//
//  PerMinuteSpoolDecoder.swift
//  OpenRM
//
//  Decoder for AirSense 11 `TherapyOneMinutePeriodic` spool fragments.
//
//  Unlike the `Summary` spool (one record per day, field-tagged percentiles),
//  this spool contains per-session blobs with seven channel arrays storing
//  one value per minute of therapy. Channels are encoded with a custom
//  Rice-Golomb variant that was reverse-engineered on 2026-04-12 by
//  cross-referencing five BLE captures against the SD-card PLD.edf ground
//  truth. Validated at 0.9966 correlation for MaskPress (field 2) across
//  five sessions with a perfect 10/10 match on one short session.
//
//  Encoding (fields 2..7):
//    1. values[i] = round(physical × scale)  (scale varies per channel)
//    2. Blob starts with a 4-byte header: 2 × uint16 LE = values[0], values[1]
//    3. Second-order prediction residuals:
//         r[i] = values[i+2] - 2*values[i+1] + values[i]
//       (linear extrapolation — the predictor assumes the slope continues)
//    4. Zigzag encode residuals (signed → unsigned)
//    5. Rice-Golomb with a *per-field* k. MaskPress/TidVol/MinVent/Snore
//       use k=2; the set-pressure channel (field 3) uses k=1; RespRate
//       (field 4) uses k=3. Using the wrong k produces plausible-looking
//       garbage — sustained small drift rather than an obvious failure.
//    6. Bit packing is MSB-first within each byte (unary first, then 0, then
//       the k remainder bits MSB-first)
//
//  Field 1 uses a different encoding (8-byte header, possibly event counts
//  or flags) — not decoded by this module.
//
//  Channel mapping (fully validated 2026-04-12 via 21-session BLE capture
//  cross-referenced against SD-card PLD.edf with MaskPress-shape alignment):
//    f1 — Leak      (L/s × 50),     k=2, corr +0.987  (yes — f1 uses the
//                                                      same pipeline; the
//                                                      "8-byte header" was
//                                                      a red herring from
//                                                      long zero runs)
//    f2 — MaskPress (cmH₂O × 5),    k=2, corr +0.996
//    f3 — Press     (cmH₂O × 5),    k=1, corr +0.994  (set/target pressure)
//    f4 — RespRate  (br/min × 4),   k=3, corr +0.979
//    f5 — TidVol    (L × 25),        k=2, corr +0.74
//    f6 — MinVent   (L/min × 2.5),  k=2, corr +0.85
//    f7 — unidentified              k=2, not RespRate, not Snore — possibly
//                                                      RR95 (95th-percentile
//                                                      breath rate) or some
//                                                      TidVol variant not
//                                                      present in PLD.edf
//
//  Snore and FlowLim are NOT in this spool. Both appear only in SD-card
//  PLD.edf (and snore is near-zero flat for most therapy anyway).
//
//

import Foundation

/// One channel of per-minute telemetry decoded from a
/// `TherapyOneMinutePeriodic` spool. Raw `values` are integer (scaled)
/// samples; use `physicalValues` to recover the floating-point physical
/// quantity in the channel's natural units.
struct PerMinuteChannel {
    /// Semantic meaning of a channel. Kept in sync with the field → PLD
    /// mapping validated against the SD-card PLD.edf ground truth.
    enum Kind: Int {
        case leak         = 1   // L/s  (yes, f1 — not a metadata field)
        case maskPressure = 2   // cmH₂O
        case setPressure  = 3   // cmH₂O  (set/target pressure)
        case respRate     = 4   // breaths/min
        case tidalVolume  = 5   // liters
        case minuteVent   = 6   // L/min
        case unknownF7    = 7   // not RespRate, not Snore — identity TBD

        /// Physical value = raw / wireScale.
        var wireScale: Double {
            switch self {
            case .leak:         return 50.0
            case .maskPressure: return 5.0
            case .setPressure:  return 5.0
            case .respRate:     return 4.0
            case .tidalVolume:  return 25.0
            case .minuteVent:   return 2.5
            case .unknownF7:    return 1.0
            }
        }

        /// Rice k to use for the decoder loop. Using the wrong k produces
        /// plausible-looking garbage, not an obvious parse failure.
        var riceK: Int {
            switch self {
            case .setPressure: return 1
            case .respRate:    return 3
            default:           return 2
            }
        }

        var label: String {
            switch self {
            case .leak:         return "Leak"
            case .maskPressure: return "MaskPress"
            case .setPressure:  return "Press"
            case .respRate:     return "RespRate"
            case .tidalVolume:  return "TidVol"
            case .minuteVent:   return "MinVent"
            case .unknownF7:    return "f7?"
            }
        }

        var unit: String {
            switch self {
            case .leak:        return "L/s"
            case .maskPressure, .setPressure: return "cmH₂O"
            case .respRate:    return "br/min"
            case .tidalVolume: return "L"
            case .minuteVent:  return "L/min"
            case .unknownF7:   return ""
            }
        }
    }

    /// Which protobuf field this blob came from (2..7).
    let fieldNumber: Int
    /// Semantic meaning, derived from `fieldNumber`.
    let kind: Kind
    /// Decoded integer samples at the wire scale (one per minute).
    let values: [Int]
    /// The two header bytes as `(values[0], values[1])` for convenience.
    let header: (UInt16, UInt16)

    /// Values converted to the channel's natural physical unit.
    var physicalValues: [Double] {
        let s = kind.wireScale
        return values.map { Double($0) / s }
    }
}

/// One session's worth of per-minute telemetry.
struct PerMinuteSession {
    /// Session start in milliseconds since epoch (as reported by the CPAP,
    /// before any clock-drift correction).
    let timestampMs: UInt64
    /// Session start as a Swift `Date` — already shifted by the caller's
    /// `clockOffsetSeconds` so it lines up with real UTC.
    let startDate: Date
    /// One entry per channel blob (usually 7 entries, fields 1..7).
    let channels: [PerMinuteChannel]

    /// Convenience accessor for the channel at a specific protobuf field.
    func channel(field: Int) -> PerMinuteChannel? {
        channels.first { $0.fieldNumber == field }
    }
}

enum PerMinuteSpoolDecoderError: Error {
    case truncated
    case invalidWireType(Int)
    case parseError(String)
}

enum PerMinuteSpoolDecoder {

    /// Parse a full `TherapyOneMinutePeriodic` spool payload into sessions.
    ///
    /// Top-level protobuf structure (observed from five BLE captures):
    ///   field 5 (length-delimited, repeated) — Session
    ///     field 1..7 (length-delimited)      — Channel
    ///       field 1 (varint)  — version
    ///       field 2 (varint)  — timestamp_ms (session start)
    ///       field 3 (bytes)   — Rice-coded blob (header + payload)
    ///
    /// - Parameter clockOffsetSeconds: same semantics as `SummarySpoolDecoder`
    ///   — subtract to map the CPAP's internal UTC to real UTC.
    static func decode(_ data: Data,
                       clockOffsetSeconds: TimeInterval = 0) throws -> [PerMinuteSession] {
        var sessions: [PerMinuteSession] = []
        // Walk top-level: collect field 5 length-delimited blobs (each is
        // one session). Keep them as raw bytes so we don't accidentally
        // parse the Rice-coded channel payloads below.
        let sessionBlobs = try scanLengthDelimited(data, field: 5)
        for sessBlob in sessionBlobs {
            var channels: [PerMinuteChannel] = []
            var sessionTsMs: UInt64 = 0

            // Each session contains repeated channel entries at fields 1..7.
            // We walk the full wire stream once to preserve field ordering.
            for (fn, chBytes) in try walkLengthDelimited(sessBlob, fields: 1...7) {
                let (ts, rawData) = parseChannel(chBytes)
                if let ts = ts, sessionTsMs == 0 { sessionTsMs = ts }
                guard let rawData = rawData else { continue }
                guard let decoded = decodeBlob(rawData, fieldNumber: fn) else { continue }
                channels.append(decoded)
            }

            guard sessionTsMs > 0 else { continue }
            let raw = Date(timeIntervalSince1970: TimeInterval(sessionTsMs) / 1000.0)
            let start = raw.addingTimeInterval(-clockOffsetSeconds)
            sessions.append(PerMinuteSession(
                timestampMs: sessionTsMs,
                startDate: start,
                channels: channels
            ))
        }
        return sessions
    }

    // MARK: - Blob decoding (second-order prediction + Rice k=2)

    /// Decode one channel blob. Returns `nil` for field 1 (different
    /// encoding) or for malformed blobs.
    static func decodeBlob(_ blob: Data, fieldNumber: Int) -> PerMinuteChannel? {
        // Field 1 has an 8-byte uint32 header structure and a different
        // encoding (likely event counts/flags) — skip for now.
        guard let kind = PerMinuteChannel.Kind(rawValue: fieldNumber) else { return nil }
        guard blob.count >= 4 else { return nil }

        let k = kind.riceK
        let remainderMask = (1 << k) - 1

        // 4-byte header: 2 × uint16 LE = first two samples at wire scale.
        let b = [UInt8](blob)
        let h1 = UInt16(b[0]) | (UInt16(b[1]) << 8)
        let h2 = UInt16(b[2]) | (UInt16(b[3]) << 8)

        var values: [Int] = [Int(h1), Int(h2)]

        // Walk payload as MSB-first bits.
        let payload = Array(b[4...])
        let totalBits = payload.count * 8
        var pos = 0

        @inline(__always) func bitAt(_ i: Int) -> Int {
            let byte = payload[i >> 3]
            return (Int(byte) >> (7 - (i & 7))) & 1
        }

        // Need enough bits for a minimal code: 1 (terminator) + k (remainder).
        let minCodeBits = 1 + k
        while pos + minCodeBits <= totalBits {
            // Unary quotient: count leading 1s up to a 0 terminator.
            var q = 0
            while pos < totalBits && bitAt(pos) == 1 {
                q += 1
                pos += 1
            }
            if pos >= totalBits { break }
            pos += 1                                // skip the 0 terminator
            if pos + k > totalBits { break }

            // Read k-bit remainder MSB-first.
            var r = 0
            for j in 0..<k {
                r = (r << 1) | bitAt(pos + j)
            }
            r &= remainderMask
            pos += k

            // Bail out on runaway quotients — real streams rarely exceed
            // ~30 unary bits for a plausible residual; anything beyond
            // that is almost certainly trailing-zero padding we misread.
            if q > 48 { break }

            let zz = (q << k) | r                   // recombine Rice code
            let residual = (zz >> 1) ^ -(zz & 1)    // zigzag decode

            // Second-order prediction: next = residual + 2*prev - prev_prev
            let last = values[values.count - 1]
            let prev = values[values.count - 2]
            values.append(residual + 2 * last - prev)
        }

        return PerMinuteChannel(
            fieldNumber: fieldNumber,
            kind: kind,
            values: values,
            header: (h1, h2)
        )
    }

    // MARK: - Targeted protobuf walker
    //
    // We deliberately don't use a generic recursive parser here: the
    // Rice-coded channel payloads stored in field 3 of each channel are
    // arbitrary bytes that could accidentally parse as a valid protobuf
    // message and lose their identity. Instead, we walk the wire stream
    // one level at a time, pulling out the specific fields we care about.

    /// Collect all occurrences of `field` (wire type 2) from a single
    /// protobuf stream, returning the raw bytes of each. Non-matching
    /// fields are skipped correctly (including varint, fixed32, fixed64).
    private static func scanLengthDelimited(_ data: Data, field: Int) throws -> [Data] {
        var out: [Data] = []
        var i = 0
        while i < data.count {
            let (tag, next) = try readVarint(data, at: i)
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if wt == 2 {
                let (length, n) = try readVarint(data, at: i); i = n
                let end = i + Int(length)
                guard end <= data.count else { throw PerMinuteSpoolDecoderError.truncated }
                if fn == field {
                    out.append(data.subdata(in: (data.startIndex + i)..<(data.startIndex + end)))
                }
                i = end
            } else {
                i = try skipField(data, at: i, wireType: wt)
            }
        }
        return out
    }

    /// Walk all length-delimited fields whose number is in `fields` and
    /// yield `(fieldNumber, rawBytes)` pairs in stream order.
    private static func walkLengthDelimited(_ data: Data,
                                             fields: ClosedRange<Int>) throws -> [(Int, Data)] {
        var out: [(Int, Data)] = []
        var i = 0
        while i < data.count {
            let (tag, next) = try readVarint(data, at: i)
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if wt == 2 {
                let (length, n) = try readVarint(data, at: i); i = n
                let end = i + Int(length)
                guard end <= data.count else { throw PerMinuteSpoolDecoderError.truncated }
                if fields.contains(fn) {
                    out.append((fn, data.subdata(in: (data.startIndex + i)..<(data.startIndex + end))))
                }
                i = end
            } else {
                i = try skipField(data, at: i, wireType: wt)
            }
        }
        return out
    }

    /// Parse a channel wrapper to extract its timestamp (field 2) and
    /// raw Rice-coded payload (field 3). Anything else is ignored.
    private static func parseChannel(_ data: Data) -> (UInt64?, Data?) {
        var ts: UInt64?
        var raw: Data?
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { break }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            switch (fn, wt) {
            case (2, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return (ts, raw) }
                ts = v; i = n
            case (3, 2):
                guard let (length, n) = try? readVarint(data, at: i) else { return (ts, raw) }
                i = n
                let end = i + Int(length)
                guard end <= data.count else { return (ts, raw) }
                raw = data.subdata(in: (data.startIndex + i)..<(data.startIndex + end))
                i = end
            default:
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { return (ts, raw) }
                i = skipped
            }
        }
        return (ts, raw)
    }

    /// Move `offset` past a field with the given wire type.
    private static func skipField(_ data: Data, at offset: Int, wireType: Int) throws -> Int {
        switch wireType {
        case 0:
            let (_, n) = try readVarint(data, at: offset); return n
        case 1:
            guard offset + 8 <= data.count else { throw PerMinuteSpoolDecoderError.truncated }
            return offset + 8
        case 2:
            let (length, n) = try readVarint(data, at: offset)
            let end = n + Int(length)
            guard end <= data.count else { throw PerMinuteSpoolDecoderError.truncated }
            return end
        case 5:
            guard offset + 4 <= data.count else { throw PerMinuteSpoolDecoderError.truncated }
            return offset + 4
        default:
            throw PerMinuteSpoolDecoderError.invalidWireType(wireType)
        }
    }

    private static func readVarint(_ data: Data, at offset: Int) throws -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset
        while i < data.count {
            let byte = data[data.startIndex + i]
            result |= UInt64(byte & 0x7f) << shift
            i += 1
            if (byte & 0x80) == 0 { return (result, i) }
            shift += 7
            if shift >= 64 { throw PerMinuteSpoolDecoderError.parseError("varint overflow") }
        }
        throw PerMinuteSpoolDecoderError.truncated
    }
}
