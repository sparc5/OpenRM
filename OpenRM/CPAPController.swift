//
//  CPAPController.swift
//  OpenRM
//
//  High-level CPAP controller. Combines BLE, FIG framing, SRP key exchange,
//  and AES encryption into a single API.
//
//  Usage:
//    let controller = CPAPController()
//    try await controller.scanAndConnect()
//    if controller.needsPairing {
//        try await controller.pair(pin: "1234")
//    } else {
//        try await controller.resumeSession()
//    }
//    try await controller.startTherapy()
//    try await controller.stopTherapy()
//

import Foundation
import Combine
import CryptoKit
import BigInt
import os

private let log = Logger(subsystem: "com.openrm.cpap", category: "CPAPController")

@MainActor
final class CPAPController: ObservableObject {
    /// Process-wide singleton. Required because the CBCentralManager
    /// inside `ble` is configured with a state-restoration identifier
    /// — iOS expects exactly one central manager per identifier per
    /// process, and the BackgroundSync path needs to reuse the same
    /// instance the UI binds to (otherwise background wake-ups and
    /// the UI both try to connect to the peripheral and conflict).
    static let shared = CPAPController()

    @Published var ble = BLEManager()
    @Published var isPaired: Bool = false
    @Published var sessionEstablished: Bool = false
    @Published var isRunning: Bool = false
    @Published var lastError: String?
    @Published var isSimulating: Bool = false
    private var simTask: Task<Void, Never>?

    // Live state polled from the device. These get updated every
    // `pollIntervalNanos` while a session is active.
    @Published var fgState: String = "—"             // "Standby" / "Therapy" / etc.
    @Published var maskPressure: Double = 0.0        // cm H₂O, from MaskPressure-100hz
    @Published var inspiratoryPressure: Double = 0.0 // cm H₂O, from InspiratoryPressure-50hz
    @Published var setPressure: Double = 0.0         // cm H₂O, from SetPressureWithoutCAD
    @Published var leakRate: Double = 0.0            // L/min (presumed), from Leak50Hz
    @Published var remainingRampTime: Int = 0        // seconds (presumed)
    @Published var systemError: String = "—"

    // Machine meters from MachineMetrics (seconds, ISO 8601 PT…S format).
    // Updated every Nth poll tick to avoid pulling the bigger response
    // every 1.5 s.
    @Published var therapyRunSeconds: Int = 0
    @Published var lastTherapyUse: String = "—"
    /// `LastTherapyUseDateTime` parsed and corrected for CPAP clock drift.
    /// While the device reports `FGState == "Therapy"`, this is the
    /// CURRENT session's start (the AirSense rewrites it on each new
    /// session). When standby, it's the most recent finished session.
    @Published var lastTherapyUseDate: Date?

    /// Duration of the most recent "real" sleep session, decoded from
    /// the Summary spool. Nil until `fetchLastSessionSummary` has run.
    /// "Real" = at least `lastSessionMinThresholdMinutes` minutes, which
    /// excludes brief pressure-test sessions.
    @Published var lastSessionMinutes: Int?
    /// Calendar day the most recent real session belongs to.
    @Published var lastSessionDate: Date?

    /// Timestamp of the last successful `fetchLastSessionSummary`
    /// completion. Persisted across launches so the dashboard can
    /// still show "Last synced: ..." after a cold restart — the
    /// actual work doesn't need to re-run for the timestamp to be
    /// meaningful to the user. Written inside fetchLastSessionSummary
    /// on success.
    @Published var lastSyncedAt: Date? = {
        UserDefaults.standard.object(forKey: "com.openrm.cpap.lastSyncedAt") as? Date
    }()

    /// Lifetime total time actually asleep (in seconds), as classified
    /// by the v2 stage detector and written to HealthKit. This is the
    /// complement to `therapyRunSeconds` (lifetime mask-on time):
    /// mask-on-and-awake minutes are subtracted out. Refreshed after
    /// each successful sync; cached in UserDefaults so the dashboard
    /// has a number to show immediately on cold launch.
    @Published var lifetimeTimeAsleepSeconds: Int = {
        UserDefaults.standard.integer(forKey: "com.openrm.cpap.lifetimeTimeAsleepSeconds")
    }()

    /// Drift between the CPAP's internal UTC clock and real UTC, in
    /// seconds (positive = CPAP believes time is later than it is).
    /// Set by `calibrateClockOffset()`. Applied to BLE-spool session
    /// timestamps so dates display correctly in the user's local
    /// timezone regardless of where the CPAP was set up or whether
    /// it observes DST.
    ///
    /// Observed on 2026-04-11: 1h drift during EDT (CPAP didn't
    /// observe DST so it's consistently 1h ahead of real UTC).
    @Published var cpapClockOffsetSeconds: TimeInterval = 0

    // Climate feature state.
    // Settings (static, fetched via Get ClimateFeature on session establish):
    @Published var climateControl: String = "—"
    @Published var humidifierLevel: Double = 0         // level 0-8 (user setting)
    @Published var heatedTubeTempSetting: Double = 0   // °C, user's target
    // Live measurements (polled every tick, same path as pressure/leak):
    @Published var heatedTubeTempActual: Double = 0    // °C, instantaneous
    @Published var humidifierPower: Double = 0         // % 0-100
    @Published var heatedTubePower: Double = 0         // % 0-100
    @Published var ambientHumidity: Double = 0         // mg/L

    /// Serial number of the currently paired CPAP, read via Get on connect.
    /// Used to namespace per-machine state (cleaning/filter reminders) so
    /// swapping CPAPs doesn't cross-contaminate timers.
    @Published var machineSerialNumber: String?

    // Raw diagnostic channel readouts from the two spools whose semantics
    // we haven't nailed down yet. Exposed on the dashboard so we can
    // ground-truth their meaning by toggling humidifier / heater on the
    // CPAP and watching which number changes.
    // - `diagnosticChanA` / `diagnosticChanB`: last sample from the two
    //   channels of DiagnosticTenMinutePeriodic (10-min cadence).
    // - `perMinF7`: last sample from TherapyOneMinutePeriodic field 7
    //   (1-min cadence, physical quantity TBD — "not RespRate, not Snore").
    // - `diagReceivedAt`: wall-clock time of the most recent pull, so the
    //   UI can show "stale" hints without guessing.
    @Published var diagnosticChanA: Int?
    @Published var diagnosticChanB: Int?
    @Published var perMinF7: Int?
    @Published var diagReceivedAt: Date?

    private var rxBuffer = Data()
    private var pendingResponses: [UInt16: CheckedContinuation<String, Error>] = [:]
    private var nextRequestId: Int = 1
    private var sessionKey: Data?
    private var srp: SRPClient?
    private var pendingSession: SRPSession?
    private var pollingTask: Task<Void, Never>?
    private var lastInvalidCount: Int = -1
    private var pollTickCount: Int = 0
    /// Guards the diagnostic-spool fetch so a slow pull doesn't stack up
    /// with the next tick. One at a time.
    private var diagnosticFetchInFlight: Bool = false

    /// How often to run the fallback poll. Push notifications are fast
    /// (100Hz for mask pressure) but sometimes go quiet around state
    /// transitions, so we still poll every 2s as a safety net to keep
    /// the LED readouts fresh.
    private static let pollIntervalNanos: UInt64 = 2_000_000_000

    init() {
        isPaired = CredentialStore.load() != nil
        ble.onData = { [weak self] data in
            Task { @MainActor in self?.handleIncoming(data) }
        }
    }

    // MARK: - Connection

