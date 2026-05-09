//
//  DiagnosticTenMinutePeriodicSpoolDecoder.swift
//  OpenRM
//
//  Decoder for AirSense 11 `DiagnosticTenMinutePeriodic` spool fragments.
//
//  Discovered accessible to consumer-auth sessions on 2026-04-14. The spool
//  is the largest and densest observed so far (~30 KB over 119 fragments in
//  the first sample capture). Format is structurally similar to
//  `TherapyOneMinutePeriodic` but wraps its per-channel records in an outer
//  repeated envelope at field 17, and so far we have only observed two
//  channels (outer fields f2 and f5) rather than seven. Channel names for
//  this spool are NOT YET validated against the SD-card PLD.edf — see the
//  writeup for validation plan.
//
//  Outer wire schema (reverse-engineered from the first 500 bytes of sample
//  `DiagnosticTenMinutePeriodic_first500.hex`, captured 2026-04-14):
//
//      message DiagnosticTenMinutePeriodic {
//          repeated Record   records = 17;     // wire tag 0x8a 0x01
//      }
//      message Record {                         // inside each field-17 blob
//          uint32  version = 1;                 //   observed value: 1
//          Channel channelA = 2;                //   "outer-f2" channel
//          Channel channelB = 5;                //   "outer-f5" channel
//      }
//      message Channel {
//          uint32  channelKind = 1;             //   observed value: 10
//          uint64  timestampMs = 2;             //   ms-since-epoch (matches
//                                               //   across channelA/B of the
//                                               //   same Record)
//          bytes   samples = 3;                 //   2-byte or 4+N-byte blob
//      }
//
//  Sample blob encoding (identical family to `PerMinuteSpoolDecoder`):
//    - 2 bytes      → one int16 LE sample, no residuals (very short records)
//    - 4 bytes      → two int16 LE header samples, no residuals
//    - 4 + N bytes  → two int16 LE header samples followed by Rice-Golomb
//                     residuals over second-order prediction:
//                         r[i] = v[i+2] - 2*v[i+1] + v[i]
//                     zigzag(residual), unary quotient + k-bit remainder,
//                     MSB-first within each byte.
//
//  Rice-k per outer field (HIGH confidence — determined by cross-channel
//  sample-count consistency on record 2 of the first-500-byte sample:
//  both channels decode to exactly 398 samples only when using these k
//  values; other k values produce runaway drift):
//    outer f2 → k = 2
//    outer f5 → k = 1
//
//  Semantic identity of the two channels — LOW confidence:
//    Both channels decode to small, tightly-bounded integer sequences with
//    near-zero means (channelA ≈ -82, channelB ≈ -10 in the large record),
//    consistent with signed sensor readings around a calibrated baseline.
//    Plausible candidates — motor-current offset, flow-sensor zero, ambient
//    pressure reference, internal-temperature deviation, motor RPM trim —
//    but we have no ground truth in the 500-byte sample. Needs validation
//    against the SD-card DIAG.edf (or equivalent) once available.
//
//  Other open questions (MEDIUM/LOW confidence):
//    - Whether the full 30 KB spool contains additional outer fields (f3,
//      f4, f6, f7, …) that we simply haven't seen in the first 500 bytes.
//    - Whether records are emitted per-session, per-day, or on some other
//      cadence. Observed: 3 records over ~2h36m with varying sample counts
//      (1, 3, 398) — inconsistent with a simple "10 min/sample" model,
//      suggests sample count is event-driven within a record.
//    - Wire scale (values / scale → physical units) is unknown for both
//      channels. We expose raw integer samples only.
//
//  See also:
//    - PerMinuteSpoolDecoder.swift          (encoding reference)
//    - /archive/reverse_engineering/spool_diagnostictenminuteperiodic_format.md
//

import Foundation

/// One diagnostic channel decoded from a `DiagnosticTenMinutePeriodic`
/// record. Raw integer samples only — no physical-unit conversion is
/// applied because the wire scale is not yet known.
struct DiagnosticTenMinuteChannel {
    /// Which outer protobuf field this channel came from within its Record.
    /// We've observed 2 and 5 so far; others may exist in longer captures.
    enum Kind: Int {
        case channelA = 2
        case channelB = 5

        /// Rice k validated by cross-channel sample-count consistency.
        var riceK: Int {
            switch self {
            case .channelA: return 2
            case .channelB: return 1
            }
        }

        var label: String {
            switch self {
            case .channelA: return "diag_f2"
            case .channelB: return "diag_f5"
            }
        }
    }

