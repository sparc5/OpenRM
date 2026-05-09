//
//  HistoryView.swift
//  OpenRM
//
//  7-day sleep history rendered as an animated spiral.
//

import SwiftUI

struct HistoryView: View {
    @ObservedObject var controller: CPAPController
    @Environment(\.dismiss) private var dismiss

    private let daysToShow = 7

    @State private var days: [DaySummary] = []
    /// Per-minute telemetry keyed by the integer `startDate.timeIntervalSince1970`
    /// of the corresponding `DaySummary.Session` — rounded to the nearest
    /// second, with a ±2 minute tolerance on lookup. The BLE clock can
    /// drift a minute or so even after calibration, and Summary's session
    /// boundary is "first stable breath after ramp" vs TherapyOneMinute's
    /// "ramp start", so exact start-time equality is the exception.
    @State private var perMinute: [PerMinuteSession] = []
    @State private var trackProgress: Double = 0.0   // awake spiral reveal
    @State private var fillProgress: Double = 0.0    // therapy fill reveal
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDayIndex: Int?         // tapped day
    @State private var selectedExpand: CGFloat = 0    // expansion animation
    @State private var showingDetail = false
    /// Set explicitly at the end of `loadHistory`. The canvas uses this
    /// to decide whether to draw labels + average-sleep lines, rather
    /// than sniffing the animation progress values — those would race
    /// with task cancellation and SwiftUI coalescing and occasionally
    /// leave labels missing on a fully-loaded spiral.
    @State private var labelsReady = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sleep History")
                        .font(.title3).fontWeight(.semibold)
                    Text("Last \(daysToShow) days — one rotation per 24 h")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)

            GeometryReader { geo in
                SpiralHistoryCanvas(
                    days: days,
                    daysToShow: daysToShow,
                    trackProgress: trackProgress,
                    fillProgress: fillProgress,
                    selectedDayIndex: selectedDayIndex,
                    selectedExpand: selectedExpand,
                    labelsReady: labelsReady
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(SpatialTapGesture().onEnded { value in
                    handleSpiralTap(at: value.location, in: geo.size)
                })
            }
            .sheet(isPresented: $showingDetail, onDismiss: {
                withAnimation(.easeOut(duration: 0.2)) { selectedExpand = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    selectedDayIndex = nil
                }
            }) {
                if let idx = selectedDayIndex, idx < days.count {
                    SessionDetailView(day: days[idx], perMinute: perMinute)
                }
            }

            legend.padding(.horizontal, 20).padding(.bottom, 10)

            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadHistory() }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendSwatch(color: Color.orange.opacity(0.85), label: "On therapy")
            legendSwatch(color: Color.white.opacity(0.12),  label: "Awake")
            if !days.isEmpty {
                let perDay = days.compactMap { day -> Int? in
                    let total = day.sessions
                        .filter { $0.durationMinutes >= 5 }
                        .map { $0.durationMinutes }.reduce(0, +)
                    return total > 0 ? total : nil
                }
                if let lo = perDay.min(), let hi = perDay.max() {
                    let avg = perDay.reduce(0, +) / max(1, perDay.count)
                    Text("min \(fmtH(lo)) · avg \(fmtH(avg)) · max \(fmtH(hi))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fmtH(_ m: Int) -> String {
        let h = m / 60, mm = m % 60
        return h == 0 ? "\(mm)m" : "\(h)h \(mm)m"
    }

    /// Manually tick a progress variable from 0→1 over `duration` seconds.
    /// Canvas doesn't participate in SwiftUI's withAnimation system — it
    /// reads the raw state, so we have to drive it frame-by-frame.
    private func animate(_ binding: Binding<Double>, duration: Double) async {
        let fps: Double = 60
        let steps = Int(duration * fps)
        for step in 1...steps {
            binding.wrappedValue = Double(step) / Double(steps)
            try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / fps))
        }
        binding.wrappedValue = 1.0
    }

    /// Hit-test a tap point against the spiral geometry to find
    /// which therapy day was tapped, then animate + show detail.
    private func handleSpiralTap(at location: CGPoint, in size: CGSize) {
        guard !days.isEmpty, fillProgress >= 0.98 else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2 - 52
        let innerRadius = max(26, maxRadius * 0.18)
        let bandWidth = (maxRadius - innerRadius) / CGFloat(daysToShow)

        let totalMinutes = daysToShow * 24 * 60
        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(totalMinutes) * 60)
        let windowStartSec = windowStart.timeIntervalSince1970

        // Convert tap to polar from center
        let dx = location.x - center.x
        let dy = location.y - center.y
        let tapR = sqrt(dx * dx + dy * dy)

        // Must be within the spiral band
        guard tapR >= innerRadius - bandWidth && tapR <= maxRadius + bandWidth else { return }

        let cal = Calendar.current
        let startComps = cal.dateComponents([.hour, .minute], from: windowStart)
        let startMinuteOfDay = (startComps.hour ?? 0) * 60 + (startComps.minute ?? 0)

        // Match the rendered stroke width (bandWidth * 0.75 in the canvas),
        // plus a small slack so taps near the edge still register.
        let strokeRadius = bandWidth * 0.75 / 2
        let hitTolerance = strokeRadius + 6

        // Sample the actual arc of each session and take the closest point —
        // not just the midpoint — so taps anywhere on the orange blob hit.
        var bestDay: Int?
        var bestDist: CGFloat = .greatestFiniteMagnitude

        func point(at m: Int) -> CGPoint {
            let minuteOfDay = (startMinuteOfDay + m) % 1440
            let angle = -Double.pi / 2 + 2 * .pi * Double(minuteOfDay) / 1440.0
            let r = innerRadius + CGFloat(Double(m) / Double(totalMinutes)) * (maxRadius - innerRadius)
            return CGPoint(x: center.x + CGFloat(cos(angle)) * r,
                           y: center.y + CGFloat(sin(angle)) * r)
        }

        for (dayIdx, day) in days.enumerated() {
            for session in day.sessions where session.durationMinutes >= 5 {
                let sLo = Int((session.startDate.timeIntervalSince1970 - windowStartSec) / 60)
                let sHi = Int((session.endDate.timeIntervalSince1970 - windowStartSec) / 60)
                let lo = max(0, sLo)
                let hi = min(totalMinutes - 1, sHi)
                guard lo < hi else { continue }

                // Step ~1 pixel along the arc (≈ 1 minute is well under
                // 1pt for any practical band width, so this oversamples
                // safely without being expensive).
                let step = max(1, (hi - lo) / 240)
                var m = lo
                while m <= hi {
                    let p = point(at: m)
                    let d = hypot(location.x - p.x, location.y - p.y)
                    if d < hitTolerance && d < bestDist {
                        bestDist = d
                        bestDay = dayIdx
                    }
                    m += step
                }
            }
        }

        guard let dayIdx = bestDay else {
            // Tapped empty space — deselect
            if selectedDayIndex != nil {
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedExpand = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    selectedDayIndex = nil
                }
            }
            return
        }

        // Select and animate expand, then show detail
        selectedDayIndex = dayIdx
        selectedExpand = 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            selectedExpand = 6
        }
        // Show detail after the expand animation settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showingDetail = true
        }
    }

    private func loadHistory() async {
        isLoading = true; errorMessage = nil
        trackProgress = 0; fillProgress = 0; labelsReady = false

        // 1. Start drawing the awake track inside-out immediately
        let trackTask = Task { await animate($trackProgress, duration: 3.0) }

        // 2. Fetch Summary first (required for the spiral to render at all).
        //    As soon as it returns, the fillProgress animation unblocks
        //    the tap gesture — users can open detail views immediately.
        do {
            let fetched = try await controller.fetchHistory(days: daysToShow)
            days = fetched; isLoading = false
        } catch {
            errorMessage = error.localizedDescription; isLoading = false
        }

        // 3. Fire per-minute download in the background. It takes ~5-15s
        //    over BLE and doesn't affect the spiral's clickability or
        //    rendering. When it completes, `perMinute` updates and any
        //    freshly-opened SessionDetailView gets real classifications;
        //    views opened before completion fall back to the template.
        Task {
            let pm = await controller.fetchPerMinuteHistory(days: daysToShow)
            await MainActor.run { self.perMinute = pm }
        }

        // 3. Wait for track to finish (if data came back faster)
        await trackTask.value

        // 4. Animate therapy fill outside-in
        if !days.isEmpty {
            await animate($fillProgress, duration: 1.5)
            // Force-set in case the animate loop got cancelled and
            // SwiftUI coalesced some of its writes mid-stream.
            fillProgress = 1.0
            trackProgress = 1.0
            labelsReady = true
        }
    }
}