    func scanAndConnect() async throws {
        // Fast path: if we have credentials with a saved peripheral UUID,
        // try to reconnect directly and skip the 5s scan entirely.
        if let creds = CredentialStore.load(),
           let idStr = creds.peripheralId,
           let uuid = UUID(uuidString: idStr) {
            do {
                if try await ble.connectByIdentifier(uuid) {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    rxBuffer.removeAll()
                    return
                }
            } catch {
                log.error("fast reconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        ble.startScan()
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let device = ble.discoveredDevices.first(where: {
            $0.name.contains("ResMed") || $0.name.contains("AirSense")
        }) ?? ble.discoveredDevices.first
        guard let device = device else {
            log.error("no devices found")
            throw CPAPError.deviceNotFound
        }
        try await ble.connect(device)
        // Give the CPAP a moment to send initial heartbeat
        try await Task.sleep(nanoseconds: 1_500_000_000)
        rxBuffer.removeAll()  // drop initial heartbeat
    }

    /// Connect to a specific device the user picked from the scan list.
    /// Called from the device picker sheet during the pairing flow.
    func connectToDiscovered(_ device: BLEManager.DiscoveredDevice) async throws {
        ble.stopScan()
        try await ble.connect(device)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        rxBuffer.removeAll()
    }

    func disconnect() {
        stopLivePolling()
        ble.disconnect()
        sessionKey = nil
        sessionEstablished = false
    }

    // MARK: - Pairing (SRP-6a key exchange)

    func pair(pin: String) async throws {
        let client = SRPClient()
        self.srp = client

        // Step 1: Send StartKeyExchange with clientPk (A)
        let clientPkHex = SRPClient.pad(client.A.serialize(), to: SRPClient.keyLength).hexString.uppercased()
        let req1: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "StartKeyExchange",
            "params": ["clientPk": clientPkHex],
            "id": nextId()
        ]
        let resp1Str = try await sendRPC(req1)
        let resp1 = try parseJSON(resp1Str)
        guard let result1 = resp1["result"] as? [String: Any],
              let serverPkHex = result1["serverPk"] as? String,
              let saltHex = result1["salt"] as? String else {
            throw CPAPError.protocolError("missing serverPk/salt")
        }
        let B = BigUInt(serverPkHex, radix: 16)!
        let salt = Data(hex: saltHex)!

        // Step 2: Compute SRP state
        guard let session = client.computeSession(B: B, salt: salt, pin: pin) else {
            throw CPAPError.protocolError("SRP computation failed")
        }

        // Step 3: Send ConfirmKeyExchange with clientConfirmation=M1.
        let req2: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "ConfirmKeyExchange",
            "params": ["clientConfirmation": session.M1.hexString.uppercased()],
            "id": nextId()
        ]
        let resp2Str = try await sendRPC(req2)
        let resp2 = try parseJSON(resp2Str)
        guard let result2 = resp2["result"] as? [String: Any],
              let clientId = result2["clientId"] as? String,
              let serverProofHex = result2["serverConfirmation"] as? String,
              let nonceHex = result2["nonce"] as? String else {
            throw CPAPError.protocolError("confirm result missing clientId/serverConfirmation/nonce")
        }
        let serverM2 = Data(hex: serverProofHex)!
        guard serverM2 == session.expectedM2 else {
            throw CPAPError.protocolError("Server proof verification failed (wrong PIN?)")
        }

        // Derive session key: sessionKey = H(masterPairKey || nonce)
        let nonce = Data(hex: nonceHex)!
        let sessKey = SRPClient.deriveSessionKey(masterPairKey: session.masterPairKey, nonce: nonce)

        // Save credentials (including peripheral UUID for fast reconnect) so
        // future launches skip both scan and SRP.
        let peripheralIdStr = ble.currentPeripheralIdentifier?.uuidString
        try CredentialStore.save(CPAPCredentials(
            clientId: clientId,
            masterPairKey: session.masterPairKey.hexString.uppercased(),
            peripheralId: peripheralIdStr
        ))
        isPaired = true
        self.sessionKey = sessKey
        sessionEstablished = true
    }

    // MARK: - Resume session (uses saved credentials)

    func resumeSession() async throws {
        guard let creds = CredentialStore.load() else {
            throw CPAPError.notPaired
        }
        guard let masterPairKey = Data(hex: creds.masterPairKey) else {
            throw CPAPError.protocolError("invalid stored masterPairKey")
        }

        // Step 1: RequestSession(clientId)
        let req1: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "RequestSession",
            "params": ["clientId": creds.clientId],
            "id": nextId()
        ]
        let resp1Str = try await sendRPC(req1)
        let resp1 = try parseJSON(resp1Str)
        guard let result1 = resp1["result"] as? [String: Any],
              let challengeHex = result1["challenge"] as? String,
              let nonceHex = result1["nonce"] as? String,
              let challenge = Data(hex: challengeHex),
              let nonce = Data(hex: nonceHex) else {
            throw CPAPError.protocolError("missing challenge/nonce")
        }

        // Step 2: CheckSessionIntegrity(response)
        //   response = HMAC-SHA256(key=challenge, data=masterPairKey)
        let response = SRPClient.challengeResponse(challenge: challenge, masterPairKey: masterPairKey)
        let req2: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "CheckSessionIntegrity",
            "params": ["response": response.hexString.uppercased()],
            "id": nextId()
        ]
        let resp2Str = try await sendRPC(req2)
        let resp2 = try parseJSON(resp2Str)
        guard let result2 = resp2["result"] as? [String: Any],
              let ok = result2["confirmation"] as? Bool, ok else {
            throw CPAPError.protocolError("session confirmation failed")
        }

