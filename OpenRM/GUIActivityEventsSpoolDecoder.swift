//
//  GUIActivityEventsSpoolDecoder.swift
//  OpenRM
//
//  Decoder for AirSense 11 `GUIActivityEvents` spool fragments.
//
//  A ring-buffer-style log of user-facing UI events (button presses, screen
//  transitions, menu taps) emitted by the device. Useful as a poor-man's
//  sleep-onset/offset signal when paired with a specific event-code table:
//  "START pressed" and "STOP pressed" codes, once identified, straddle
//  therapy sessions precisely (the ResMed STR.edf MaskOn/MaskOff ticks
//  typically trail these by 5-20 seconds).
//
//  Wire format (reverse-engineered 2026-04-15 from the first 500 bytes of
//  a real capture — 37 events decoded cleanly):
//
//    Root message {
//      field 13: bytes  // length-delimited wrapper around all events.
//                       // Runs the full length of the spool (~32 KB for
//                       // a device that's been running ~9 months). The
//                       // outer field number 13 appears to be a simple
//                       // "GUIActivityEvents body" tag and is stable
//                       // across fragments.
//    }
//    Wrapper {
//      repeated GUIEvent events = 1;
//    }
//    GUIEvent {
//      int32  version    = 1;   // always 1 in captures
//      int64  timestampMs = 2;  // ms since UTC epoch
//      int32  eventCode  = 3;   // small-integer enum, see below
//    }
//
//  Event-code enum (PARTIAL — inferred from frequencies in a 37-event
//  slice, not yet ground-truthed against observed user actions):
//    1    (most common, 12/37) — probably a heartbeat or screen-redraw
//                                tick. Candidate: "idle/home-screen
//                                reached".
//    7, 8, 9, 10                — small cluster, appear near each other
//                                in time. Candidate: menu navigation.
//    20, 30, 49, 52, 55, 63, 75 — sparse. Candidate: settings screens.
//    77, 82                     — appear in pairs near clusters with
//                                 rapid timestamps. Candidate: START
//                                 (77) / STOP (82) or mask-fit-test.
//    208, 219                   — rare three-digit values. Candidate:
//                                 error or alarm codes.
//
//  Two timestamps at the very start of the spool fall in 2011 and 2012
//  (1325376099218 ms = 2011-12-31; 1328559979996 = 2012-02-06). These are
//  clearly factory-fixture/RTC-not-yet-set records written before the
//  device saw a real clock. The decoder exposes them but consumers should
//  filter out events prior to ~2020.
//
//  Validation TODO: capture one full `.bin` from the iPad app container
//  (Xcode → Devices → Download Container → spool_GUIActivityEvents_*.bin),
//  plus a known user-action timeline (e.g. "pressed START at 21:13,
//  pressed STOP at 06:02"), and correlate event codes to button presses.
//

import Foundation

/// A single user-facing GUI event as reported by the CPAP.
struct GUIActivityEvent {
    /// UTC timestamp corrected for the device's clock drift (the caller's
    /// `clockOffsetSeconds` has been subtracted).
    let timestamp: Date
    /// Raw millisecond timestamp as recorded by the CPAP, BEFORE drift
    /// correction. Use this as the stable dedup key.
    let rawTimestampMs: UInt64
    /// Small-integer event code. Semantics partially inferred — see the
    /// file-header comment for the current best-guess table.
    let eventCode: Int
    /// Wire version tag (always 1 in current captures).
    let version: Int
}

enum GUIActivityEventsSpoolDecoderError: Error {
    case truncated
    case invalidWireType(Int)
    case parseError(String)
}

/// Decodes the `GUIActivityEvents` spool. The spool stores one big
/// length-delimited message at field 13 containing the full repeated
/// event list; on a truncated capture (e.g. only the first N fragments
/// assembled) `decode` will parse as many events as fit cleanly and stop.
enum GUIActivityEventsSpoolDecoder {

    /// - Parameter clockOffsetSeconds: see `SummarySpoolDecoder.decode`.
    ///   Subtracted from each timestamp so callers see real UTC.
    static func decode(_ data: Data,
                       clockOffsetSeconds: TimeInterval = 0) throws -> [GUIActivityEvent] {
        // Grab the outer wrapper blob (field 13). If the spool was
        // truncated mid-fragment the declared length may exceed what's
        // available — in that case fall back to parsing the remainder.
        let wrapper = try extractOuterWrapper(data, field: 13)
        return parseEvents(wrapper, clockOffsetSeconds: clockOffsetSeconds)
    }

    private static func parseEvents(_ data: Data,
                                    clockOffsetSeconds: TimeInterval) -> [GUIActivityEvent] {
        var out: [GUIActivityEvent] = []
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
            defer { i = end }
            i = end
            guard fn == 1 else { continue }
            let blob = data.subdata(in: (data.startIndex + n2)..<(data.startIndex + end))
            if let event = parseEvent(blob, clockOffsetSeconds: clockOffsetSeconds) {
                out.append(event)
            }
        }
        return out
    }

    private static func parseEvent(_ data: Data,
                                   clockOffsetSeconds: TimeInterval) -> GUIActivityEvent? {
        var version = 0
        var tsMs: UInt64 = 0
        var code = 0
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { return nil }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            switch (fn, wt) {
            case (1, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                version = Int(v); i = n
            case (2, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                tsMs = v; i = n
            case (3, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                code = Int(v); i = n
            default:
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { return nil }
                i = skipped
            }
        }
        guard tsMs > 0 else { return nil }
        let raw = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0)
        return GUIActivityEvent(
            timestamp: raw.addingTimeInterval(-clockOffsetSeconds),
            rawTimestampMs: tsMs,
            eventCode: code,
            version: version
        )
    }

    // MARK: - Shared outer-wrapper extraction

    /// Pull the bytes of the first length-delimited field with the given
    /// number. If the declared length exceeds the buffer (truncated
    /// capture) return whatever remains — the event walker is tolerant of
    /// a cut-short tail.
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
        throw GUIActivityEventsSpoolDecoderError.parseError("outer field \(field) not found")
    }

    private static func skipField(_ data: Data, at offset: Int, wireType: Int) throws -> Int {
        switch wireType {
        case 0:
            let (_, n) = try readVarint(data, at: offset); return n
        case 1:
            guard offset + 8 <= data.count else { throw GUIActivityEventsSpoolDecoderError.truncated }
            return offset + 8
        case 2:
            let (length, n) = try readVarint(data, at: offset)
            let end = n + Int(length)
            guard end <= data.count else { throw GUIActivityEventsSpoolDecoderError.truncated }
            return end
        case 5:
            guard offset + 4 <= data.count else { throw GUIActivityEventsSpoolDecoderError.truncated }
            return offset + 4
        default:
            throw GUIActivityEventsSpoolDecoderError.invalidWireType(wireType)
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
            if shift >= 64 { throw GUIActivityEventsSpoolDecoderError.parseError("varint overflow") }
        }
        throw GUIActivityEventsSpoolDecoderError.truncated
    }
}
