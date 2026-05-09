//
//  SettingProfilesCollectionSpoolDecoder.swift
//  OpenRM
//
//  Decoder for AirSense 11 `SettingProfilesCollection` spool fragments.
//
//  A full historical log of every *therapy-setting profile* the device
//  has ever been configured with — effectively a change-journal for the
//  clinician/user-adjustable parameters. Each record is a self-contained
//  snapshot: list of which setting-IDs are present, the allowed range
//  for each, and the actual value for each. Multiple records = the
//  history of mutations over time, keyed by a timestamp at the top of
//  each record.
//
//  Wire format (reverse-engineered 2026-04-15 from the first 500 bytes
//  of a real capture — 2 full records decoded cleanly, 1 truncated):
//
//    Root message {
//      repeated Profile records = 3;   // one record per historical
//                                      // setting-profile snapshot.
//    }
//    Profile {
//      Header    header   = 1;
//      SettingList ids    = 2;
//      RangeSpecs  ranges = 3;
//      Values      values = 4;
//    }
//    Header {
//      int64  changeTimestampMs = 1;  // when this profile became active.
//                                     // The very first record has no
//                                     // name and a ts matching device
//                                     // commission date; the second is
//                                     // the "MFGShipState" factory
//                                     // profile 2s later.
//      bytes  name              = 3;  // UTF-8 profile name, e.g.
//                                     // "MFGShipState". May be empty
//                                     // for the pre-ship zero record.
//      int32  flag              = 4;  // observed 0 — unknown.
//    }
//    SettingList {
//      int32  version      = 1;       // always 1 in captures.
//      repeated int32 settingIds = 2; // which setting IDs exist in
//                                     // this profile. Observed ID set:
//                                     // {1,2,3,5,6,7,13,14,15,16,17,
//                                     //  18,19,20,21,25}.
//    }
//    RangeSpecs {
//      // Sparse: only the settings with nontrivial numeric ranges have
//      // an entry. Keyed positionally by sub-field number.
//      Range r1 = 1; Range r2 = 2; Range r3 = 3; // etc.
//    }
//    Range {
//      int32 settingId = 1;
//      int32 min       = 2;          // raw units (pressure × 100, etc).
//      int32 max       = 3;
//      int32 default_  = 4;          // observed 2000 == 20.00 cmH₂O.
//    }
//    Values {
//      // One entry per setting in `ids`, keyed POSITIONALLY by the
//      // sub-field number. Values.fN corresponds to ids[N-1]. The inner
//      // f1 inside each Value is NOT a settingId — it's just the first
//      // numeric component of the value tuple (which is why the same
//      // inner-f1=2 shows up against ids 5, 6, 15, 16, 18, 19 — those
//      // are unrelated settings that happen to share a value of 2).
//      // In the two factory records, ids has 16 entries but only 15
//      // slots are populated; the 16th id (25 in captures) has no
//      // value — likely meaning "default".
//      Value v1 = 1; Value v2 = 2; ... Value v15 = 15;
//      CalendarBlock calendar = 14;   // composite weekly-schedule
//                                     // sub-message (overrides v14's
//                                     // simple int tuple).
//    }
//    Value {
//      int32 a = 1; int32 b = 2; int32 c = 3; int32 d = 4; int32 e = 5;
//      // All ints are setting-specific scaled values — scale depends on
//      // the settingId, not on the slot's sub-field number.
//    }
//    CalendarBlock (Values.f14) {
//      WeekDay monday    = 1;        // Four sub-blocks, each an
//      WeekDay tuesday   = 2;        // identical {f1=1, f2=946684800000,
//      WeekDay wednesday = 3;        // f3=2} in captures. f2 is the
//      WeekDay thursday  = 4;        // 2000-01-01 epoch-default — means
//                                    // "no scheduled change set". There
//                                    // are only four sub-entries, not
//                                    // seven: likely the device groups
//                                    // the week into four shift slots
//                                    // (wake/sleep/travel/clinic?) or
//                                    // the remaining days live under a
//                                    // field we haven't seen yet. Needs
//                                    // a device with an actual schedule
//                                    // set to disambiguate.
//    }
//
//  Setting-ID mapping (ground-truthed against SD card's
//  SETTINGS/CurrentSettings.json, 2026-04-15). The Values slots f1..f15
//  are positionally aligned with ActiveProfiles.FeatureProfiles[0..14]:
//
//    slot / settingId / Feature                 / factory value tuple
//    -------------------------------------------------------------------
//    f1   / 1  / ComfortFeature                  / (1,)           MED
//    f2   / 2  / EprFeature                      / (2,2,1,100)    MED
//                 — {EprEnablePatientAccess, EprEnable, EprType, EprPressure}
//    f3   / 3  / AutoRampFeature                 / (3, 2000)      LOW
//    f4   / 5  / SmartStartStopFeature           / (2, 1)         MED
//    f5   / 6  / CircuitFeature                  / (2, 3, 1)      MED
//                 — {MaskType, TubeType, AntiBacterialFilter}
//    f6   / 7  / ClimateFeature                  / (1,2,4,3,2700) HIGH
//                 — 5-tuple; 2700 = 27.00 °C heated-tube temp ×100
//    f7   / 13 / LanguageFeature                 / (1, 163, 1)    CONFIRMED
//                 — 163 matches JSON LanguageConfiguration exactly
//    f8   / 14 / UserSolutionFeature             / (3,)           LOW
//    f9   / 15 / TemperatureFeature              / (2,)           LOW
//    f10  / 16 / PatientViewFeature              / (2,)           LOW
//    f11  / 17 / TimeZoneFeature                 / 0 → 599        LOW
//    f12  / 18 / CareCheckFeature                / (2,)           LOW
//    f13  / 19 / DeviceHealthFeature             / (2, 1)         MED
//                 — {SoundcheckFeatureToggle, SoundcheckRunFrequency}
//    f14  / 20 / ReminderFeature (CalendarBlock) /                CONFIRMED
//                 — 4 sub-records {Mask, Tubing, Filter, Humidifier},
//                   each (Enable=1, StartDateTime=2000-01-01, Period=2="P1M")
//    f15  / 21 / DisplayFeature                  / (1, 2)         LOW
//                 — JSON has 7 fields; factory omits most
//    (—)  / 25 / MaskSenseFeature                / (not present)
//                 — 16th ID in SettingList has no value slot; treat as default
//
//  To crack the LOW-confidence IDs: pull a full SettingProfilesCollection
//  spool (no 500-byte truncation). The latest record will match
//  CurrentSettings.json and will diff from factory exactly on user-modified
//  features (e.g. AutoRampFeature.RampTime=45 unlocks f3's semantics).
//  See archive/reverse_engineering/spool_groundtruth.md.
//