// MARK: - Spiral canvas

private struct SpiralHistoryCanvas: View {
    let days: [DaySummary]
    let daysToShow: Int
    let trackProgress: Double   // 0..1 awake track
    let fillProgress: Double    // 0..1 therapy fill
    let selectedDayIndex: Int?
    let selectedExpand: CGFloat
    /// Once true, the canvas renders labels + average-sleep lines.
    /// Driven by the outer view's `loadHistory` completion, not the
    /// animation progress values — those race with cancellation.
    let labelsReady: Bool

    var body: some View {
        Canvas { context, size in
            draw(into: context, size: size)
        }
    }

    private func draw(into context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Enough margin for labels OUTSIDE the ring
        let maxRadius = min(size.width, size.height) / 2 - 52
        let innerRadius: CGFloat = max(26, maxRadius * 0.18)
        let bandWidth = (maxRadius - innerRadius) / CGFloat(daysToShow)

        let totalMinutes = daysToShow * 24 * 60
        let trackMinutes = min(totalMinutes, Int(Double(totalMinutes) * trackProgress))

        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(totalMinutes) * 60)
        let cal = Calendar.current
        let startComps = cal.dateComponents([.hour, .minute], from: windowStart)
        let startMinuteOfDay = (startComps.hour ?? 0) * 60 + (startComps.minute ?? 0)