    /// Outer field number (2 or 5).
    let outerField: Int
    /// Kind derived from `outerField`.
    let kind: Kind
    /// Inner f1 tag — observed as 10 for every channel so far. Preserved so
    /// callers can notice if a capture ever reports a different value.
    let channelKindTag: UInt64
    /// Decoded integer samples (signed). First two came from the header;
    /// the rest were reconstructed through the Rice + second-order path.
    let values: [Int]
    /// The two header int16s in capture order.
    let header: (Int16, Int16)?
}

/// One outer Record (field 17) from a `DiagnosticTenMinutePeriodic` spool.
/// Both channels share the same timestamp.
struct DiagnosticTenMinuteRecord {
    /// Version tag (inner f1) — observed value 1 on every record so far.
    let version: UInt64
    /// Timestamp common to both channels, already shifted by the caller's
    /// `clockOffsetSeconds`.
    let startDate: Date
    /// Raw ms-since-epoch as reported by the CPAP (before clock-offset).
    let timestampMs: UInt64
    /// Channels in capture order (expected: outer f2 then outer f5).
    let channels: [DiagnosticTenMinuteChannel]

    func channel(field: Int) -> DiagnosticTenMinuteChannel? {
        channels.first { $0.outerField == field }
    }
}

enum DiagnosticTenMinuteSpoolDecoderError: Error {
    case truncated
    case invalidWireType(Int)
    case parseError(String)
}

enum DiagnosticTenMinuteSpoolDecoder {

    /// Parse a full `DiagnosticTenMinutePeriodic` spool payload into records.
    ///
    /// - Parameter clockOffsetSeconds: same semantics as the other spool
    ///   decoders — subtract to map the CPAP's internal UTC to real UTC.
    static func decode(_ data: Data,
                       clockOffsetSeconds: TimeInterval = 0) throws -> [DiagnosticTenMinuteRecord] {
        var records: [DiagnosticTenMinuteRecord] = []

        let recordBlobs = try scanLengthDelimited(data, field: 17)
        for recBlob in recordBlobs {
            var version: UInt64 = 0
            var timestampMs: UInt64 = 0
            var channels: [DiagnosticTenMinuteChannel] = []

            let innerFields = try walkAllFields(recBlob)
            for (fn, wt, varintVal, bytesVal) in innerFields {
                switch (fn, wt) {
                case (1, 0):
                    version = varintVal
                case (2, 2), (5, 2):
                    guard let chBytes = bytesVal else { continue }
                    let (kindTag, ts, payload) = parseChannel(chBytes)
                    if timestampMs == 0, let ts = ts { timestampMs = ts }
                    guard let payload = payload, let kind = DiagnosticTenMinuteChannel.Kind(rawValue: fn) else { continue }
                    let decoded = decodeBlob(payload, outerField: fn, kind: kind, channelKindTag: kindTag ?? 0)
                    channels.append(decoded)
                default:
                    continue
                }
            }

            guard timestampMs > 0 else { continue }
            let raw = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
            let start = raw.addingTimeInterval(-clockOffsetSeconds)
            records.append(DiagnosticTenMinuteRecord(
                version: version,
                startDate: start,
                timestampMs: timestampMs,
                channels: channels
            ))
        }
        return records
    }

    // MARK: - Blob decoding (header + optional Rice-Golomb residuals)

    static func decodeBlob(_ blob: Data,
                           outerField: Int,
                           kind: DiagnosticTenMinuteChannel.Kind,
                           channelKindTag: UInt64) -> DiagnosticTenMinuteChannel {
        let b = [UInt8](blob)

        if b.count == 2 {
            let h1 = Int16(bitPattern: UInt16(b[0]) | (UInt16(b[1]) << 8))
            return DiagnosticTenMinuteChannel(
                outerField: outerField, kind: kind,
                channelKindTag: channelKindTag,
                values: [Int(h1)], header: (h1, 0)
            )
        }

        guard b.count >= 4 else {
            return DiagnosticTenMinuteChannel(
                outerField: outerField, kind: kind,
                channelKindTag: channelKindTag,
                values: [], header: nil
            )
        }

        let k = kind.riceK
        let remainderMask = (1 << k) - 1

        let h1 = Int16(bitPattern: UInt16(b[0]) | (UInt16(b[1]) << 8))
        let h2 = Int16(bitPattern: UInt16(b[2]) | (UInt16(b[3]) << 8))
        var values: [Int] = [Int(h1), Int(h2)]

        let payload = Array(b[4...])
        let totalBits = payload.count * 8
        var pos = 0

        @inline(__always) func bitAt(_ i: Int) -> Int {
            let byte = payload[i >> 3]
            return (Int(byte) >> (7 - (i & 7))) & 1
        }

        let minCodeBits = 1 + k
        while pos + minCodeBits <= totalBits {
            var q = 0
            while pos < totalBits && bitAt(pos) == 1 {
                q += 1
                pos += 1
            }
            if pos >= totalBits { break }
            pos += 1
            if pos + k > totalBits { break }

            var r = 0
            for j in 0..<k {
                r = (r << 1) | bitAt(pos + j)
            }
            r &= remainderMask
            pos += k

            if q > 48 { break }

            let zz = (q << k) | r
            let residual = (zz >> 1) ^ -(zz & 1)

            let last = values[values.count - 1]
            let prev = values[values.count - 2]
            values.append(residual + 2 * last - prev)
        }

        return DiagnosticTenMinuteChannel(
            outerField: outerField, kind: kind,
            channelKindTag: channelKindTag,
            values: values, header: (h1, h2)
        )
    }

