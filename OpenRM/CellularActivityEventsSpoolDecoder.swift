//
//  CellularActivityEventsSpoolDecoder.swift
//  OpenRM
//
//  Decoder for AirSense 11 `CellularActivityEvents` spool fragments.
//
//  A log of the device's internal LTE modem lifecycle — power-on,
//  registration, data-session open/close, sync start/end, failure codes,
//  signal-strength samples. Useful for diagnosing "why didn't my myAir
//  update last night" without reaching for carrier tools.
//
//  Wire format (reverse-engineered 2026-04-15 from the first 500 bytes
//  of a real capture — 25 events decoded cleanly, spanning 24 hours):
//
//    Root message {
//      field 12: bytes  // length-delimited wrapper, holds the full
//                       // repeated event list for the whole spool.
//    }
//    Wrapper {
//      repeated CellularEvent events = 1;
//    }
//    CellularEvent {
//      int32 eventType     = 1;   // enum, see table below.
//      int64 timestampMs   = 2;   // start-of-event ms since UTC epoch.
//      int64 endTimestampMs = 3;  // end-of-event ms. For instantaneous
//                                 // events (most) == field 2. When an
//                                 // event has nonzero duration this
//                                 // will be later than field 2.
//      // ---- Optional type-tagged side payloads. The *field number*
//      //      carrying the extra value is keyed to `eventType` — the
//      //      device uses a sparse-union layout where a given type's
//      //      payload always lands on the same sub-field. Observed
//      //      (type → field) bindings:
//      //         5  → field 5   (small int, 4 in capture — count?)
//      //         13 → field 6   (unknown small int)
//      //         24 → field 16  (observed value 1 — flag)
//      //         60 → field 8   (observed 260 — likely RSSI or rel
//      //                         signal power in dBm×N)
//      //         61 → field 9   (observed 310 — likely RSRP/RSRQ value)
//      //         87 → field 12  (observed 224894742 — bytes-transferred
//      //                         or session-duration-ms; magnitude is
//      //                         plausible for a 200 MB sync)
//      //         90 → field 13  (observed small ints 3, 11, 12 — likely
//      //                         retry-count or failure-reason code)
//    }
//
//  Event-type enum (seen so far; names are guesses, NOT ground-truthed):
//    2    — possibly "modem-ready"          (paired with type 3/9/60/61)
//    3    — possibly "registration-request"
//    5    — "something with a small count"
//    6    — ?
//    7    — appears late in sync clusters; "session-closed"?
//    9    — ?
//    10   — ?
//    11   — ?
//    13   — paired with side-field 6
//    23   — rare
//    24   — pairs with a flag; possibly "modem-power-on"
//    60   — RSSI/signal sample
//    61   — secondary signal metric sample
//    87   — data-session-complete; side payload = bytes transferred or
//           duration-ms (~225 M suggests bytes).
//    90   — retry/backoff event; appears in bursts of 3-5 within seconds
//
//  Observed pattern: type 24 opens a modem cycle; types 2/3/9/60/61/5/7
//  fire in a tight cluster within ~1 second (registration + first data
//  session); type 87 closes with a bytes-transferred count; bursts of
//  type 90 indicate retry storms when the network was flaky.
//
//  Validation TODO: pull a full `.bin` from the iPad container and a
//  carrier-side log (or just correlate the type 87 byte-counts against
//  myAir session sizes seen that night) to nail down event-type names.
//

import Foundation

/// One cellular-modem event emitted by the CPAP's internal LTE radio.
struct CellularActivityEvent {
    /// Start time in real UTC (`clockOffsetSeconds` already subtracted).
    let timestamp: Date
    /// End time in real UTC. Equal to `timestamp` for instantaneous events.
    let endTimestamp: Date
    /// Raw start-ms as recorded by the CPAP — stable dedup key.
    let rawTimestampMs: UInt64
    /// Raw end-ms as recorded by the CPAP.
    let rawEndTimestampMs: UInt64
    /// Event-type enum value. See file header for the in-progress name
    /// table.
    let eventType: Int
    /// Type-tagged side payload, if any. The protobuf field number on
    /// which this landed is kept so future reverse-engineering can
    /// disambiguate overlapping types.
    let payload: Payload?

    struct Payload {
        /// The protobuf field number this value arrived on. Lets callers
        /// distinguish between payload types without losing the raw tag.
        let fieldNumber: Int
        /// The integer value itself. All observed payloads have been
        /// unsigned varints so far.
        let value: UInt64
    }
}

