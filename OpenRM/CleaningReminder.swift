//
//  CleaningReminder.swift
//  OpenRM
//
//  Generic CPAP maintenance-countdown reminder. Two shared instances
//  ship today: `.cleaning` (7-day mask + hose wash) and `.filter`
//  (30-day machine intake filter replacement). Add another `shared`
//  static if a new task shows up — same code path supports it.
//
//  Persists the last-reset timestamp in UserDefaults so the LED
//  panels survive cold launches. Negative `daysRemaining` = past due;
//  the LED renders "-N" and the panel color shifts red.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class MaintenanceReminder: ObservableObject {
    /// ResMed-recommended mask cushion + hose wash cadence.
    static let cleaning = MaintenanceReminder(
        cadenceDays: 7,
        defaultsKey: "com.openrm.cpap.lastCleanedAt"
    )

    /// ResMed intake-filter replacement cadence (standard hypoallergenic
    /// filter for the AirSense 11 — about 30 days per the device
    /// maintenance guide).
    static let filter = MaintenanceReminder(
        cadenceDays: 30,
        defaultsKey: "com.openrm.cpap.lastFilterReplacedAt"
    )

    let cadenceDays: Int
    /// Base key prefix. When a machine is bound via `setMachineId`, the
    /// effective UserDefaults key becomes `<baseKey>.<machineId>` so each
    /// paired CPAP keeps its own countdown. Before a machine is bound, the
    /// legacy unqualified key is used — preserves reminder state set before
    /// this feature existed.
    private let baseKey: String
    private var machineId: String?

    @Published private(set) var lastResetAt: Date?

    private init(cadenceDays: Int, defaultsKey: String) {
        self.cadenceDays = cadenceDays
        self.baseKey = defaultsKey
        self.reloadFromDefaults()
    }

    /// Bind this reminder to a specific machine. All subsequent reads and
    /// writes use a per-machine UserDefaults key, so switching CPAPs
    /// shows the correct countdown for each one. Pass `nil` on unpair.
    func setMachineId(_ id: String?) {
        guard id != machineId else { return }
        machineId = id
        reloadFromDefaults()
    }

    private var effectiveKey: String {
        guard let id = machineId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    private func reloadFromDefaults() {
        lastResetAt = UserDefaults.standard.object(forKey: effectiveKey) as? Date
    }

    /// Mark the task complete just now. Resets the countdown.
    func markDoneNow() {
        let now = Date()
        lastResetAt = now
        UserDefaults.standard.set(now, forKey: effectiveKey)
    }

    /// Days remaining until the next due date. Positive = still good,
    /// negative = past due by that many days, zero = due today. Nil
    /// if the user has never marked a reset (→ show call-to-action,
    /// not a misleading default).
    var daysRemaining: Int? {
        guard let last = lastResetAt else { return nil }
        let cal = Calendar.current
        let startOfLast = cal.startOfDay(for: last)
        let startOfToday = cal.startOfDay(for: Date())
        let daysSince = cal.dateComponents([.day], from: startOfLast, to: startOfToday).day ?? 0
        return cadenceDays - daysSince
    }

    /// Pre-formatted value for the LED panel — always 3 chars wide
    /// so digit spacing stays stable across single/double-digit
    /// counts and minus signs. " 7" / "-2" / " --" (never-set).
    var ledValueText: String {
        guard let days = daysRemaining else { return " --" }
        return String(format: "%3d", days)
    }

    /// Green while the countdown is healthy, yellow as the deadline
    /// approaches, red once we hit or pass zero. The "approaching"
    /// threshold scales with the cadence — 2 days on a 7-day clock,
    /// 5 days on a 30-day clock — so short and long reminders warn
    /// at visually comparable points in their lifecycle.
    var ledColor: Color {
        guard let days = daysRemaining else { return .yellow }
        if days <= 0 { return .red }
        let warnWindow = max(2, cadenceDays / 5)
        if days <= warnWindow { return .yellow }
        return .green
    }
}

// Back-compat typealias so existing references don't break. New code
// should reference `MaintenanceReminder.cleaning` / `.filter` directly.
typealias CleaningReminder = MaintenanceReminder

extension MaintenanceReminder {
    /// Back-compat shortcut: `CleaningReminder.shared` used to resolve
    /// to the singleton; now it points at the cleaning instance.
    static var shared: MaintenanceReminder { cleaning }

    /// Back-compat shim — old call sites wrote `markCleanedNow()`.
    func markCleanedNow() { markDoneNow() }
}