        // Step 3: Derive session key locally
        //   sessionKey = SHA256(masterPairKey || nonce)
        self.sessionKey = SRPClient.deriveSessionKey(masterPairKey: masterPairKey, nonce: nonce)
        sessionEstablished = true
    }

    // MARK: - Therapy Control

    func startTherapy() async throws {
        guard sessionKey != nil else { throw CPAPError.noSession }
        let req: [String: Any] = ["jsonrpc": "2.0", "method": "EnterTherapy", "id": nextId()]
        _ = try await sendEncryptedRPC(req)
        isRunning = true       // optimistic — next poll tick will reconcile
        fgState = "Therapy"
    }

    func stopTherapy() async throws {
        guard sessionKey != nil else { throw CPAPError.noSession }
        let req: [String: Any] = ["jsonrpc": "2.0", "method": "EnterStandby", "id": nextId()]
        _ = try await sendEncryptedRPC(req)
        isRunning = false      // optimistic
        fgState = "Standby"
    }

    // MARK: - Live state via SubscribeEvent (push)

    /// SubscribeEvent targets. Each one gets an individual subscription
    /// so the device pushes updates as they change instead of us polling.
    /// We still keep polling as a fallback for fields that don't support
    /// subscription or that return immediate errors.
    private static let subscribeTargets = [
        "FGState",
        "MaskPressure-100hz",
        "InspiratoryPressure-50hz",
        "SetPressureWithoutCAD",
        "RemainingRampTime",
        "SystemError",
        "Leak-50hz",
    ]

    /// Map subscriptionId → dataId, populated as SubscribeEvent responses
    /// come back. Used to route EventNotifications.
    private var subscriptionIdToDataId: [Int: String] = [:]

    /// Subscribe to every field in `subscribeTargets`. Does nothing if
    /// we already have a non-empty subscription map. Each subscribe is
    /// `SubscribeEvent {"dataIds":[<one>]}` — one subscription per field
    /// so we can route notifications by subscriptionId cleanly.
    func startLiveSubscriptions() async {
        guard sessionEstablished else { return }
        guard subscriptionIdToDataId.isEmpty else { return }
        for dataId in Self.subscribeTargets {
            do {
                let respStr = try await execRaw(
                    method: "SubscribeEvent",
                    paramsJSON: ["dataIds": [dataId]]
                )
                guard let data = respStr.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                guard let result = dict["result"] as? [String: Any] else {
                    continue
                }
                let sid: Int? = (result["subscriptionId"] as? Int)
                    ?? (result["subscriptionId"] as? NSNumber)?.intValue
                if let sid = sid {
                    subscriptionIdToDataId[sid] = dataId
                }
            } catch {
                log.error("subscribe: \(dataId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Called from handleIncoming when a JSON-RPC notification with
    /// method="SpoolFragment" arrives. Decodes the base64 payload and
    /// hands the raw protobuf bytes to `onSpoolFragment`.
    ///
    /// Confirmed wire shape (from myAir Frida capture):
    ///   {"method":"SpoolFragment",
    ///    "params":{"spoolId": N, "data": "<base64 protobuf>"}}
    private func handleSpoolFragment(_ dict: [String: Any]) {
        guard let params = dict["params"] as? [String: Any] else { return }
        let spoolId = (params["spoolId"] as? Int)
            ?? (params["spoolId"] as? NSNumber)?.intValue ?? -1
        guard let b64 = params["data"] as? String,
              let data = Data(base64Encoded: b64) else {
            log.error("rx: SpoolFragment missing/invalid data field")
            return
        }
        onSpoolFragment?(spoolId, data)
    }

    /// Called from handleIncoming when a JSON-RPC notification with
    /// method="EventNotification" arrives.
    ///
    /// Confirmed payload shape on AirSense 11:
    ///   {"params":{
    ///     "subscriptionId": N,
    ///     "dataId": "FieldName",
    ///     "events": [
    ///       {"reportTime": "...", "event": "ValueChange", "value": V}
    ///     ]
    ///   }}
    ///
    /// dataId is at `params` level, NOT per-event. The inner events only
    /// carry reportTime/event/value.
    private func handleEventNotification(_ dict: [String: Any]) {
        guard let params = dict["params"] as? [String: Any] else { return }

        // Resolve which field this notification is for
        var dataId: String? = params["dataId"] as? String
        if dataId == nil, let sid = (params["subscriptionId"] as? Int)
                                      ?? (params["subscriptionId"] as? NSNumber)?.intValue {
            dataId = subscriptionIdToDataId[sid]
        }
        guard let name = dataId else { return }

        // Process events; apply the last one (most recent value wins)
        if let events = params["events"] as? [[String: Any]], let last = events.last {
            let rawValue = last["value"]
            applyFieldUpdate(name: name, value: rawValue, isFromPush: true)
        } else {
            // Fallback: value maybe directly in params
            applyFieldUpdate(name: name, value: params["value"], isFromPush: true)
        }
    }

    /// Apply a single field update from either a poll tick or an event
    /// notification. Centralised so both paths stay in sync.
    ///
    /// `isFromPush` controls value scaling: the SubscribeEvent push channel
    /// delivers pressure fields as fixed-point integers at 0.02 cmH₂O
    /// resolution (multiply by 50), while `Get` returns pre-scaled floats.
    /// Confirmed via paired readings: event value 252 = Get value 5.04.
    private func applyFieldUpdate(name: String, value: Any?, isFromPush: Bool) {
        // Pressure fields need ÷50 scaling from push, no scaling from Get.
        let pressureScale = isFromPush ? 50.0 : 1.0

        switch name {
        case "FGState":
            if let s = value as? String {
                let wasRunning = isRunning
                fgState = s
                isRunning = (s == "Therapy")
                // Therapy just ended — a new completed session is
                // available on the device. Kick off a sync so the
                // Summary spool + HealthKit write happen immediately
                // instead of waiting for the next BGAppRefreshTask
                // tick. Re-entrant safe: fetchLastSessionSummary
                // dedupes at the HealthKit write layer via the
                // openrm-sess-* metadata keys.
                if wasRunning && !isRunning {
                    Task { [weak self] in
                        await self?.fetchLastSessionSummary()
                    }
                }
            }
        case "MaskPressure-100hz":
            if let v = asDouble(value) { maskPressure = v / pressureScale }
        case "InspiratoryPressure-50hz":
            if let v = asDouble(value) { inspiratoryPressure = v / pressureScale }
        case "SetPressureWithoutCAD":
            if let v = asDouble(value) { setPressure = v / pressureScale }
        case "Leak-50hz":
            // Leak does NOT share the ÷50 pressure scaling. Confirmed from
            // the log: push events during a breathing cycle went 1..12..0,
            // and Get returns values like 1.00 L/min at similar moments,
            // so push and Get are both already in L/min. Apply as-is.
            if let v = asDouble(value) {
                leakRate = v
            } else {
                leakRate = 0.0
            }
        case "RemainingRampTime":
            if let v = value as? Int { remainingRampTime = v }
            else if let v = value as? NSNumber { remainingRampTime = v.intValue }
        case "SystemError":
            if let s = value as? String { systemError = s }
        case "AmbHumidity":
            if let v = asDouble(value) { ambientHumidity = v }
        case "HTubeTemp":
            if let v = asDouble(value) { heatedTubeTempActual = v }
        case "HumPow":
            if let v = asDouble(value) { humidifierPower = v }
        case "HTubePow":
            if let v = asDouble(value) { heatedTubePower = v }
        default:
            break
        }
    }

    // MARK: - Live state polling

    /// Start polling live state (FGState, pressures, etc.) every 1.5s,
    /// and also kick off push subscriptions for fields that support it.
    /// Polling stays active as a fallback for fields that don't push.
    /// Idempotent — calling while already polling is a no-op.
    func startLivePolling() {
        guard pollingTask == nil else { return }
        Task { [weak self] in
            await self?.startLiveSubscriptions()
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.pollLiveStateOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
            }
        }
    }

    /// Stop polling. Safe to call multiple times.
    func stopLivePolling() {
        pollingTask?.cancel()
        pollingTask = nil
        // Clear subscription map — next startLivePolling will re-subscribe.
        // The device drops subscriptions when the session tears down.
        subscriptionIdToDataId.removeAll()
    }

    /// Objects pulled on every poll tick.
    ///
    /// Push notifications via SubscribeEvent are the fast path and handle
    /// most updates. But empirically the device sometimes stops pushing
    /// after state transitions (e.g. Standby → Therapy) and we'd be
    /// stuck showing stale values. Polling the full set every 2s keeps
    /// the LED readouts fresh as a safety net.
    ///
    /// MachineMetrics is appended every 10th tick (~20s).
    private static let livePollObjects = [
        "FGState",
        "MaskPressure-100hz",
        "InspiratoryPressure-50hz",
        "SetPressureWithoutCAD",
        "RemainingRampTime",
        "SystemError",
        "Leak-50hz",
        // Climate live dataIds confirmed InvalidObject on this firmware
        // (AirSense 11 SW04600.16). No equivalent exists via Get either;
        // the only on-device source for humidity/temp/power readings is
        // the Summary spool per-session medians, seeded on sync.
    ]

    /// Tracks whether we've logged the first poll response's keys yet,
    /// so we can see in the log which of the live-poll objects the device
    /// actually recognizes.
    private var loggedFirstPollKeys = false

    private func pollLiveStateOnce() async {
        guard sessionEstablished else { return }
        pollTickCount += 1

        // Periodic background fetch of the two experimental diagnostic
        // spools. Both install onSpoolFragment handlers; the
        // session-establish path (fetchLastSessionSummary) does the
        // same, so first fire is deferred to tick 40 (~60s in) to let
        // that land. Subsequent fires every 60 ticks (~90s) — matches
        // the TherapyOneMinutePeriodic cadence with headroom.
        if (pollTickCount == 40 || (pollTickCount > 40 && pollTickCount % 60 == 0))
            && !diagnosticFetchInFlight {
            diagnosticFetchInFlight = true
            Task { [weak self] in
                await self?.fetchDiagnosticReadouts()
                await MainActor.run { self?.diagnosticFetchInFlight = false }
            }
        }

        // Every 10th tick (≈15s) also fetch MachineMetrics. It's bigger
        // (~460 B) and the meters change slowly so no need to pull it
        // on every tick.
        let fetchMetrics = (pollTickCount == 1) || (pollTickCount % 10 == 0)
        let objs = fetchMetrics ? Self.livePollObjects + ["MachineMetrics"] : Self.livePollObjects

        do {
            let (valid, invalid) = try await getObjects(objs)

            if !loggedFirstPollKeys {
                loggedFirstPollKeys = true
            }
            if !invalid.isEmpty, invalid.count != lastInvalidCount {
                lastInvalidCount = invalid.count
            }

            // Route Get values through the shared applier. isFromPush=false
            // means values are already in cmH₂O (no scaling needed).
            for key in ["FGState",
                        "MaskPressure-100hz", "InspiratoryPressure-50hz",
                        "SetPressureWithoutCAD", "RemainingRampTime",
                        "SystemError"] {
                applyFieldUpdate(name: key, value: valid[key], isFromPush: false)
            }
            // Leak-50hz is only reported while in Therapy. Zero the panel
            // when it comes back as InvalidObject rather than leaving a
            // stale value from the last therapy session.
            if valid["Leak-50hz"] != nil {
                applyFieldUpdate(name: "Leak-50hz", value: valid["Leak-50hz"], isFromPush: false)
            } else {
                leakRate = 0.0
            }
            if let metrics = valid["MachineMetrics"] as? [String: Any] {
                therapyRunSeconds = parseIsoDurationSeconds(metrics["TherapyRunMeter"]) ?? therapyRunSeconds
                if let s = metrics["LastTherapyUseDateTime"] as? String {
                    lastTherapyUse = s
                    // Parse the CPAP-clock timestamp and back out the
                    // calibrated drift so the resulting Date is in the
                    // app's wall-clock space. Used by the dashboard to
                    // drive a SESSION TIME LED off device-reported data
                    // instead of a local stopwatch.
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let parsed = f.date(from: s)
                        ?? ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z")
                    if let p = parsed {
                        lastTherapyUseDate = p.addingTimeInterval(-cpapClockOffsetSeconds)
                    }
                }
            }
        } catch {
            // Log but keep polling — a transient BLE failure shouldn't tear
            // down the polling loop. The next tick will retry.
            log.error("poll: tick failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Batch-get several flat objects via the `Get` method.
    /// Handles both happy-path (`result` present) and partial-success
    /// (`error -11201 InvalidObject` with `data` containing both the
    /// valid values and an `InvalidObjects` list).
    func getObjects(_ names: [String]) async throws -> (valid: [String: Any], invalid: [String]) {
        let respStr = try await execRaw(method: "Get", paramsJSON: names)
        guard let data = respStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CPAPError.protocolError("getObjects: invalid JSON response")
        }
        if let result = dict["result"] as? [String: Any] {
            return (valid: result, invalid: [])
        }
        if let err = dict["error"] as? [String: Any],
           let code = (err["code"] as? Int) ?? (err["code"] as? NSNumber)?.intValue,
           code == -11201,
           var edata = err["data"] as? [String: Any] {
            let invalid = (edata["InvalidObjects"] as? [String]) ?? []
            edata["InvalidObjects"] = nil
            return (valid: edata, invalid: invalid)
        }
        // Any other error: surface it
        if let err = dict["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "unknown"
            throw CPAPError.rpcError(msg)
        }
        throw CPAPError.protocolError("getObjects: unexpected response shape")
    }

    func fetchClimateSettings() async {
        guard sessionEstablished else { return }
        do {
            let (valid, _) = try await getObjects(["ClimateFeature"])
            if let climate = valid["ClimateFeature"] as? [String: Any] {
                await MainActor.run {
                    if let s = climate["ClimateControl"] as? String { climateControl = s }
                    if let v = asDouble(climate["HumidifierLevel"]) { humidifierLevel = v }
                    if let v = asDouble(climate["HeatedTubeTemperature"]) { heatedTubeTempSetting = v }
                }
            }
        } catch {
            log.error("climate: fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read the CPAP's SerialNumber via Get and bind per-machine state
    /// (maintenance reminders) to it. Called after session establish so
    /// cleaning/filter timers show the correct countdown for *this* CPAP,
    /// not whichever machine was paired last.
    /// Pull the most recent records from the two experimental spools whose
    /// channel semantics are unknown, extract the last sample of each, and
    /// publish them so the dashboard can display raw diagnostic readouts.
    /// Used to ground-truth the spool channels by watching which numbers
    /// change when the user toggles humidifier / heater on the CPAP.
    func fetchDiagnosticReadouts() async {
        guard sessionEstablished else { return }
        // Pull the last 24 h — outside therapy windows these spools are
        // mostly empty, so we need a wide window to catch the last
        // session's tail. 32 KB cap to accommodate a whole night in one
        // shot when the spool is dense.
        let from = Date().addingTimeInterval(-86400)

        do {
            let diagRecords = try await fetchDiagnosticTenMinute(from: from)
            log.info("diag: DiagnosticTenMinutePeriodic → \(diagRecords.count) record(s)")
            if let latest = diagRecords.last {
                let a = latest.channel(field: 2)?.values.last
                let b = latest.channel(field: 5)?.values.last
                let ts = latest.startDate
                log.info("diag: latest rec ts=\(ts, privacy: .public) chanA=\(a.map { "\($0)" } ?? "nil", privacy: .public) chanB=\(b.map { "\($0)" } ?? "nil", privacy: .public)")
                await MainActor.run {
                    diagnosticChanA = a
                    diagnosticChanB = b
                }
            }
        } catch {
            log.error("diag: DiagnosticTenMinutePeriodic fetch failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            let f7 = try await fetchLatestPerMinF7(from: from)
            log.info("diag: PerMinute f7=\(f7.map { "\($0)" } ?? "nil", privacy: .public)")
            if let f7 = f7 {
                await MainActor.run { perMinF7 = f7 }
            }
        } catch {
            log.error("diag: TherapyOneMinutePeriodic fetch failed: \(error.localizedDescription, privacy: .public)")
        }

        await MainActor.run { diagReceivedAt = Date() }
    }

    private func fetchDiagnosticTenMinute(from: Date) async throws -> [DiagnosticTenMinuteRecord] {
        let spoolId = try await startSpool(
            spoolType: .diagnosticTenMinutePeriodic,
            fromDateTime: from,
            maxSpoolSize: 32768
        )
        log.info("diag: DiagnosticTenMinutePeriodic StartSpool OK spoolId=\(spoolId) from=\(Self.isoDateTimeFormatter.string(from: from), privacy: .public)")
        let collector = SpoolCollector()
        let prev = onSpoolFragment
        onSpoolFragment = { id, data in if id == spoolId { collector.append(data) } }
        defer { onSpoolFragment = prev }
        _ = try await pullSpoolFragments(spoolId: spoolId)
        let waitStart = Date()
        while Date().timeIntervalSince(waitStart) < 15 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if !collector.fragments.isEmpty &&
               Date().timeIntervalSince(collector.lastFragmentAt) >= 2 { break }
        }
        log.info("diag: DiagnosticTenMinutePeriodic fragments=\(collector.fragments.count) totalBytes=\(collector.fragments.reduce(0) { $0 + $1.count })")
        if collector.fragments.isEmpty { return [] }
        let combined = collector.fragments.reduce(Data()) { $0 + $1 }
        return try DiagnosticTenMinuteSpoolDecoder.decode(
            combined, clockOffsetSeconds: cpapClockOffsetSeconds)
    }

    private func fetchLatestPerMinF7(from: Date) async throws -> Int? {
        let spoolId = try await startSpool(
            spoolType: .therapyOneMinutePeriodic,
            fromDateTime: from,
            maxSpoolSize: 32768
        )
        log.info("diag: TherapyOneMinutePeriodic StartSpool OK spoolId=\(spoolId) from=\(Self.isoDateTimeFormatter.string(from: from), privacy: .public)")
        let collector = SpoolCollector()
        let prev = onSpoolFragment
        onSpoolFragment = { id, data in if id == spoolId { collector.append(data) } }
        defer { onSpoolFragment = prev }
        _ = try await pullSpoolFragments(spoolId: spoolId)
        let waitStart = Date()
        while Date().timeIntervalSince(waitStart) < 15 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if !collector.fragments.isEmpty &&
               Date().timeIntervalSince(collector.lastFragmentAt) >= 2 { break }
        }
        log.info("diag: TherapyOneMinutePeriodic fragments=\(collector.fragments.count) totalBytes=\(collector.fragments.reduce(0) { $0 + $1.count })")
        if collector.fragments.isEmpty { return nil }
        let combined = collector.fragments.reduce(Data()) { $0 + $1 }
        let sessions = try PerMinuteSpoolDecoder.decode(
            combined, clockOffsetSeconds: cpapClockOffsetSeconds)
        log.info("diag: TherapyOneMinutePeriodic sessions=\(sessions.count)")
        guard let latest = sessions.max(by: { $0.startDate < $1.startDate }),
              let f7 = latest.channels.first(where: { $0.kind == .unknownF7 }),
              let val = f7.values.last else { return nil }
        return val
    }

    func fetchMachineIdentity() async {
        guard sessionEstablished else { return }
        do {
            let (valid, _) = try await getObjects(["SerialNumber"])
            let serial = valid["SerialNumber"] as? String
            await MainActor.run {
                machineSerialNumber = serial
                MaintenanceReminder.cleaning.setMachineId(serial)
                MaintenanceReminder.filter.setMachineId(serial)
            }
        } catch {
            log.error("machine: fetch serial failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Coerce a JSON value to Double. JSONSerialization may hand us Int,
    /// Double, or NSNumber depending on how the server encoded the number.
    private func asDouble(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Parse an ISO 8601 duration like "PT7727976S" into seconds.
    /// The AirSense reports meters as plain `PT<N>S` — no H/M components.
    private func parseIsoDurationSeconds(_ v: Any?) -> Int? {
        guard let s = v as? String, s.hasPrefix("PT"), s.hasSuffix("S") else { return nil }
        let num = s.dropFirst(2).dropLast(1)
        return Int(num)
    }

    // MARK: - Probe harness (removed)
    //
    // The earlier `runProbesFromFile()` autoprobe harness and the
    // `probeDeviceInfo()`/`DeviceInfoResult` Device Info sheet were used
    // for reverse-engineering the BLE protocol. With the protocol now
    // understood, they were removed along with BLEFuzzer to cut noise
    // from the log. A no-op stub preserves the call site in DashboardView
    // without needing a compile flag.
    func runProbesFromFile() async { }

    // MARK: - Generic RPC entry point

    /// Send an arbitrary encrypted RPC call to the device.
    /// Returns the raw JSON response string.
    /// Use this to exercise read-only methods (GetVersion, GetDateTime,
    /// GetHistory, GetLoggedData, etc.) without adding a dedicated wrapper.
    func exec(method: String, params: [String: Any]? = nil) async throws -> String {
        guard sessionKey != nil else { throw CPAPError.noSession }
        var req: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": nextId(),
        ]
        if let params = params {
            req["params"] = params
        }
        return try await sendEncryptedRPC(req)
    }

    /// Send an encrypted RPC with a raw JSON params value (object, array, or
    /// anything else). Thin wrapper over sendEncryptedRPC that skips the
    /// dictionary-only constraint of `exec`.
    private func execRaw(method: String, paramsJSON: Any?) async throws -> String {
        guard sessionKey != nil else { throw CPAPError.noSession }
        var req: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": nextId(),
        ]
        if let p = paramsJSON {
            req["params"] = p
        }
        return try await sendEncryptedRPC(req)
    }

    // MARK: - Bulk-transfer (Spool) API

    /// The subset of `SpoolType` cases we've confirmed exist on this
    /// firmware by finding them as bare strings in the myAir binary.
    /// Each case's associated value is encoded as a `{"fromDateTime": ...}`
    /// object on the wire — proven uniform across all SpoolType cases by
    /// static RE of the myAir Swift metadata (`SpoolAddress` is a plain
    /// 2-field struct with a custom `encode(to:)` that emits the rawValue
    /// as the outer key). So `.therapyEvents`'s `-32602 Invalid Params`
    /// is a firmware/auth rejection, not a wire-format mismatch.
    /// See `archive/reverse_engineering/therapyevents_shape.md`.
    enum SpoolType: String {
        case summary = "Summary"
        case therapyEvents = "TherapyEvents"
        case therapyOneMinutePeriodic = "TherapyOneMinutePeriodic"
        case diagnosticTenMinutePeriodic = "DiagnosticTenMinutePeriodic"
    }

    /// ISO-8601 with millisecond precision and literal `Z` — matches the
    /// format myAir emits (`2026-04-09T17:53:35.193Z`). Swift's built-in
    /// `.withInternetDateTime` option drops the fractional seconds, so we
    /// format manually.
    static let isoDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    /// Start a bulk data spool. Returns the `spoolId` the device assigned,
    /// which must be passed to `pullSpoolFragments` to start the transfer.
    ///
    /// Confirmed wire shape (captured from myAir via Frida hook):
    ///   {"method":"StartSpool","params":{
    ///     "maxSpoolSize": 4096,
    ///     "spoolAddress": {"Summary": {"fromDateTime": "2026-04-09T17:53:35.193Z"}}
    ///   }}
    func startSpool(spoolType: SpoolType,
                    fromDateTime: Date,
                    maxSpoolSize: Int = 4096) async throws -> Int {
        let iso = Self.isoDateTimeFormatter.string(from: fromDateTime)
        let params: [String: Any] = [
            "maxSpoolSize": maxSpoolSize,
            "spoolAddress": [
                spoolType.rawValue: ["fromDateTime": iso],
            ] as [String: Any],
        ]
        let respStr = try await execRaw(method: "StartSpool", paramsJSON: params)
        let dict = try parseJSON(respStr)
        guard let result = dict["result"] as? [String: Any],
              let sid = (result["spoolId"] as? Int) ?? (result["spoolId"] as? NSNumber)?.intValue else {
            throw CPAPError.protocolError("StartSpool: no spoolId in response")
        }
        return sid
    }

    /// Request that the device start streaming fragments for a spool that
    /// was previously opened via `startSpool`. The response itself is a
    /// simple `{spoolId}` ack; the actual data arrives as
    /// `SpoolFragment` push notifications routed via `onSpoolFragment`.
    ///
    /// - Parameters:
    ///   - spoolId: identifier returned by `startSpool`
    ///   - maxFragmentSize: myAir uses 2808 (BLE MTU budget)
    ///   - maxNotifications: 0 = no limit (myAir's default)
    @discardableResult
    func pullSpoolFragments(spoolId: Int,
                            maxFragmentSize: Int = 2808,
                            maxNotifications: Int = 0) async throws -> String {
        let params: [String: Any] = [
            "maxFragmentSize": maxFragmentSize,
            "maxNotifications": maxNotifications,
            "spoolId": spoolId,
        ]
        return try await execRaw(method: "PullSpoolFragments", paramsJSON: params)
    }

    /// Callback invoked for each `SpoolFragment` push notification that
    /// arrives on the BLE link. `data` is base64-decoded raw protobuf
    /// bytes. `downloadSummaryHistory` installs a temporary handler here
    /// for the duration of its flow.
    var onSpoolFragment: ((_ spoolId: Int, _ data: Data) -> Void)?

    /// Mutable collector shared between the download coroutine and the
    /// `onSpoolFragment` closure. Class so the closure can mutate it
    /// without needing a Sendable wrapper — we're always on MainActor.
    final class SpoolCollector {
        var fragments: [Data] = []
        var lastFragmentAt: Date = Date()
        func append(_ data: Data) {
            fragments.append(data)
            lastFragmentAt = Date()
        }
    }

    /// End-to-end helper: download all Summary day records from `from`
    /// through the most recent data the CPAP has. Paginates internally
    /// because each spool is capped to `maxSpoolSize` bytes (≈20-23 day
    /// records per batch at ~177 bytes each), so multi-month histories
    /// need 5-20 batches to drain.
    ///
    /// Each batch starts a fresh spool at the advancing watermark and
    /// pulls fragments until the CPAP stops sending. Stops when a batch
    /// returns zero new records (already caught up) or `maxBatches` is
    /// reached (safety cap — should never actually hit this).
    func downloadSummaryHistory(from: Date,
                                silenceTimeoutSeconds: Double = 3.0,
                                maxWaitSeconds: Double = 30.0,
                                maxBatches: Int = 50) async throws -> [DaySummary] {
        guard sessionKey != nil else { throw CPAPError.noSession }
        var all: [DaySummary] = []
        var watermark = from
        var seenStarts = Set<Date>()

        for _ in 0..<maxBatches {
            let batch = try await downloadSummaryBatch(
                from: watermark,
                silenceTimeoutSeconds: silenceTimeoutSeconds,
                maxWaitSeconds: maxWaitSeconds
            )
            if batch.isEmpty { break }

            // Drop any records we already saw — protects against servers
            // that round watermarks down to day boundaries or re-emit the
            // last record of the previous batch.
            let newRecords = batch.filter { !seenStarts.contains($0.startDate) }
            if newRecords.isEmpty { break }
            for r in newRecords { seenStarts.insert(r.startDate) }
            all.append(contentsOf: newRecords)

            // Advance watermark to just past the latest endDate in this
            // batch. Records don't arrive in a guaranteed order, so use
            // max() rather than the last element.
            guard let latestEnd = batch.map({ $0.endDate }).max() else { break }
            watermark = latestEnd.addingTimeInterval(0.001)
            if watermark >= Date() { break }
        }

        // Final sort — pagination typically yields them in order but
        // paranoia is cheap and the caller expects chronological order.
        all.sort { $0.startDate < $1.startDate }
        return all
    }

    /// End-to-end helper: download per-minute telemetry (TherapyOneMinutePeriodic)
    /// for all sessions starting from `from`. Returns one `PerMinuteSession`
    /// per therapy session, each containing up to six decoded channels
    /// (MaskPress, Press, RespRate, TidVol, MinVent, Snore).
    ///
    /// Unlike the daily Summary spool, this one isn't heavily paginated —
    /// typical captures are 1.5-2 kB per session and fit in a single
    /// 4 kB spool request for a few sessions at a time. Callers who need
    /// deep history should chunk their `from` windows manually.
    func downloadPerMinuteHistory(from: Date,
                                  silenceTimeoutSeconds: Double = 3.0,
                                  maxWaitSeconds: Double = 30.0) async throws -> [PerMinuteSession] {
        guard sessionKey != nil else { throw CPAPError.noSession }
        let spoolId = try await startSpool(spoolType: .therapyOneMinutePeriodic, fromDateTime: from)

        let collector = SpoolCollector()
        let previousHandler = onSpoolFragment
        onSpoolFragment = { sid, data in
            guard sid == spoolId else { return }
            collector.append(data)
        }
        defer { onSpoolFragment = previousHandler }

        _ = try await pullSpoolFragments(spoolId: spoolId)

        let startWait = Date()
        while Date().timeIntervalSince(startWait) < maxWaitSeconds {
            try await Task.sleep(nanoseconds: 250_000_000)
            if !collector.fragments.isEmpty {
                let quietFor = Date().timeIntervalSince(collector.lastFragmentAt)
                if quietFor >= silenceTimeoutSeconds { break }
            }
        }

        if collector.fragments.isEmpty { return [] }
        let combined = collector.fragments.reduce(Data()) { $0 + $1 }
        return try PerMinuteSpoolDecoder.decode(combined, clockOffsetSeconds: cpapClockOffsetSeconds)
    }

    /// Ask the CPAP what it thinks "now UTC" is via `GetDateTime` and
    /// compare against this device's real UTC clock. The difference is
    /// the CPAP's clock drift — usually 0, occasionally ±1h when the
    /// CPAP was set up in a timezone that doesn't observe DST (EST-only
    /// configuration). Stored in `cpapClockOffsetSeconds` and applied to
    /// every BLE spool timestamp at decode time so dates display
    /// correctly regardless of the user's current location.
    ///
    /// Handles the travel case cleanly: the user moves EDT → PDT, the
    /// CPAP's internal clock stays put (still 1h ahead, say), we
    /// calibrate on each connect with this device's new-timezone clock,
    /// the offset comes out the same, and decoded timestamps land on
    /// the right absolute moment that SwiftUI renders in PDT.
    func calibrateClockOffset() async {
        guard sessionKey != nil else { return }
        do {
            let resp = try await execRaw(method: "GetDateTime", paramsJSON: nil)
            let dict = try parseJSON(resp)
            guard let result = dict["result"] as? [String: Any],
                  let dtStr = result["dateTime"] as? String else {
                log.error("calibrate: GetDateTime response missing `dateTime`")
                return
            }
            // CPAP returns "2026-04-11T18:54:46.015Z" — fractional
            // seconds, zulu suffix. ISO8601DateFormatter handles it if
            // we enable `.withFractionalSeconds`.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let cpapNow = f.date(from: dtStr) else {
                log.error("calibrate: unparseable dateTime: \(dtStr, privacy: .public)")
                return
            }
            let realNow = Date()
            let delta = cpapNow.timeIntervalSince(realNow)
            cpapClockOffsetSeconds = delta
        } catch {
            log.error("calibrate: failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Targeted fetch for the history view: download the last N days of
    /// Summary data and return the decoded `DaySummary` list sorted
    /// oldest-first. Calibrates the clock offset before decoding so
    /// every returned session's `startDate` is correct real-UTC.
    /// Does NOT sync to HealthKit (that's `fetchLastSessionSummary`'s
    /// job) — this is read-only for visualisation.
    func fetchHistory(days: Int) async throws -> [DaySummary] {
        if isSimulating { return simGenerateHistory(days: days) }
        guard sessionKey != nil else { throw CPAPError.noSession }
        await calibrateClockOffset()
        let from = Date().addingTimeInterval(-Double(days) * 86400)
        let batch = try await downloadSummaryBatch(
            from: from,
            silenceTimeoutSeconds: 3.0,
            maxWaitSeconds: 30.0
        )
        return batch.sorted { $0.startDate < $1.startDate }
    }

    /// Targeted fetch for the detail view: download per-minute telemetry
    /// for the last N days alongside the Summary history. The TherapyOne-
    /// MinutePeriodic spool can hold many sessions per request — a 16 kB
    /// payload typically covers ~7 days of two-session nights — so we
    /// issue a single StartSpool and let the CPAP drain whatever it has.
    ///
    /// Returned sessions are sorted by start time (oldest first).
    /// Non-fatal: on failure returns `[]` so the detail view can fall
    /// back on template-based staging instead of erroring the whole
    /// history load.
    func fetchPerMinuteHistory(days: Int) async -> [PerMinuteSession] {
        if isSimulating { return [] }
        guard sessionKey != nil else { return [] }
        let from = Date().addingTimeInterval(-Double(days) * 86400)
        do {
            // Use a larger spoolSize so we don't truncate mid-session
            // when the user has a week of data. 32 kB is still under
            // any reasonable BLE MTU budget at 4 fragments per packet.
            let spoolId = try await startSpool(
                spoolType: .therapyOneMinutePeriodic,
                fromDateTime: from,
                maxSpoolSize: 32_768
            )
            let collector = SpoolCollector()
            let previousHandler = onSpoolFragment
            onSpoolFragment = { sid, data in
                guard sid == spoolId else { return }
                collector.append(data)
            }
            defer { onSpoolFragment = previousHandler }
            _ = try await pullSpoolFragments(spoolId: spoolId)

            let startWait = Date()
            while Date().timeIntervalSince(startWait) < 30 {
                try await Task.sleep(nanoseconds: 250_000_000)
                if !collector.fragments.isEmpty &&
                   Date().timeIntervalSince(collector.lastFragmentAt) >= 3 { break }
            }
            if collector.fragments.isEmpty { return [] }
            let combined = collector.fragments.reduce(Data()) { $0 + $1 }
            let sessions = try PerMinuteSpoolDecoder.decode(
                combined, clockOffsetSeconds: cpapClockOffsetSeconds)
            return sessions.sorted { $0.startDate < $1.startDate }
        } catch {
            log.error("fetchPerMinute: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Records shorter than this are ignored by `fetchLastSessionSummary`
    /// — they're almost certainly pressure-test sessions ("tap the power
    /// button, run for a minute or two with low pressure") rather than a
    /// real sleep session. Today's 2026-04-11 data showed a 4-minute
    /// test at 3.8 cmH₂O; normal nights are hundreds of minutes at 5+
    /// cmH₂O.
    private static let lastSessionMinThresholdMinutes = 30

    /// Fetch just the most recent sleep-session summary and publish it
    /// to `lastSessionMinutes` / `lastSessionDate`. This is a targeted
    /// fast path — pulls one spool batch covering the last 7 days
    /// (small enough to fit in the 4KB `maxSpoolSize` budget without
    /// pagination) and picks the latest record that looks like a real
    /// session. Runs in the background after session ready; safe to
    /// call repeatedly. Errors are logged but not thrown — the
    /// dashboard just keeps showing "—" on failure.
    ///
    /// Also pushes the 7-day batch into HealthKit (iOS / Catalyst only
    /// — native Mac build is a no-op stub). Dedup is handled inside
    /// `HealthKitSync` via metadata keys so repeated calls are safe.
    func fetchLastSessionSummary() async {
        if isSimulating { return }
        guard sessionKey != nil else { return }
        // Calibrate the CPAP clock once before decoding anything —
        // ensures the sessions we're about to parse come out with
        // real-UTC timestamps that match the user's wall clock.
        await calibrateClockOffset()

        let from = Date().addingTimeInterval(-7 * 86400)
        do {
            let days = try await downloadSummaryBatch(
                from: from,
                silenceTimeoutSeconds: 3.0,
                maxWaitSeconds: 15.0
            )
            let real = days
                .filter { $0.maskDurationMinutes >= Self.lastSessionMinThresholdMinutes }
                .sorted { $0.startDate < $1.startDate }
            if let last = real.last {
                self.lastSessionMinutes = last.maskDurationMinutes
                self.lastSessionDate = last.startDate
                // Climate: live dataIds are unavailable on this firmware,
                // so the gauges show per-session medians from the latest
                // Summary. Static between syncs — not realtime — but
                // represents what the device actually observed last night.
                if let v = last.ambientHumidity { self.ambientHumidity = v }
                if let v = last.heatedTubeTemp { self.heatedTubeTempActual = v }
                if let v = last.humidifierPower { self.humidifierPower = v }
                if let v = last.heatedTubePower { self.heatedTubePower = v }
            } else {
                self.lastSessionMinutes = nil
                self.lastSessionDate = nil
            }

            // Push the recent batch to HealthKit, one sample per real
            // session (not per day). On native macOS this is a no-op
            // stub; on iOS/Catalyst it requests authorization on first
            // run and inserts new sessions, skipping dupes.
            //
            // Also run the legacy cleanup: earlier builds wrote one
            // sample per day with a fake 07:00 wake time. Those are
            // gone after the first cleanup; no-op after.
            do {
                _ = try await HealthKitSync.cleanupLegacySamples()
                _ = try await HealthKitSync.sync(days, minSessionMinutes: 5)

                // Per-stage sync: run the v2 TCN classifier over the
                // per-minute telemetry for the same 7-day window and
                // write one HKCategorySample per stage run. Dedup is
                // keyed off (rawStartMs, run.startEpoch, stage) so
                // re-running is idempotent. Non-fatal — if the model
                // or HealthKit reads fail, the session-level sample
                // above is still in Health.
                await syncStageClassification(days: real)

                // Record the successful-sync timestamp for the
                // dashboard's "Last synced: ..." display. Persist so
                // a cold launch can still render the timestamp.
                let now = Date()
                lastSyncedAt = now
                UserDefaults.standard.set(now, forKey: "com.openrm.cpap.lastSyncedAt")

                // Refresh the lifetime-time-asleep aggregate (queries
                // HealthKit for all our own non-awake sleep samples).
                // Persist so the dashboard number is available on
                // the next cold launch without re-querying.
                let asleep = await HealthKitSync.fetchLifetimeTimeAsleepSeconds()
                lifetimeTimeAsleepSeconds = asleep
                UserDefaults.standard.set(asleep, forKey: "com.openrm.cpap.lifetimeTimeAsleepSeconds")
            } catch {
                log.error("healthkit: sync failed: \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            log.error("lastSession: fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// For each real session in `days`, pull per-minute telemetry,
    /// fetch HR from HealthKit covering the session window, run the v2
    /// TCN classifier, and write per-stage HKCategorySample entries.
    /// Gated on `SleepStageDetectorV2.shared` — if the model isn't in
    /// the bundle this is a no-op (the session-level sample stays).
    ///
    /// One StartSpool pulls all per-minute sessions in the window, so
    /// this issues exactly one BLE spool request regardless of how
    /// many nights it's classifying.
    private func syncStageClassification(days: [DaySummary]) async {
        guard let detector = SleepStageDetectorV2.shared else {
            log.info("staged-sleep: v2 detector unavailable, skipping")
            return
        }
        guard let firstDay = days.first else { return }
        let spanDays = max(1, Int(Date().timeIntervalSince(firstDay.startDate) / 86400) + 1)
        let perMinuteSessions = await fetchPerMinuteHistory(days: spanDays)
        guard !perMinuteSessions.isEmpty else {
            log.info("staged-sleep: no per-minute data in window")
            return
        }

        var totalInserted = 0
        var totalDupes = 0
        for pm in perMinuteSessions {
            // Each per-minute session knows its own start; length is
            // inferred from the RespRate channel length (1 value / min).
            let nMinutes = pm.channel(
                field: PerMinuteChannel.Kind.respRate.rawValue
            )?.values.count ?? 0
            // The Core ML model's input shape is constrained to
            // [minimumSessionMinutes .. 720]. Shorter spool blobs are
            // almost always mask-fit blips anyway, so skip them
            // silently rather than running the model and catching the
            // MLFeatureTypeMultiArray constraint error.
            guard nMinutes >= SleepStageDetectorV2.minimumSessionMinutes else { continue }
            let endDate = pm.startDate.addingTimeInterval(Double(nMinutes) * 60)

            // Fetch HR for this window. Empty dict is fine — the model
            // degrades to CPAP-only on those minutes (hk_available=0).
            let hrByMinute = await HealthKitSync.fetchHeartRatePerMinute(
                from: pm.startDate, to: endDate
            )
            let rawStages = detector.predict(perMinute: pm, heartRate: hrByMinute)
            guard !rawStages.isEmpty else { continue }

            // Fetch non-OpenRM sleep samples (Apple Watch, manual entry)
            // and override our Awake predictions wherever Apple says the
            // user was asleep. Fixes the mask-off-during-sleep false
            // positive: airway signals spike on mask break, the model
            // calls it Awake, but the watch still sees resting HR and
            // no actigraphy → actually asleep.
            let externalStages = await HealthKitSync.fetchExternalSleepStagesPerMinute(
                from: pm.startDate, to: endDate
            )
            let inputs = SleepStageDetectorV2.buildMinuteInputs(
                perMinute: pm, heartRate: hrByMinute
            )
            let stages = SleepStageDetectorV2.overrideWakeWithExternalSleep(
                stages: rawStages, minutes: inputs, externalStages: externalStages
            )

            let runs = SleepStageDetectorV2.runs(
                stages: stages, startDate: pm.startDate
            ).map {
                HealthKitSync.StageRun(
                    stage: $0.stage, startDate: $0.startDate, endDate: $0.endDate
                )
            }
            do {
                let result = try await HealthKitSync.syncStageRuns(
                    rawStartMs: pm.timestampMs, runs: runs
                )
                totalInserted += result.inserted
                totalDupes += result.duplicates
            } catch {
                log.error("staged-sleep: HealthKit write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("staged-sleep: inserted=\(totalInserted) dupes=\(totalDupes) sessions=\(perMinuteSessions.count)")
    }

    /// Allocate one Summary spool starting at `from`, pull its fragments,
    /// and decode them into `[DaySummary]`. This is one page of the
    /// pagination loop in `downloadSummaryHistory`.
    ///
    /// The CPAP pushes data as `SpoolFragment` JSON-RPC notifications
    /// with no explicit completion signal (OSCAR source mentions
    /// `spoolComplete` / `spoolIncomplete` statuses but we haven't seen
    /// them on the BLE wire). We instead wait for silence — if no
    /// fragment arrives for `silenceTimeoutSeconds`, assume this spool
    /// is drained. A hard cap of `maxWaitSeconds` prevents hangs.
    private func downloadSummaryBatch(from: Date,
                                      silenceTimeoutSeconds: Double,
                                      maxWaitSeconds: Double) async throws -> [DaySummary] {
        let spoolId = try await startSpool(spoolType: .summary, fromDateTime: from)

        let collector = SpoolCollector()
        let previousHandler = onSpoolFragment
        onSpoolFragment = { sid, data in
            guard sid == spoolId else { return }
            collector.append(data)
        }
        defer { onSpoolFragment = previousHandler }

        _ = try await pullSpoolFragments(spoolId: spoolId)

        let startWait = Date()
        while Date().timeIntervalSince(startWait) < maxWaitSeconds {
            try await Task.sleep(nanoseconds: 250_000_000)
            if !collector.fragments.isEmpty {
                let quietFor = Date().timeIntervalSince(collector.lastFragmentAt)
                if quietFor >= silenceTimeoutSeconds { break }
            }
        }

        if collector.fragments.isEmpty { return [] }

        let combined = collector.fragments.reduce(Data()) { $0 + $1 }
        // Apply the calibrated clock drift so session timestamps come
        // out as real UTC (not the CPAP's possibly-offset internal UTC).
        return try SummarySpoolDecoder.decode(combined, clockOffsetSeconds: cpapClockOffsetSeconds)
    }

    // MARK: - Raw RPC plumbing

    private func nextId() -> Int {
        let id = nextRequestId
        nextRequestId += 1
        return id
    }

    private func sendRPC(_ request: [String: Any]) async throws -> String {
        let json = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard let id = request["id"] as? Int else { throw CPAPError.protocolError("no id") }
        // Unencrypted uses channel 0x0393
        let frame = FigFrame.encode(sequence: 0x0393, payload: json)
        return try await sendAndWait(frame: frame, requestId: UInt16(id))
    }

    private func sendEncryptedRPC(_ request: [String: Any]) async throws -> String {
        guard let key = sessionKey else { throw CPAPError.noSession }
        let json = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard let id = request["id"] as? Int else { throw CPAPError.protocolError("no id") }
        let encryptedPayload = try FigCrypto.encrypt(jsonPayload: json, sessionKey: key)
        // Encrypted traffic uses channel 0x0397 (TX), RX comes on 0x0396
        let frame = FigFrame.encode(sequence: 0x0397, payload: encryptedPayload)
        return try await sendAndWait(frame: frame, requestId: UInt16(id))
    }

    /// 10s RPC timeout. Without this, a missing/mis-keyed response leaves
    /// the pair sheet stuck on "Exchanging keys..." forever.
    private static let rpcTimeoutNanos: UInt64 = 10_000_000_000

    private func sendAndWait(frame: Data, requestId: UInt16) async throws -> String {
        // Spawn a watchdog that will resume the continuation with a timeout
        // error if no response arrives in time.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.rpcTimeoutNanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self = self else { return }
                if let cont = self.pendingResponses.removeValue(forKey: requestId) {
                    log.error("sendAndWait: timeout waiting for response id=\(requestId)")
                    cont.resume(throwing: CPAPError.timeout(requestId: requestId))
                }
            }
        }

        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestId] = continuation
            do {
                try ble.write(frame)
            } catch {
                pendingResponses[requestId] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        rxBuffer.append(data)
        let (frames, remaining) = FigFrame.decode(rxBuffer)
        rxBuffer = remaining
        for frame in frames {
            var payload = frame.payload
            // Channel 0x0396 = encrypted response, 0x0392 = plaintext response
            if frame.sequence == 0x0396, let key = sessionKey {
                if let decrypted = try? FigCrypto.decrypt(ivAndCiphertext: payload, sessionKey: key) {
                    payload = decrypted
                } else {
                    log.error("rx: failed to decrypt 0x0396 frame")
                }
            }
            guard let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                continue
            }
            // JSON-RPC notifications (no `id`) — HeartBeat is ignored,
            // EventNotification is routed to the subscription handler.
            if let method = dict["method"] as? String, dict["id"] == nil {
                if method == "EventNotification" {
                    handleEventNotification(dict)
                } else if method == "SpoolFragment" {
                    handleSpoolFragment(dict)
                }
                continue
            }
            let rawId = dict["id"]
            let id: Int? = (rawId as? Int) ?? (rawId as? NSNumber)?.intValue
            guard let id = id else {
                log.error("rx: response has no usable id")
                continue
            }
            if let cont = pendingResponses.removeValue(forKey: UInt16(id)) {
                let jsonStr = String(data: payload, encoding: .utf8) ?? ""
                cont.resume(returning: jsonStr)
            } else {
                log.error("rx: no pending continuation for id=\(id)")
            }
        }
    }

    private func parseJSON(_ str: String) throws -> [String: Any] {
        guard let data = str.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CPAPError.protocolError("invalid JSON")
        }
        if let err = dict["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "unknown"
            throw CPAPError.rpcError(msg)
        }
        return dict
    }

    enum CPAPError: Error, LocalizedError {
        case deviceNotFound
        case notPaired
        case noSession
        case protocolError(String)
        case rpcError(String)
        case timeout(requestId: UInt16)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound: return "CPAP not found"
            case .notPaired: return "Not paired - enter PIN first"
            case .noSession: return "No active session"
            case .protocolError(let m): return "Protocol error: \(m)"
            case .rpcError(let m): return "Device error: \(m)"
            case .timeout(let id): return "Timed out waiting for response (id=\(id))"
            }
        }
    }
    // MARK: - Simulation mode

    private func simGenerateHistory(days: Int) -> [DaySummary] {
        var rng = SystemRandomNumberGenerator()
        var result: [DaySummary] = []
        let cal = Calendar.current
        for i in (1...days).reversed() {
            let dayStart = cal.startOfDay(for: Date()).addingTimeInterval(-Double(i) * 86400 + 13 * 3600)
            let dayEnd = dayStart.addingTimeInterval(86400)
            let dur = Int.random(in: 300...480, using: &rng)
            let ahi = Double.random(in: 0...5, using: &rng)
            let hi = ahi * Double.random(in: 0.3...0.7, using: &rng)
            let oai = (ahi - hi) * Double.random(in: 0.2...0.6, using: &rng)
            let cai = (ahi - hi - oai) * Double.random(in: 0.3...0.8, using: &rng)

            let sess1Start = dayStart.addingTimeInterval(Double.random(in: 7*3600...10*3600, using: &rng))
            let sess1Dur = Int.random(in: 200...350, using: &rng)
            var sessions = [DaySummary.Session(
                startDate: sess1Start, durationMinutes: sess1Dur,
                rawStartMs: UInt64(sess1Start.timeIntervalSince1970 * 1000)
            )]
            if dur - sess1Dur > 60 {
                let sess2Start = sess1Start.addingTimeInterval(Double(sess1Dur + 30) * 60)
                sessions.append(DaySummary.Session(
                    startDate: sess2Start, durationMinutes: dur - sess1Dur,
                    rawStartMs: UInt64(sess2Start.timeIntervalSince1970 * 1000)
                ))
            }

            let mp50 = Double.random(in: 5...10, using: &rng)
            result.append(DaySummary(
                startDate: dayStart, endDate: dayEnd,
                maskDurationMinutes: dur,
                recordGeneratedAt: dayEnd,
                ahi: (ahi * 100).rounded() / 100,
                ai: ((oai + cai) * 100).rounded() / 100,
                hi: (hi * 100).rounded() / 100,
                oai: (oai * 100).rounded() / 100,
                cai: (cai * 100).rounded() / 100,
                uai: 0, rin: Double.random(in: 0...1, using: &rng),
                maskPressure: .init(p50: mp50, p95: mp50 + 2, max: mp50 + 4),
                targetIPAP: .init(p50: mp50 + 0.5, p95: mp50 + 2.5, max: mp50 + 4.5),
                targetEPAP: .init(p50: mp50, p95: mp50 + 2, max: mp50 + 4),
                leak: .init(p50: 0.02, p70: 0.06, p95: 0.18, max: 0.6),
                tidalVolume: .init(p50: 0.35, p95: 0.45, max: 0.7),
                minuteVentilation: .init(p50: 5.5, p95: 7, max: 12),
                respiratoryRate: .init(p50: 15, p95: 21, max: 29),
                maskEventCount: sessions.count,
                ambientHumidity: 15, heatedTubeTemp: 27,
                humidifierPower: 17, heatedTubePower: 3,
                sessions: sessions,
                unknownFields: [:]
            ))
        }
        return result
    }

    func enterSimulation() {
        isSimulating = true
        isPaired = true
        sessionEstablished = true
        fgState = "Standby"
        systemError = "NoError"
        machineSerialNumber = "SIM00000000"
        MaintenanceReminder.cleaning.setMachineId("SIM00000000")
        MaintenanceReminder.filter.setMachineId("SIM00000000")

        therapyRunSeconds = 7_873_770    // ~91 days, matches real device
        lastTherapyUse = Self.isoDateTimeFormatter.string(from: Date().addingTimeInterval(-3600))
        lastTherapyUseDate = Date().addingTimeInterval(-3600)
        lastSessionMinutes = 444          // 7h 24m
        lastSessionDate = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400))

        lifetimeTimeAsleepSeconds = 680_400  // ~189 hrs
        lastSyncedAt = Date()
        UserDefaults.standard.set(Date(), forKey: "com.openrm.cpap.lastSyncedAt")

        climateControl = "Auto"
        humidifierLevel = 1
        heatedTubeTempSetting = 30
    }

    func exitSimulation() {
        simTask?.cancel()
        simTask = nil
        isSimulating = false
        isPaired = false
        sessionEstablished = false
        isRunning = false
        fgState = "—"
        maskPressure = 0
        inspiratoryPressure = 0
        setPressure = 0
        leakRate = 0
        remainingRampTime = 0
        therapyRunSeconds = 0
        lastSessionMinutes = nil
        lastSessionDate = nil
        machineSerialNumber = nil
        MaintenanceReminder.cleaning.setMachineId(nil)
        MaintenanceReminder.filter.setMachineId(nil)
    }

    func simStartTherapy() {
        guard isSimulating else { return }
        isRunning = true
        fgState = "Therapy"
        lastTherapyUseDate = Date()
        remainingRampTime = 45 * 60

        simTask?.cancel()
        simTask = Task { [weak self] in
            guard let self else { return }
            var tick: Int = 0
            let breathPeriod = 4.0   // ~15 breaths/min
            let rampSeconds = 45.0 * 60
            let minPress = 5.0
            let maxPress = 15.0

            while !Task.isCancelled {
                tick += 1
                let elapsed = Double(tick) * 1.5
                let rampFrac = min(elapsed / rampSeconds, 1.0)
                let targetPress = minPress + rampFrac * (maxPress - minPress)

                // Breathing sine wave on top of target
                let phase = elapsed / breathPeriod * 2.0 * .pi
                let breathAmp = 1.5
                let mask = targetPress + sin(phase) * breathAmp
                let inspir = targetPress + sin(phase + 0.3) * breathAmp * 0.8

                // Leak with occasional spikes
                let baseLeak = 1.0 + sin(elapsed * 0.03) * 0.5
                let spike = (tick % 40 == 0) ? Double.random(in: 4...8) : 0
                let leak = max(0, baseLeak + spike)

                // Ramp countdown
                let rampLeft = max(0, Int(rampSeconds - elapsed))

                await MainActor.run {
                    self.maskPressure = max(0, mask)
                    self.inspiratoryPressure = max(0, inspir)
                    self.setPressure = targetPress
                    self.leakRate = leak
                    self.remainingRampTime = rampLeft
                }

                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func simStopTherapy() {
        guard isSimulating else { return }
        simTask?.cancel()
        simTask = nil
        isRunning = false
        fgState = "Standby"
        maskPressure = 0
        inspiratoryPressure = 0
        setPressure = 0
        leakRate = 0
        remainingRampTime = 0
    }
}

// MARK: - Data/hex helpers

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        self = data
    }
}