import Foundation

/// A single historical snapshot of the device's therapy-setting profile.
struct SettingProfile {
    /// UTC moment this profile became active (clock-offset corrected).
    let changedAt: Date
    /// Raw ms timestamp as recorded by the CPAP — stable dedup key.
    let rawChangedAtMs: UInt64
    /// UTF-8 profile name, e.g. "MFGShipState". Empty for the
    /// pre-commission zero record.
    let name: String
    /// The `flag` integer from the header (field 4). Observed 0.
    let headerFlag: Int
    /// The list of setting IDs this profile references.
    let settingIds: [Int]
    /// Setting-ID → numeric range, when the device reported one.
    let ranges: [Int: Range]
    /// Setting-ID → current value tuple. Keyed by the settingId obtained
    /// by positional lookup into `settingIds` (Values.fN ↔ settingIds[N-1]).
    /// See file header for why we can't key by the Value's inner f1.
    let values: [Int: Value]

    struct Range {
        let min: Int
        let max: Int
        let defaultValue: Int
    }

    /// A setting's actual current value as a small ordered tuple. Up to
    /// five numeric components; trailing ones are `nil` when the device
    /// didn't send them. Scale and semantics depend on the settingId —
    /// see the per-ID table in the format writeup markdown.
    struct Value {
        let a: Int?
        let b: Int?
        let c: Int?
        let d: Int?
        let e: Int?
    }
}

enum SettingProfilesCollectionSpoolDecoderError: Error {
    case truncated
    case invalidWireType(Int)
    case parseError(String)
}

enum SettingProfilesCollectionSpoolDecoder {