        func point(at m: Int) -> CGPoint {
            let minuteOfDay = (startMinuteOfDay + m) % 1440
            let angle = -Double.pi / 2 + 2 * .pi * Double(minuteOfDay) / 1440.0
            let r = innerRadius + CGFloat(Double(m) / Double(totalMinutes)) * (maxRadius - innerRadius)
            return CGPoint(x: center.x + CGFloat(cos(angle)) * r,
                           y: center.y + CGFloat(sin(angle)) * r)
        }

        /// Tangent angle for a label at minute `m`, oriented so the
        /// **top of the letters faces the spiral center** rather than
        /// outward. At the top/bottom of the dial the radial flip would
        /// put the text upside down, so we add π to keep it readable —
        /// horizontal text at 6 o'clock, right-side up.
        func tangent(at m: Int) -> (angle: Double, flipped: Bool) {
            let minuteOfDay = (startMinuteOfDay + m) % 1440
            let θ = -Double.pi / 2 + 2 * .pi * Double(minuteOfDay) / 1440.0
            // Radial-perpendicular minus 90° points letters TOWARD center
            // (was +90° = pointing outward, which gave the inconsistent
            // "some labels face away" appearance).
            var t = θ - .pi / 2
            while t > .pi  { t -= 2 * .pi }
            while t < -.pi { t += 2 * .pi }
            let flipped = abs(t) > .pi / 2
            if flipped { t += .pi }
            while t > .pi  { t -= 2 * .pi }
            while t < -.pi { t += 2 * .pi }
            return (t, flipped)
        }

        func pixelsToMinutes(_ px: CGFloat, atMinute m: Int) -> Int {
            let r = innerRadius + CGFloat(Double(m) / Double(totalMinutes)) * (maxRadius - innerRadius)
            let pxPerMin = max(0.1, r * CGFloat(2 * Double.pi / 1440.0))
            return Int(px / pxPerMin)
        }

        // 0. Average sleep/wake dashed lines — drawn FIRST so they
        //    sit under the spiral track and therapy fill. Gated on the
        //    explicit labelsReady flag from the parent (not the animation
        //    progress values, which can stall below threshold under task
        //    cancellation and leave the spiral rendered without labels).
        if labelsReady && !days.isEmpty {
            drawAverageLines(context: context, center: center,
                             innerRadius: innerRadius, outerRadius: maxRadius)
        }

        // 1. Awake track (driven by trackProgress)
        var trackPath = Path()
        if trackMinutes > 1 {
            trackPath.move(to: point(at: 0))
            for m in 1..<trackMinutes {
                trackPath.addLine(to: point(at: m))
            }
        }
        context.stroke(trackPath,
            with: .color(Color.white.opacity(0.12)),
            style: StrokeStyle(lineWidth: max(1.5, bandWidth * 0.18), lineCap: .round))