    // MARK: - Targeted protobuf walker (copied pattern from PerMinuteSpoolDecoder)

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
                guard end <= data.count else { throw DiagnosticTenMinuteSpoolDecoderError.truncated }
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

    /// Walk every field in a message and return `(fieldNumber, wireType,
    /// varintValue, bytesValue)` tuples. Only varint and length-delimited
    /// fields populate their respective values; others return `nil` for both.
    private static func walkAllFields(_ data: Data) throws -> [(Int, Int, UInt64, Data?)] {
        var out: [(Int, Int, UInt64, Data?)] = []
        var i = 0
        while i < data.count {
            let (tag, next) = try readVarint(data, at: i); i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            switch wt {
            case 0:
                let (v, n) = try readVarint(data, at: i); i = n
                out.append((fn, wt, v, nil))
            case 2:
                let (length, n) = try readVarint(data, at: i); i = n
                let end = i + Int(length)
                guard end <= data.count else { throw DiagnosticTenMinuteSpoolDecoderError.truncated }
                let bytes = data.subdata(in: (data.startIndex + i)..<(data.startIndex + end))
                out.append((fn, wt, 0, bytes))
                i = end
            case 1:
                guard i + 8 <= data.count else { throw DiagnosticTenMinuteSpoolDecoderError.truncated }
                i += 8
            case 5:
                guard i + 4 <= data.count else { throw DiagnosticTenMinuteSpoolDecoderError.truncated }
                i += 4
            default:
                throw DiagnosticTenMinuteSpoolDecoderError.invalidWireType(wt)
            }
        }
        return out
    }

    /// Inside a Channel blob (outer f2 or f5), pull the channel-kind tag
    /// (inner f1), the timestamp (inner f2) and the raw sample bytes
    /// (inner f3). Anything else is ignored.
    private static func parseChannel(_ data: Data) -> (UInt64?, UInt64?, Data?) {
        var kindTag: UInt64?
        var ts: UInt64?
        var raw: Data?
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { break }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            switch (fn, wt) {
            case (1, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return (kindTag, ts, raw) }
                kindTag = v; i = n
            case (2, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return (kindTag, ts, raw) }
                ts = v; i = n
            case (3, 2):
                guard let (length, n) = try? readVarint(data, at: i) else { return (kindTag, ts, raw) }
                i = n
                let end = i + Int(length)
                guard end <= data.count else { return (kindTag, ts, raw) }
                raw = data.subdata(in: (data.startIndex + i)..<(data.startIndex + end))
                i = end
            default:
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { return (kindTag, ts, raw) }
                i = skipped
            }
        }
        return (kindTag, ts, raw)
    }

    private static func skipField(_ data: Data, at offset: Int, wireType: Int) throws -> Int {
        switch wireType {
        case 0:
            let (_, n) = try readVarint(data, at: offset); return n
        case 1:
            guard offset + 8 <= data.count else { throw DiagnosticTenMinuteSpoolDecoderError.truncated }
            return offset + 8
        case 2:
            let (length, n) = try readVarint(data, at: offset)
            let end = n + Int(length)
            guard end <= data.count else { throw DiagnosticTenMinuteSpoolDecoderError.truncated }
            return end
        case 5:
            guard offset + 4 <= data.count else { throw DiagnosticTenMinuteSpoolDecoderError.truncated }
            return offset + 4
        default:
            throw DiagnosticTenMinuteSpoolDecoderError.invalidWireType(wireType)
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
            if shift >= 64 { throw DiagnosticTenMinuteSpoolDecoderError.parseError("varint overflow") }
        }
        throw DiagnosticTenMinuteSpoolDecoderError.truncated
    }
}
