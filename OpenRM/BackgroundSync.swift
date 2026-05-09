//
//  BackgroundSync.swift
//  OpenRM
//
//  Headless sync orchestrator. Wakes the app from iOS background
//  (either via BGAppRefreshTask scheduling or via CoreBluetooth state
//  restoration), connects to the CPAP, pulls the latest therapy data,
//  runs sleep-stage classification, and writes the result to Apple
//  Health — all without the user opening the app.
//
//  Two entry points feed this:
//
//  1. BGTask handler (this file) — iOS fires BGAppRefreshTaskRequest
//     every few hours at its discretion. We register the task
//     identifier at app launch, schedule the next run on scene
//     background, and perform the sync when the task actually fires.
//
//  2. State restoration (BLEManager.willRestoreState) — when our
//     subscribed peripheral broadcasts while the app is suspended,
//     iOS relaunches us headlessly and invokes the willRestoreState
//     delegate. Subsequent `fgState` transitions into "Standby"
//     (therapy ended) should trigger the same sync path here.
//
//  Both paths converge on `CPAPController.fetchLastSessionSummary()`,
//  which runs the full Summary-spool pull + 7-day history classify +
//  HealthKit write. On BGTask path we disconnect cleanly on
//  completion so iOS can re-suspend us.
//

#if canImport(BackgroundTasks) && !os(macOS)
import Foundation
import BackgroundTasks
import os

private let bgLog = Logger(subsystem: "com.openrm.cpap", category: "BackgroundSync")

@MainActor
final class BackgroundSync {
    /// Must exactly match the value in
    /// `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers` — iOS will
    /// reject registration otherwise.
    static let taskIdentifier = "com.openrm.cpap.sync"

    /// Minimum delay before the next BGTask can fire. iOS treats this
    /// as a hint, not a guarantee; actual firing depends on device
    /// usage patterns, battery, and foreground activity.
    private static let refreshInterval: TimeInterval = 4 * 3600   // 4 hours

    static let shared = BackgroundSync()

    /// Single source of truth. Shared with the UI path so the
    /// CBCentralManager with its state-restoration identifier is
    /// unique in-process.
    private var controller: CPAPController { CPAPController.shared }

    /// Call once, at app launch — before any UIScene comes up. iOS
    /// requires `BGTaskScheduler.register` to happen during app
    /// launch; registering later throws at runtime.
    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false); return
            }
            Task { @MainActor in
                await self?.handle(refresh)
            }
        }
    }

    /// Schedule the next wake-up. Safe to call repeatedly — submitting
    /// a new request with the same identifier replaces the pending one.
    func scheduleNextRun() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            bgLog.info("BGTask scheduled (earliest: +\(Int(Self.refreshInterval))s)")
        } catch {
            bgLog.error("BGTask schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Task handler

    private func handle(_ task: BGAppRefreshTask) async {
        // Reschedule immediately — the scheduler only holds one
        // pending request, and iOS won't auto-reschedule on
        // completion. Doing it up-front guarantees that if we crash
        // mid-sync the next run is still queued.
        scheduleNextRun()

        let work = Task { @MainActor in
            await self.performSync()
        }
        task.expirationHandler = {
            bgLog.error("BGTask expired — cancelling sync")
            work.cancel()
        }
        await work.value
        task.setTaskCompleted(success: true)
    }

    // MARK: - Sync cycle

    /// Perform one end-to-end sync: connect → calibrate → pull →
    /// classify → write to HealthKit → disconnect. Safe to call from
    /// either the BGTask handler or the state-restoration path.
    func performSync() async {
        let controller = self.controller

        // Already connected (common after state restoration)? Just pull.
        if controller.sessionEstablished {
            bgLog.info("sync: session already live, pulling")
            await controller.fetchLastSessionSummary()
            return
        }

        guard controller.isPaired else {
            bgLog.info("sync: device not paired, nothing to do")
            return
        }

        // Wait for CoreBluetooth to be ready. CBCentralManager reports
        // .poweredOn asynchronously after init — if we were freshly
        // relaunched by iOS, the first state callback hasn't fired yet.
        for _ in 0..<30 where !controller.ble.isBluetoothReady {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard controller.ble.isBluetoothReady else {
            bgLog.error("sync: Bluetooth not ready after 3 s, aborting")
            return
        }

        // Fast-reconnect via the stored peripheral UUID. We skip the
        // fallback scan (that scanAndConnect() does) because 5 s of
        // scanning blows our budget and probably won't find anything
        // new anyway: the whole point is that the known device is in
        // range and sleeping.
        guard let creds = CredentialStore.load(),
              let idStr = creds.peripheralId,
              let uuid = UUID(uuidString: idStr) else {
            bgLog.info("sync: no stored peripheral id, cannot fast-reconnect")
            return
        }
        do {
            let connected = try await controller.ble.connectByIdentifier(uuid)
            if !connected {
                bgLog.info("sync: system no longer knows peripheral, bailing")
                return
            }
        } catch {
            bgLog.error("sync: fast reconnect failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Let the session establish (SRP handshake kicks off inside
        // CPAPController via its BLE state observer).
        for _ in 0..<50 where !controller.sessionEstablished {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard controller.sessionEstablished else {
            bgLog.error("sync: session not established in 5 s")
            controller.disconnect()
            return
        }

        await controller.fetchLastSessionSummary()
        controller.disconnect()
    }
}

#else

// macOS / unsupported — BackgroundTasks isn't available. Stub so
// call sites don't need their own #if guards.
import Foundation

@MainActor
final class BackgroundSync {
    static let shared = BackgroundSync()
    func registerTasks() {}
    func scheduleNextRun() {}
    func performSync() async {}
}

#endif