    /// Parse a full `SettingProfilesCollection` spool into profile
    /// snapshots, in on-wire order (which is typically chronological).
    ///
    /// - Parameter clockOffsetSeconds: see `SummarySpoolDecoder.decode`.
    static func decode(_ data: Data,
                       clockOffsetSeconds: TimeInterval = 0) throws -> [SettingProfile] {
        var out: [SettingProfile] = []
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
            guard end <= data.count else {
                // Truncated mid-record: stop here cleanly.
                break
            }
            let blobEnd = end
            i = blobEnd
            guard fn == 3 else { continue }
            let blob = data.subdata(in: (data.startIndex + n2)..<(data.startIndex + blobEnd))
            if let profile = parseProfile(blob, clockOffsetSeconds: clockOffsetSeconds) {
                out.append(profile)
            }
        }
        return out
    }

    private static func parseProfile(_ data: Data,
                                     clockOffsetSeconds: TimeInterval) -> SettingProfile? {
        var header: (ts: UInt64, name: Data, flag: Int)?
        var ids: [Int] = []
        var ranges: [Int: SettingProfile.Range] = [:]
        var values: [Int: SettingProfile.Value] = [:]

        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { return nil }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if wt != 2 {
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { return nil }
                i = skipped
                continue
            }
            guard let (length, n2) = try? readVarint(data, at: i) else { return nil }
            let end = n2 + Int(length)
            guard end <= data.count else { return nil }
            let blob = data.subdata(in: (data.startIndex + n2)..<(data.startIndex + end))
            i = end
            switch fn {
            case 1:
                header = parseHeader(blob)
            case 2:
                ids = parseSettingList(blob)
            case 3:
                ranges = parseRangeSpecs(blob)
            case 4:
                // Needs the ids list so it can resolve positional slots.
                // The f2 (SettingList) field always precedes f4 on the
                // wire in captures, so by the time we hit f4 `ids` is
                // populated. If the device ever reorders, we'd fall
                // back to an empty-keyed map — not great but not crash.
                values = parseValues(blob, settingIds: ids)
            default:
                continue
            }
        }
        guard let h = header else { return nil }
        let raw = Date(timeIntervalSince1970: TimeInterval(h.ts) / 1000.0)
        return SettingProfile(
            changedAt: raw.addingTimeInterval(-clockOffsetSeconds),
            rawChangedAtMs: h.ts,
            name: String(data: h.name, encoding: .utf8) ?? "",
            headerFlag: h.flag,
            settingIds: ids,
            ranges: ranges,
            values: values
        )
    }

    private static func parseHeader(_ data: Data) -> (ts: UInt64, name: Data, flag: Int)? {
        var ts: UInt64 = 0
        var name = Data()
        var flag = 0
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { return nil }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            switch (fn, wt) {
            case (1, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                ts = v; i = n
            case (3, 2):
                guard let (length, n) = try? readVarint(data, at: i) else { return nil }
                let end = n + Int(length)
                guard end <= data.count else { return nil }
                name = data.subdata(in: (data.startIndex + n)..<(data.startIndex + end))
                i = end
            case (4, 0):
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                flag = Int(v); i = n
            default:
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { return nil }
                i = skipped
            }
        }
        return (ts, name, flag)
    }

    private static func parseSettingList(_ data: Data) -> [Int] {
        var ids: [Int] = []
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { break }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if fn == 2 && wt == 0 {
                guard let (v, n) = try? readVarint(data, at: i) else { break }
                ids.append(Int(v)); i = n
            } else {
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { break }
                i = skipped
            }
        }
        return ids
    }

    /// The RangeSpecs wrapper holds one sub-message per field slot; each
    /// sub-message carries its own settingId in its f1. We key the
    /// resulting dictionary by settingId so downstream callers don't
    /// have to know the slot layout.
    private static func parseRangeSpecs(_ data: Data) -> [Int: SettingProfile.Range] {
        var out: [Int: SettingProfile.Range] = [:]
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { break }
            i = next
            let wt = Int(tag & 0x7)
            if wt != 2 {
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { break }
                i = skipped
                continue
            }
            guard let (length, n2) = try? readVarint(data, at: i) else { break }
            let end = n2 + Int(length)
            guard end <= data.count else { break }
            let sub = data.subdata(in: (data.startIndex + n2)..<(data.startIndex + end))
            i = end
            if let r = parseRange(sub) {
                out[r.settingId] = r.range
            }
        }
        return out
    }

    private static func parseRange(_ data: Data) -> (settingId: Int, range: SettingProfile.Range)? {
        var settingId: Int?
        var minV: Int = 0, maxV: Int = 0, defV: Int = 0
        var sawMin = false, sawMax = false, sawDef = false
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { return nil }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if wt == 0 {
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                i = n
                switch fn {
                case 1: settingId = Int(v)
                case 2: minV = Int(v); sawMin = true
                case 3: maxV = Int(v); sawMax = true
                case 4: defV = Int(v); sawDef = true
                default: break
                }
            } else {
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { return nil }
                i = skipped
            }
        }
        guard let id = settingId else { return nil }
        return (id, SettingProfile.Range(
            min: sawMin ? minV : 0,
            max: sawMax ? maxV : 0,
            defaultValue: sawDef ? defV : 0
        ))
    }

    /// Slot-by-slot walk of the Values message. The N-th length-delimited
    /// sub-entry is the value of setting `settingIds[N-1]`.
    private static func parseValues(_ data: Data,
                                    settingIds: [Int]) -> [Int: SettingProfile.Value] {
        var out: [Int: SettingProfile.Value] = [:]
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { break }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if wt != 2 {
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { break }
                i = skipped
                continue
            }
            guard let (length, n2) = try? readVarint(data, at: i) else { break }
            let end = n2 + Int(length)
            guard end <= data.count else { break }
            let sub = data.subdata(in: (data.startIndex + n2)..<(data.startIndex + end))
            i = end

            let slot = fn
            // Positional resolve. The SettingList includes a leading
            // "version" entry (its own f1=1 before the repeated f2 ids),
            // but that's not an id — only the ids[] list was returned.
            // Slot index into ids is zero-based and excludes the version.
            let idx = slot - 1
            guard idx >= 0 && idx < settingIds.count else { continue }
            let settingId = settingIds[idx]
            if let v = parseValueTuple(sub) {
                out[settingId] = v
            }
        }
        return out
    }

    /// Parse one Value sub-message as a flat {a,b,c,d,e} int tuple.
    /// Non-int sub-fields (e.g. the nested week-calendar of the v14
    /// slot) are ignored — a proper calendar struct will arrive once we
    /// have a device with a real weekly schedule set.
    private static func parseValueTuple(_ data: Data) -> SettingProfile.Value? {
        var a: Int?, b: Int?, c: Int?, d: Int?, e: Int?
        var i = 0
        while i < data.count {
            guard let (tag, next) = try? readVarint(data, at: i) else { return nil }
            i = next
            let fn = Int(tag >> 3)
            let wt = Int(tag & 0x7)
            if wt == 0 {
                guard let (v, n) = try? readVarint(data, at: i) else { return nil }
                i = n
                switch fn {
                case 1: a = Int(v)
                case 2: b = Int(v)
                case 3: c = Int(v)
                case 4: d = Int(v)
                case 5: e = Int(v)
                default: break
                }
            } else {
                guard let skipped = try? skipField(data, at: i, wireType: wt) else { return nil }
                i = skipped
            }
        }
        return SettingProfile.Value(a: a, b: b, c: c, d: d, e: e)
    }

    // MARK: - Shared plumbing

    private static func skipField(_ data: Data, at offset: Int, wireType: Int) throws -> Int {
        switch wireType {
        case 0:
            let (_, n) = try readVarint(data, at: offset); return n
        case 1:
            guard offset + 8 <= data.count else { throw SettingProfilesCollectionSpoolDecoderError.truncated }
            return offset + 8
        case 2:
            let (length, n) = try readVarint(data, at: offset)
            let end = n + Int(length)
            guard end <= data.count else { throw SettingProfilesCollectionSpoolDecoderError.truncated }
            return end
        case 5:
            guard offset + 4 <= data.count else { throw SettingProfilesCollectionSpoolDecoderError.truncated }
            return offset + 4
        default:
            throw SettingProfilesCollectionSpoolDecoderError.invalidWireType(wireType)
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
            if shift >= 64 { throw SettingProfilesCollectionSpoolDecoderError.parseError("varint overflow") }
        }
        throw SettingProfilesCollectionSpoolDecoderError.truncated
    }
}