        // 2. Therapy fill — draws OUTSIDE-IN (most recent night first,
        //    then older nights reveal as fillProgress advances).
        //    Selected day gets extra thickness for tap feedback.
        if !days.isEmpty && fillProgress > 0 {
            let fillStartMinute = Int(Double(totalMinutes) * (1.0 - fillProgress))
            let windowStartSec0 = windowStart.timeIntervalSince1970
            let normalWidth = bandWidth * 0.75

            for (dayIdx, day) in days.enumerated() {
                let isSelected = dayIdx == selectedDayIndex
                let width = isSelected ? normalWidth + selectedExpand : normalWidth
                let color = isSelected
                    ? Color.orange
                    : Color.orange.opacity(0.88)

                var dayPath = Path()
                // Match the threshold used by label code + tap hit-test
                // (both gate on >= 5 min). Without this, a day with
                // only a mask-fit blip would draw an orange dot on the
                // spiral that nothing else in the UI acknowledges.
                for session in day.sessions where session.durationMinutes >= 5 {
                    let sLo = Int((session.startDate.timeIntervalSince1970 - windowStartSec0) / 60)
                    let sHi = Int((session.endDate.timeIntervalSince1970 - windowStartSec0) / 60)
                    let lo = max(fillStartMinute, max(0, sLo))
                    let hi = min(totalMinutes - 1, sHi)
                    guard lo < hi else { continue }
                    dayPath.move(to: point(at: lo))
                    for m in (lo + 1)...hi { dayPath.addLine(to: point(at: m)) }
                }
                context.stroke(dayPath, with: .color(color),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }

        // 3. Labels (only after both animations done)

        if labelsReady {
            let windowStartSec = windowStart.timeIntervalSince1970
            let minSessionMin = 5
            let gap: CGFloat = bandWidth * 0.6   // big enough to clear the orange fill

            // Per-day duration labels
            for day in days {
                let real = day.sessions.filter { $0.durationMinutes >= minSessionMin }
                guard let last = real.last else { continue }
                let totalMin = real.map { $0.durationMinutes }.reduce(0, +)
                guard totalMin > 0 else { continue }

                let lastEndMin = Int((last.endDate.timeIntervalSince1970 - windowStartSec) / 60.0)
                if lastEndMin > 0 && lastEndMin < totalMinutes {
                    let hours = totalMin / 60, mins = totalMin % 60
                    let durStr = hours == 0 ? "\(mins)m" : "\(hours)h \(mins)m"
                    let label = Text(durStr)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                    let resolved = context.resolve(label)
                    let textW = resolved.measure(in: CGSize(width: 300, height: 40)).width
                    let offsetMin = pixelsToMinutes(textW / 2 + gap, atMinute: lastEndMin)
                    let centerMin = min(totalMinutes - 1, lastEndMin + offsetMin)
                    let centerPt = point(at: centerMin)
                    // Tangentially rotated: labels follow the spiral arc
                    // so adjacent nights with similar end-times don't
                    // stack on top of each other (they spread radially
                    // along their own arcs). The 180° hemisphere flip
                    // is the unavoidable cost of going around a circle —
                    // we accept it to keep text upright everywhere.
                    let (tan, _) = tangent(at: centerMin)
                    context.drawLayer { layer in
                        layer.translateBy(x: centerPt.x, y: centerPt.y)
                        layer.rotate(by: .radians(tan))
                        layer.draw(resolved, at: .zero)
                    }
                }
            }

            // Start/end date labels
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "EEE d"; dayFmt.timeZone = .current

            // Oldest day → center of spiral
            if let firstDay = days.first,
               let firstSess = firstDay.sessions.filter({ $0.durationMinutes >= 5 }).first {
                let label = Text(dayFmt.string(from: firstSess.startDate))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                context.draw(label, at: center)
            }

            // Newest day → AFTER the very end of the awake spiral.
            // We place it further along the spiral path (beyond
            // totalMinutes) so the track "points at" the label.
            if let lastDay = days.last,
               let lastSess = lastDay.sessions.filter({ $0.durationMinutes >= 5 }).last {
                let label = Text(dayFmt.string(from: lastSess.startDate))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                let resolved = context.resolve(label)
                let textW = resolved.measure(in: CGSize(width: 300, height: 40)).width
                // Compute a point PAST the spiral end by extrapolating
                // the angle and radius beyond totalMinutes. Reserve room
                // for the most recent day's duration label too — its
                // text sits just inside the spiral end, and at 80-100 px
                // wide it was colliding with the date label.
                let durationLabelGap: CGFloat = 100
                let extraMinutes = pixelsToMinutes(
                    textW / 2 + durationLabelGap + 24,
                    atMinute: totalMinutes - 1
                )
                let beyondMin = totalMinutes - 1 + extraMinutes
                let beyondPt = point(at: beyondMin)
                // Horizontal — same reasoning as the per-day duration
                // labels above.
                context.draw(resolved, at: beyondPt)
            }
        }

        // 4. Hour labels OUTSIDE the outer ring
        drawHourLabels(context: context, center: center, radius: maxRadius + 18)
    }

    // MARK: - Average bedtime / wake lines

    private func drawAverageLines(context: GraphicsContext, center: CGPoint,
                                  innerRadius: CGFloat, outerRadius: CGFloat) {
        let cal = Calendar.current
        let minSession = 5
        var bedMins: [Int] = [], wakeMins: [Int] = []
        for day in days {
            let real = day.sessions.filter { $0.durationMinutes >= minSession }
            guard let first = real.first, let last = real.last else { continue }
            let bc = cal.dateComponents([.hour, .minute], from: first.startDate)
            let wc = cal.dateComponents([.hour, .minute], from: last.endDate)
            bedMins.append((bc.hour ?? 0) * 60 + (bc.minute ?? 0))
            wakeMins.append((wc.hour ?? 0) * 60 + (wc.minute ?? 0))
        }
        guard !bedMins.isEmpty else { return }

        func circularMean(_ v: [Int]) -> Int {
            var sx = 0.0, sy = 0.0
            for m in v { let a = 2 * .pi * Double(m) / 1440; sx += cos(a); sy += sin(a) }
            var m = atan2(sy / Double(v.count), sx / Double(v.count))
            if m < 0 { m += 2 * .pi }
            return Int(m / (2 * .pi) * 1440) % 1440
        }

        let avgBed = circularMean(bedMins), avgWake = circularMean(wakeMins)
        let lineExt: CGFloat = 14
        // Labels OUTSIDE the outer ring, past the dashed line end
        let labelRadius = outerRadius + lineExt + 18

        func drawLine(minuteOfDay: Int, color: Color, prefix: String) {
            let angle = -Double.pi / 2 + 2 * .pi * Double(minuteOfDay) / 1440.0
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))

            // Start lines a bit away from center so they don't
            // overlap the start-date label sitting at center
            let lineStart: CGFloat = innerRadius * 0.6
            var path = Path()
            path.move(to: CGPoint(x: center.x + cosA * lineStart,
                                  y: center.y + sinA * lineStart))
            path.addLine(to: CGPoint(x: center.x + cosA * (outerRadius + lineExt),
                                     y: center.y + sinA * (outerRadius + lineExt)))
            context.stroke(path, with: .color(color.opacity(0.6)),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            let h = minuteOfDay / 60, m = minuteOfDay % 60
            let tf = DateFormatter(); tf.dateFormat = "h:mm a"; tf.timeZone = .current
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comps.hour = h; comps.minute = m
            let fd = Calendar.current.date(from: comps) ?? Date()
            let tz = TimeZone.current.abbreviation() ?? "UTC"
            let label = Text("\(prefix) \(tf.string(from: fd)) \(tz)")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(color.opacity(0.9))

            var textAngle = angle + .pi / 2
            while textAngle > .pi  { textAngle -= 2 * .pi }
            while textAngle < -.pi { textAngle += 2 * .pi }
            if abs(textAngle) > .pi / 2 { textAngle += .pi }
            while textAngle > .pi  { textAngle -= 2 * .pi }
            while textAngle < -.pi { textAngle += 2 * .pi }

            let pt = CGPoint(x: center.x + cosA * labelRadius,
                             y: center.y + sinA * labelRadius)
            context.drawLayer { layer in
                layer.translateBy(x: pt.x, y: pt.y)
                layer.rotate(by: .radians(textAngle))
                layer.draw(label, at: .zero)
            }
        }

        drawLine(minuteOfDay: avgBed,  color: .green, prefix: "Average Start of Sleep")
        drawLine(minuteOfDay: avgWake, color: .red,   prefix: "Average End of Sleep")
    }

    // MARK: - Hour labels

    private func drawHourLabels(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let labels: [(text: String, angle: Double)] = [
            ("00", -Double.pi / 2), ("06", 0),
            ("12", Double.pi / 2),  ("18", Double.pi),
        ]
        for l in labels {
            let x = center.x + CGFloat(cos(l.angle)) * radius
            let y = center.y + CGFloat(sin(l.angle)) * radius
            context.draw(
                Text(l.text).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: y))
        }
    }

    // MARK: - Session ranges

    private func sessionMinuteRanges(windowStart: Date, totalMinutes: Int) -> [ClosedRange<Int>] {
        let ws = windowStart.timeIntervalSince1970
        var ranges: [ClosedRange<Int>] = []
        for day in days {
            for s in day.sessions where s.durationMinutes > 0 {
                let lo = max(0, Int((s.startDate.timeIntervalSince1970 - ws) / 60))
                let hi = min(totalMinutes - 1, Int((s.endDate.timeIntervalSince1970 - ws) / 60))
                if lo <= hi { ranges.append(lo...hi) }
            }
        }
        return ranges
    }
}