enum CellularActivityEventsSpoolDecoderError: Error {
    case truncated
    case invalidWireType(Int)
    case parseError(String)
}

enum CellularActivityEventsSpoolDecoder {

    /// - Parameter clockOffsetSeconds: see `SummarySpoolDecoder.decode`.
    static func decode(_ data: Data,
                       clockOffsetSeconds: TimeInterval = 0) throws -> [CellularActivityEvent] {
        let wrapper = try extractOuterWrapper(data, field: 12)
        return parseEvents(wrapper, clockOffsetSeconds: clockOffsetSeconds)
    }

    private static func parseEvents(_ data: Data,
                                    clockOffsetSeconds: TimeInterval) -> [CellularActivityEvent] {
        var out: [CellularActivityEvent] = []
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { break }
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if wt != 2 {
                guard let skipped = try? skipField(data, at: next, wireType: wt) else { break }
                i = skipped
                continue
            }
            guard let (length, n2) = try? readVarint(data, at: next) else { break }
            let end = n2 + Int(length)
            guard end <= data.count else { break }
            let savedEnd = end
            i = savedEnd
            guard fn == 1 else { continue }
            let blob = data.subdata(in: (data.startIndex + n2)..<(data.startIndex + savedEnd))
            if let event = parseEvent(blob, clockOffsetSeconds: clockOffsetSeconds) {
                out.append(event)
            }
        }
        return out
    }

    private static func parseEvent(_ data: Data,
                                   clockOffsetSeconds: TimeInterval) -> CellularActivityEvent? {
        var eventType = 0
        var startMs: UInt64 = 0
        var endMs: UInt64 = 0
        var payload: CellularActivityEvent.Payload?
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { return nil }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            switch (fn, wt) {
            case (1, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                eventType = Int(v); i = n
            case (2, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                startMs = v; i = n
            case (3, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                endMs = v; i = n
            default:
                // Any other varint is a candidate side payload. If
                // multiple show up on the same event we keep only the
                // first — no multi-payload cellular event has been
                // observed yet.
                if wt == 0 {
                    guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                    if payload == nil {
                        payload = CellularActivityEvent.Payload(fieldNumber: fn, value: v)
                    }
                    i = n
                } else {
                    guard let skipped = try? skipField(data, at: i, wireType: wt) else { return nil }
                    i = skipped
                }
            }
        }
        guard startMs > 0 else { return nil }
        if endMs == 0 { endMs = startMs }
        let rawStart = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000.0)
        let rawEnd   = Date(timeIntervalSince1970: TimeInterval(endMs)   / 1000.0)
        return CellularActivityEvent(
            timestamp: rawStart.addingTimeInterval(-clockOffsetSeconds),
            endTimestamp: rawEnd.addingTimeInterval(-clockOffsetSeconds),
            rawTimestampMs: startMs,
            rawEndTimestampMs: endMs,
            eventType: eventType,
            payload: payload
        )
    }

    // MARK: - Shared plumbing

    private static func extractOuterWrapper(_ data: Data, field: Int) throws -> Data {
        var i = 0
        while i < data.count {
            let (tag, next) = try readVarint(data, at: i)
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if wt == 2 {
                let (length, n2) = try readVarint(data, at: i)
                let declaredEnd = n2 + Int(length)
                let actualEnd = min(declaredEnd, data.count)
                if fn == field {
                    return data.subdata(in: (data.startIndex + n2)..<(data.startIndex + actualEnd))
                }
                i = actualEnd
            } else {
                i = try skipField(data, at: i, wireType: wt)
            }
        }
        throw CellularActivityEventsSpoolDecoderError.parseError("outer field \(field) not found")
    }

    private static func skipField(_ data: Data, at offset: Int, wireType: Int) throws -> Int {
        switch wireType {
        case 0:
            let (_, n) = try readVarint(data, at: offset); return n
        case 1:
            guard offset + 8 <= data.count else { throw CellularActivityEventsSpoolDecoderError.truncated }
            return offset + 8
        case 2:
            let (length, n) = try readVarint(data, at: offset)
            let end = n + Int(length)
            guard end <= data.count else { throw CellularActivityEventsSpoolDecoderError.truncated }
            return end
        case 5:
            guard offset + 4 <= data.count else { throw CellularActivityEventsSpoolDecoderError.truncated }
            return offset + 4
        default:
            throw CellularActivityEventsSpoolDecoderError.invalidWireType(wireType)
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
            if shift >= 64 { throw CellularActivityEventsSpoolDecoderError.parseError("varint overflow") }
        }
        throw CellularActivityEventsSpoolDecoderError.truncated
    }
}
