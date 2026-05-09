//
//  DashboardView.swift
//  OpenRM
//
//  Main dashboard with the big START/STOP button on the front page.
//

import SwiftUI
import Combine

struct DashboardView: View {
    // Use the shared singleton so background sync (see BackgroundSync)
    // and the UI share a single CBCentralManager — required because
    // state restoration uses one identifier per process.
    @ObservedObject private var controller = CPAPController.shared
    @ObservedObject private var cleaning = MaintenanceReminder.cleaning
    @ObservedObject private var filter = MaintenanceReminder.filter
    @State private var showingCleaningConfirm = false
    @State private var showingFilterConfirm = false
    /// Ticks each minute to keep the Last-Synced relative time string
    /// ("5 min ago") up-to-date without a full controller republish.
    @State private var wallClock: Date = .now
    /// Drives the first-appearance reveal animation. False while the
    /// view is still handing off from the static launch screen (so
    /// only the header shows, matching the launch-screen composition);
    /// flips to true on onAppear, which cascades the staggered
    /// opacity + scale animations on every element below the header.
    @State private var contentAppeared = false
    @State private var showingPairingSheet = false
    @State private var showingDevicePickerSheet = false
    @State private var showingHistorySheet = false
    @State private var showingErrorAlert = false
    @State private var errorAlertMessage = ""
    @State private var errorIsTimeout = false
    @State private var pin: String = ""
    @State private var statusMessage: String = "Disconnected"
    @State private var isWorking: Bool = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        // Outer VStack pins the bottom metric row to the bottom of
        // the window regardless of rotation. The upper block sits in
        // a ScrollView so landscape / small windows don't clip the
        // LEDs + START button + cleaning LED — the user can just
        // scroll them if the viewport is tight, and the metrics row
        // stays visible no matter what.
        //
        // GeometryReader wraps the ScrollView so we can force the
        // inner VStack's minHeight to match the scroll viewport.
        // Without that, the ScrollView gives the VStack its
        // intrinsic content height, Spacers collapse, and everything
        // piles up at the top when the viewport is tall (portrait on
        // iPad). With minHeight = geo.size.height, Spacers expand to
        // vertically center the START button / cleaning LED.
        VStack(spacing: 0) {
        GeometryReader { geo in
        ScrollView {
        // spacing: 0 so the two outer Spacers around the START cluster
        // are the ONLY vertical gaps contributing to distribution —
        // the previous `spacing: 24` added an extra 24pt below the
        // LED row that wasn't mirrored below the cleaning LED, which
        // is what made the top gap look larger than the bottom gap.
        // Explicit paddings replace the implicit 24pt where it still
        // matters (header → LEDs).
        VStack(spacing: 0) {
            // Header: title leading, buttons trailing — ZStack so the
            // title and trailing buttons don't fight over horizontal
            // space; each is anchored to its own edge independently.
            ZStack {
                VStack(spacing: 1) {
                    Text("OpenRM")
                        .font(isCompact ? .headline : .title2)
                        .fontWeight(.bold)
                    Text(lastSyncedLabel())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: isCompact ? 6 : 10) {
                    Spacer()
                    if controller.isPaired {
                        if !controller.sessionEstablished && !controller.isSimulating {
                            Button("Connect") { Task { await connect() } }
                                .buttonStyle(.bordered)
                                .controlSize(isCompact ? .small : .regular)
                                .disabled(isWorking)
                        }
                        Button("Unpair") {
                            if controller.isSimulating {
                                controller.exitSimulation()
                            } else {
                                controller.disconnect()
                                CredentialStore.clear()
                                controller.isPaired = false
                                controller.sessionEstablished = false
                                controller.machineSerialNumber = nil
                                MaintenanceReminder.cleaning.setMachineId(nil)
                                MaintenanceReminder.filter.setMachineId(nil)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(isCompact ? .small : .regular)
                    } else {
                        Button("Pair") { Task { await pairFlow() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(isCompact ? .small : .regular)
                            .disabled(isWorking)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 1.5)
                                    .onEnded { _ in
                                        controller.enterSimulation()
                                    }
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, isCompact ? 8 : 16)
            // Replaces the 24pt VStack(spacing:) that used to live
            // between every sibling. Only the header-to-LEDs gap
            // still needs it.
            .padding(.bottom, isCompact ? 8 : 24)

            // LED instrument panel — stays pinned just under the
            // header (no expanding Spacer between them) so the top
            // row of readouts sits near the top of the window in
            // every orientation.
            HStack(spacing: isCompact ? 2 : 12) {
                LEDPanel(
                    title: "MASK",
                    valueText: formatPressure(controller.maskPressure),
                    unit: "cmH₂O",
                    color: .green,
                    size: isCompact ? CGSize(width: 18, height: 32) : CGSize(width: 42, height: 76),
                    compact: isCompact
                )
                LEDPanel(
                    title: "SET",
                    valueText: formatPressure(controller.setPressure),
                    unit: "cmH₂O",
                    color: .green,
                    size: isCompact ? CGSize(width: 18, height: 32) : CGSize(width: 42, height: 76),
                    compact: isCompact
                )
                LEDPanel(
                    title: "LEAK",
                    valueText: formatPressure(controller.leakRate),
                    unit: "L/min",
                    color: leakColor(controller.leakRate),
                    size: isCompact ? CGSize(width: 18, height: 32) : CGSize(width: 42, height: 76),
                    compact: isCompact
                )
            }
            .padding(.horizontal, 16)
            .opacity(controller.sessionEstablished ? (contentAppeared ? 1.0 : 0.0) : 0.3)
            .offset(y: contentAppeared ? 0 : -12)
            .animation(.easeOut(duration: 0.35).delay(0.05), value: contentAppeared)

            // Even vertical distribution: Spacer above the START button,
            // Spacer between the button and the maintenance LEDs, Spacer
            // below the maintenance LEDs. All three gaps stay equal as
            // the viewport resizes.
            Spacer()

            // START/STOP button
            Button(action: { Task { await togglePower() } }) {
                ZStack {
                    Circle()
                        .fill(controller.isRunning ? Color.white.gradient : Color.green.gradient)
                        .frame(width: isCompact ? 150 : 220, height: isCompact ? 150 : 220)
                        .shadow(radius: 10)
                    VStack(spacing: isCompact ? 4 : 8) {
                        Image(systemName: "power")
                            .font(.system(size: isCompact ? 48 : 72, weight: .bold))
                            .foregroundStyle(controller.isRunning ? .red : .white)
                        Text(controller.isRunning ? "STOP" : "START")
                            .font(isCompact ? .subheadline : .title)
                            .fontWeight(.bold)
                            .foregroundStyle(controller.isRunning ? .red : .white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isWorking || !controller.sessionEstablished)
            .opacity(controller.sessionEstablished ? 1.0 : 0.5)
            .overlay(alignment: .bottom) {
                ProgressView()
                    .opacity(isWorking ? 1 : 0)
                    .offset(y: 20)
            }

            Spacer()

            // Maintenance reminders
            HStack(spacing: isCompact ? 8 : 12) {
                Spacer()
                Button {
                    showingCleaningConfirm = true
                } label: {
                    LEDPanel(
                        title: "CLEAN EQUIPMENT IN",
                        valueText: cleaning.ledValueText,
                        unit: "days",
                        color: cleaning.ledColor,
                        size: isCompact ? CGSize(width: 18, height: 32) : CGSize(width: 32, height: 56),
                        compact: isCompact
                    )
                    .frame(maxWidth: isCompact ? 170 : 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: isCompact ? 12 : 16)
                            .stroke(Color.blue, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                Button {
                    showingFilterConfirm = true
                } label: {
                    LEDPanel(
                        title: "REPLACE FILTER IN",
                        valueText: filter.ledValueText,
                        unit: "days",
                        color: filter.ledColor,
                        size: isCompact ? CGSize(width: 18, height: 32) : CGSize(width: 32, height: 56),
                        compact: isCompact
                    )
                    .frame(maxWidth: isCompact ? 170 : 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: isCompact ? 12 : 16)
                            .stroke(Color.blue, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Spacer()
        }
        .frame(minHeight: geo.size.height)
        }   // close ScrollView — scrollable upper section ends here
        }   // close GeometryReader

            // (status tiles removed — state is conveyed via header buttons + status message)

            // Machine metrics row — tap LAST SESSION to open History.
            // Lives outside the ScrollView so it stays anchored to the
            // bottom of the window regardless of orientation or
            // viewport height. Always visible; shows placeholders when
            // not connected.
            HStack(spacing: isCompact ? 4 : 12) {
                    metricTile(
                        label: "LIFETIME USE",
                        primary: controller.therapyRunSeconds > 0 ? formatHours(controller.therapyRunSeconds) : "—",
                        secondary: controller.therapyRunSeconds > 0 ? formatDays(controller.therapyRunSeconds) : " "
                    )
                    metricTile(
                        label: "TOTAL ASLEEP",
                        primary: controller.lifetimeTimeAsleepSeconds > 0 ? formatHours(controller.lifetimeTimeAsleepSeconds) : "—",
                        secondary: controller.lifetimeTimeAsleepSeconds > 0 ? formatDays(controller.lifetimeTimeAsleepSeconds) : " "
                    )
                    metricTile(
                        label: "LAST USE",
                        primary: formatLastUseDate(controller.lastTherapyUse),
                        secondary: formatLastUseTime(controller.lastTherapyUse)
                    )
                    // Tappable LAST SESSION tile → opens History. Only
                    // tappable (and blue-outlined) when a session is
                    // established; disconnected state shows a plain
                    // uninteractive tile.
                    Button { showingHistorySheet = true } label: {
                        metricTile(
                            label: "LAST SESSION",
                            primary: controller.lastSessionMinutes == nil ? "—" : formatSessionDuration(controller.lastSessionMinutes),
                            secondary: controller.lastSessionMinutes == nil ? " " : formatSessionDate(controller.lastSessionDate)
                        )
                        .overlay {
                            if controller.sessionEstablished && controller.lastSessionMinutes == nil {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(controller.sessionEstablished ? Color.blue : Color.clear, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.sessionEstablished)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .opacity(controller.sessionEstablished ? 1.0 : 0.5)
        }   // close outer VStack (ScrollView + metrics row)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 760)
        #endif
        .sheet(isPresented: $showingPairingSheet) {
            pairingSheet
        }
        .sheet(isPresented: $showingDevicePickerSheet) {
            devicePickerSheet
        }
        .sheet(isPresented: $showingHistorySheet) {
            #if os(macOS)
            HistoryView(controller: controller)
                .frame(minWidth: 800, idealWidth: 1000, minHeight: 800, idealHeight: 1000)
            #else
            HistoryView(controller: controller)
            #endif
        }
        .alert("Mark mask + hose as cleaned?", isPresented: $showingCleaningConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Cleaned now") { cleaning.markDoneNow() }
        } message: {
            Text("This resets the 7-day countdown starting today.")
        }
        .alert("Mark filter as replaced?", isPresented: $showingFilterConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Replaced now") { filter.markDoneNow() }
        } message: {
            Text("This resets the 30-day countdown starting today.")
        }
        // Error dialog — replaces the red text at the bottom.
        // Timeout errors get Cancel + Retry; other errors just OK.
        .alert("Error", isPresented: $showingErrorAlert) {
            if errorIsTimeout {
                Button("Cancel", role: .cancel) { }
                Button("Retry") { Task { await connect() } }
            } else {
                Button("OK", role: .cancel) { }
            }
        } message: {
            Text(errorAlertMessage)
        }
        // Start/stop polling based on session state. Fires on session
        // establish and on disappear (covers both connect and unpair).
        .onChange(of: controller.sessionEstablished) { _, established in
            if established {
                controller.startLivePolling()
                // Background: run any staged probes.json, then fetch
                // the most recent sleep-session summary for the LAST
                // SESSION metric tile. Sequenced because both grab a
                // Summary spool and install an onSpoolFragment handler
                // — concurrent runs would race on that handler.
                Task {
                    await controller.fetchMachineIdentity()
                    await controller.fetchClimateSettings()
                }
                Task {
                    await controller.runProbesFromFile()
                    await controller.fetchLastSessionSummary()
                }
            } else {
                controller.stopLivePolling()
                // Clear stale tile values so a new connect starts fresh.
                controller.lastSessionMinutes = nil
                controller.lastSessionDate = nil
            }
        }
        .onDisappear {
            controller.stopLivePolling()
        }
        // Tick once a minute so the "Last synced: N min ago" label
        // stays fresh. Cheap: only publishes a Date into a single
        // @State, touched by one Text view.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { t in
            wallClock = t
        }
        // Flip the launch-screen-handoff reveal flag the moment the
        // view lands. SwiftUI's `.animation(_:value:)` on each
        // descendant fires the staggered fade-in against this.
        .onAppear {
            contentAppeared = true
        }
        // Auto-reconnect when CoreBluetooth reports a drop. The user
        // shouldn't have to close/reopen the app to recover from a
        // temporary BLE outage. We retry every few seconds while CB is
        // ready and we have stored credentials but no live session.
        .onChange(of: controller.ble.state) { _, state in
            guard state == .disconnected,
                  controller.isPaired,
                  !controller.sessionEstablished else { return }
            Task { await reconnectLoop() }
        }
        // Auto-connect on app launch if we already have stored credentials.
        // CoreBluetooth fires its first state callback asynchronously a
        // few hundred ms after init, so we have to wait for
        // `ble.isBluetoothReady == true` (set from
        // centralManagerDidUpdateState). Polling `ble.state` directly
        // doesn't work because it stays at `.disconnected` during the
        // pre-init window — indistinguishable from "CB is up, nothing
        // connected yet".
        .task {
            guard controller.isPaired, !controller.sessionEstablished else { return }
            // Wait up to 3s for CB to report .poweredOn.
            for _ in 0..<30 where !controller.ble.isBluetoothReady {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard controller.ble.isBluetoothReady else {
                statusMessage = "Bluetooth not ready"
                return
            }
            await connect()
        }
    }

    private func formatPressure(_ v: Double) -> String {
        // Always 4 chars: "NN.N" or " N.N". Matches a 4-digit LED display.
        String(format: "%4.1f", v)
    }

    /// Compact readout for the experimental diagnostic channels. Mono
    /// font so values line up; `—` when we haven't received a sample yet.
    @ViewBuilder
    private func diagReadout(label: String, value: Int?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value.map { "\($0)" } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    /// Heated tube temperature to display on the TUBE TEMP gauge.
    /// Seeded from the Summary spool's per-session median after each sync.
    /// This firmware doesn't expose a live tube-temp dataId, so the value
    /// is static between syncs — gauge reflects the last session, not now.
    private var inferredHeatedTubeTemp: Double {
        controller.heatedTubeTempActual
    }

    /// Ambient humidity median from the latest Summary session. Same
    /// caveats as the tube temp: not realtime, per-sync refresh.
    private var inferredAmbientHumidity: Double {
        controller.ambientHumidity
    }

    /// LEAK panel color thresholds (L/min):
    ///  • < 24  → green  (well within mask seal spec)
    ///  • 24–40 → yellow (rising leak, may compromise therapy)
    ///  • > 40  → red    (large leak — therapy effectiveness reduced)
    private func leakColor(_ leak: Double) -> Color {
        if leak > 40 { return .red }
        if leak > 24 { return .yellow }
        return .green
    }

    /// Short human-readable "last synced" line. Uses a relative
    /// formatter so the user reads freshness at a glance ("5 min ago")
    /// instead of parsing a wall-clock timestamp. `wallClock` forces
    /// a recompute every minute so the string stays current even
    /// while the dashboard is still.
    private func lastSyncedLabel() -> String {
        guard let ts = controller.lastSyncedAt else { return "Apple Health Last Synced: —" }
        _ = wallClock   // read dep for reactivity
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return "Apple Health Last Synced: \(fmt.localizedString(for: ts, relativeTo: Date()))"
    }

    private func formatHours(_ seconds: Int) -> String {
        let hrs = Double(seconds) / 3600.0
        return String(format: "%.0f hrs", hrs)
    }

    private func formatDays(_ seconds: Int) -> String {
        let days = Double(seconds) / 86400.0
        return String(format: "%.1f days", days)
    }

    private func formatLastUseDate(_ iso: String) -> String {
        // "2026-04-11T15:22:32.000Z" -> "Apr 11"
        guard iso.count >= 10 else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: String(iso.prefix(19)) + "Z") {
            let out = DateFormatter()
            out.dateFormat = "MMM d"
            return out.string(from: date)
        }
        return String(iso.prefix(10))
    }

    private func formatLastUseTime(_ iso: String) -> String {
        guard iso.count >= 19 else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: String(iso.prefix(19)) + "Z") {
            let out = DateFormatter()
            out.dateFormat = "h:mm a"
            return out.string(from: date)
        }
        return ""
    }

    /// "9h 45m" / "27m" / "—". Last-session tile primary line.
    private func formatSessionDuration(_ minutes: Int?) -> String {
        guard let m = minutes else { return "—" }
        let h = m / 60
        let mm = m % 60
        if h == 0 { return "\(mm)m" }
        return "\(h)h \(mm)m"
    }

    /// "Apr 10" / "—" for the last-session tile secondary line.
    private func formatSessionDate(_ date: Date?) -> String {
        guard let d = date else { return "—" }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        return out.string(from: d)
    }

    private func metricTile(label: String, primary: String, secondary: String) -> some View {
        // Label pinned to top, secondary pinned to bottom, primary in a
        // ZStack so it sits at the tile's geometric center regardless of
        // whether the label is one or two lines long. Earlier VStack +
        // Spacer layout left the primary slightly below center because
        // the 2-line label is taller than the 1-line secondary.
        ZStack {
            Text(primary.isEmpty ? "—" : primary)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            VStack(spacing: 0) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
                Text(secondary.isEmpty ? "\u{200B}" : secondary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Device Info Sheet

    // MARK: - Pairing Sheet

    // MARK: - Device Picker Sheet

    private var devicePickerSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Select Device")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Cancel") {
                    controller.ble.stopScan()
                    showingDevicePickerSheet = false
                }
            }

            let cpapDevices = controller.ble.discoveredDevices.filter {
                $0.advertisedServices.contains(BLEManager.serviceUUID)
            }
            if cpapDevices.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Searching for CPAP devices…")
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                List(cpapDevices) { device in
                    Button {
                        Task { await connectToDevice(device) }
                    } label: {
                        HStack {
                            Image(systemName: "lungs.fill")
                                .foregroundStyle(.orange)
                            Text(device.name)
                                .font(.body)
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
    }

    // MARK: - Pairing Sheet

    private var pairingSheet: some View {
        VStack(spacing: 20) {
            Text("Pair with AirSense 11")
                .font(.title2)
                .fontWeight(.bold)

            Text("Look at your CPAP screen and enter the 4-digit PIN shown.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)

            PINDisplay(pin: pin)

            PINKeypad(
                onDigit: { d in
                    guard pin.count < 4 else { return }
                    pin.append(d)
                },
                onBackspace: {
                    if !pin.isEmpty { pin.removeLast() }
                }
            )

            HStack(spacing: 12) {
                Button("Cancel") {
                    showingPairingSheet = false
                    pin = ""
                }
                .buttonStyle(.bordered)

                Button("Pair") {
                    Task { await performPairing() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count < 4 || isWorking)
            }

            if isWorking {
                ProgressView("Exchanging keys...")
            }
        }
        .padding(40)
        .frame(width: 400)
    }

    // MARK: - Actions

    /// Scan for nearby BLE devices and show the picker sheet.
    /// User picks a device → we connect → show the PIN sheet.
    private func pairFlow() async {
        isWorking = true
        statusMessage = "Scanning..."
        controller.ble.startScan()
        // Let the scan run for a few seconds to populate the list
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        isWorking = false
        if controller.ble.discoveredDevices.isEmpty {
            statusMessage = "No devices found"
            showError("No BLE devices found. Make sure your CPAP is powered on and in range.")
        } else {
            statusMessage = "Select your device"
            showingDevicePickerSheet = true
        }
    }

    /// Called when the user picks a device from the scan list.
    private func connectToDevice(_ device: BLEManager.DiscoveredDevice) async {
        showingDevicePickerSheet = false
        isWorking = true
        statusMessage = "Connecting to \(device.name)..."
        do {
            try await controller.connectToDiscovered(device)
            statusMessage = "Connected — enter PIN"
            showingPairingSheet = true
        } catch {
            let msg = error.localizedDescription
            statusMessage = "Disconnected"
            showError(msg, isTimeout: msg.lowercased().contains("timeout"))
        }
        isWorking = false
    }

    private func showError(_ message: String, isTimeout: Bool = false) {
        errorAlertMessage = message
        errorIsTimeout = isTimeout
        showingErrorAlert = true
    }

    /// Auto-reconnect after CoreBluetooth drops the link. Polls the
    /// BLE state at growing intervals (2s → 4s → 8s, capped) and bails
    /// out as soon as the session re-establishes or the user manually
    /// unpairs. Designed to be re-entrancy-safe — multiple invocations
    /// short-circuit on the `isWorking` and `sessionEstablished` checks.
    private func reconnectLoop() async {
        var delay: UInt64 = 2_000_000_000   // 2 s
        for attempt in 1...8 {
            if controller.sessionEstablished || !controller.isPaired { return }
            if isWorking { return }          // user-initiated work in progress
            statusMessage = "Reconnecting (attempt \(attempt))…"
            try? await Task.sleep(nanoseconds: delay)
            guard controller.ble.isBluetoothReady else { continue }
            await connect()
            if controller.sessionEstablished { return }
            delay = min(delay * 2, 16_000_000_000)  // back off, cap 16s
        }
        statusMessage = "Disconnected — open Reconnect from header"
    }

    private func connect() async {
        isWorking = true
        statusMessage = "Scanning..."
        controller.lastError = nil
        do {
            try await controller.scanAndConnect()
            statusMessage = "Connected"
            if controller.isPaired {
                statusMessage = "Resuming session..."
                try await controller.resumeSession()
                statusMessage = "Session ready"
            } else {
                statusMessage = "Tap Pair to enter PIN"
            }
        } catch {
            let msg = error.localizedDescription
            statusMessage = "Disconnected"
            let timeout = msg.lowercased().contains("timeout") || msg.contains("id=")
            showError(msg, isTimeout: timeout)
        }
        isWorking = false
    }

    private func performPairing() async {
        isWorking = true
        do {
            try await controller.pair(pin: pin)
            statusMessage = "Paired and session ready"
            showingPairingSheet = false
            pin = ""
        } catch {
            showError(error.localizedDescription)
            statusMessage = "Pairing failed"
        }
        isWorking = false
    }

    private func togglePower() async {
        if controller.isSimulating {
            if controller.isRunning {
                controller.simStopTherapy()
            } else {
                controller.simStartTherapy()
            }
            return
        }
        isWorking = true
        do {
            if controller.isRunning {
                try await controller.stopTherapy()
                statusMessage = "Therapy stopped"
            } else {
                try await controller.startTherapy()
                statusMessage = "Therapy running"
            }
        } catch {
            showError(error.localizedDescription)
        }
        isWorking = false
    }

    // MARK: - Helpers

    private func statusTile(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var bleStatusText: String {
        switch controller.ble.state {
        case .disconnected: return "Off"
        case .bluetoothOff: return "BT Off"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected: return "Linked"
        case .ready: return "Ready"
        case .error(let m): return "Err: \(m.prefix(10))"
        }
    }

    private var bleStatusColor: Color {
        switch controller.ble.state {
        case .ready, .connected: return .green
        case .scanning, .connecting: return .orange
        case .error: return .red
        default: return .gray
        }
    }

    // connectionIndicator removed — status shown via BLE tile
}

#Preview {
    DashboardView()
}
