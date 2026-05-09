//
//  SessionDetailView.swift
//  OpenRM
//
//  Detail view shown when tapping a therapy day on the sleep spiral.
//

import SwiftUI

struct SessionDetailView: View {
    let day: DaySummary
    /// All per-minute sessions downloaded alongside the Summary. We pick
    /// out the ones belonging to this day by matching start times with a
    /// ±2 minute tolerance (see `perMinuteSession(for:)`).
    let perMinute: [PerMinuteSession]
    @Environment(\.dismiss) private var dismiss

    /// Default initializer keeps callers that haven't been updated yet
    /// (e.g. previews) working — they just won't get per-minute staging.
    init(day: DaySummary, perMinute: [PerMinuteSession] = []) {
        self.day = day
        self.perMinute = perMinute
    }

    /// Find the per-minute session that matches a given Summary session
    /// within ±2 minutes. Returns `nil` if no per-minute data is available
    /// for this session — the timeline then falls back to template-based
    /// staging. The 2-min tolerance accommodates both the CPAP's minor
    /// clock drift and the known Summary-vs-TherapyOneMinute start-time
    /// offset (Summary uses "first stable breath after ramp", the per-minute
    /// spool uses "ramp start" — usually 0.5-1.0 minutes apart).
    func perMinuteSession(for sess: DaySummary.Session) -> PerMinuteSession? {
        perMinute.first(where: {
            abs($0.startDate.timeIntervalSince(sess.startDate)) < 120
        })
    }

    /// Which session pill is selected (scrolls timeline to that session).
    @State private var selectedSessionIndex: Int?

    /// Namespace for scroll-to-session anchors in the timeline.
    @Namespace private var timelineNamespace

    /// Cached timeline blocks. Building them runs the BLE3ClassClassifier
    /// over every minute of the night (~95k tree-node walks per minute).
    /// Without this cache, SwiftUI re-evaluates `body` on every scroll
    /// tick and re-runs the whole inference, making the sheet unusable.
    @State private var cachedBlocks: [TimelineStageBlock] = []

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d yyyy"
        f.timeZone = .current
        return f
    }()

    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a zzz"
        f.timeZone = .current
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            // Header + session-pill row stay pinned at the top of
            // the sheet — they're the user's "where am I" orientation
            // and shouldn't scroll away when the user is mid-way down
            // looking at the pressure/respiratory/mask seal blocks.
            VStack(alignment: .leading, spacing: 20) {
                header
                if realSessions.count > 1 {
                    sessionPills(proxy: proxy)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ahiSection
                        Divider()
                        pressureSection
                        Divider()
                        respiratorySection
                        Divider()
                        maskSealSection
                        if !realSessions.isEmpty {
                            Divider()
                            timelineSection
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 420, minHeight: 500)
        .preferredColorScheme(.dark)
        // Allow the sheet to fill the screen so the timeline (the
        // tallest section, rendered last) isn't hidden below the
        // default medium detent on iPad.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Key the rebuild on (day, perMinute-loaded-count). Without the
        // second component, the common "user taps a day while the BLE
        // per-minute fetch is still in flight" race causes the first
        // view to render using template fallback, and a later arrival
        // of perMinute never retriggers the classifier so the
        // template-derived chart sticks until the user dismisses and
        // re-taps. Including perMinute.count in the id forces a
        // rebuild the moment new data lands.
        .task(id: TimelineBuildKey(dayStart: day.startDate, perMinuteCount: perMinute.count)) {
            // Run the heavy ML classification once when the sheet opens
            // (or when the underlying day changes, or when per-minute
            // telemetry finishes loading). Per-minute + HealthKit HR
            // fetch + Core ML inference + Viterbi is far too expensive
            // to run on every SwiftUI body eval.
            cachedBlocks = await buildTimelineBlocks()
        }
    }

    private var realSessions: [DaySummary.Session] {
        day.sessions.filter { $0.durationMinutes >= 5 }
    }

    private var totalMinutes: Int {
        realSessions.map(\.durationMinutes).reduce(0, +)
    }

    /// Total minutes the user was actually asleep during the night —
    /// sum of all non-Awake block minutes in the cached classifier
    /// output. Zero until `cachedBlocks` has been populated by the
    /// `.task` on first appearance.
    private var totalAsleepMinutes: Int {
        cachedBlocks
            .filter { $0.stage != .awake }
            .map(\.minutes)
            .reduce(0, +)
    }

    /// 4-class stage distribution for this night, derived from the
    /// cached classifier output (`cachedBlocks`) when available, or
    /// the percentile-based summary estimate otherwise. Reading the
    /// cache avoids re-running the model on every view re-evaluation.
    private var stageDistribution: [SleepStage: Double] {
        let blocks = cachedBlocks
        if !blocks.isEmpty, totalMinutes > 0 {
            var accum: [SleepStage: Int] = [:]
            for b in blocks { accum[b.stage, default: 0] += b.minutes }
            let total = Double(blocks.map(\.minutes).reduce(0, +))
            guard total > 0 else { return summaryDistribution }
            var dict: [SleepStage: Double] = [:]
            for stage in SleepStage.allCases {
                dict[stage] = Double(accum[stage] ?? 0) / total
            }
            return dict
        }
        return summaryDistribution
    }

    /// Fallback distribution from daily percentiles. Used when per-
    /// minute data isn't available (session predates the CPAP cache
    /// window, BLE fetch failed, or the trained model isn't loaded).
    private var summaryDistribution: [SleepStage: Double] {
        let rrP50 = day.respiratoryRate?.p50 ?? 16.0
        let rrP95 = day.respiratoryRate?.p95 ?? 17.0
        let mpP50 = day.maskPressure?.p50 ?? 6.5
        let mpMax = day.maskPressure?.max ?? 8.0
        return SleepStageDetector.estimateDistribution(
            respRateP50: rrP50,
            respRateP95: rrP95,
            maskPressP50: mpP50,
            maskPressMax: mpMax
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let first = realSessions.first {
                    Text(dateFmt.string(from: first.startDate))
                        .font(.title2)
                        .fontWeight(.bold)
                }
                Text(fmtDuration(totalMinutes) + " total therapy")
                    .font(.title3)
                    .foregroundStyle(.orange)
                // Time asleep = sum of non-awake classified minutes
                // from the cached block list. Empty (cachedBlocks = [])
                // before classification runs, so we show a "—" dash
                // until numbers are in.
                if !cachedBlocks.isEmpty {
                    Text(fmtDuration(totalAsleepMinutes) + " time asleep")
                        .font(.title3)
                        .foregroundStyle(.blue)
                } else {
                    Text("— time asleep")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Text("\(realSessions.count) session\(realSessions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    /// Horizontal row of tappable session pills. Each pill shows the
    /// session number and duration; tapping scrolls the timeline to
    /// that session's anchor.
    private func sessionPills(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(realSessions.enumerated()), id: \.offset) { i, sess in
                    let isSelected = selectedSessionIndex == i
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            selectedSessionIndex = i
                            proxy.scrollTo("session-\(i)", anchor: .top)
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text("#\(i + 1)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                            Text(fmtDuration(sess.durationMinutes))
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.orange : Color.white.opacity(0.08))
                        )
                        .foregroundStyle(isSelected ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var ahiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EVENTS").font(.caption).foregroundStyle(.secondary).tracking(1.5)

            // Combined AHI
            eventRow(
                name: "Apnea-Hypopnea Index",
                description: "Total apneas + hypopneas per hour. Under 5 is normal, 5-15 mild, 15-30 moderate, over 30 severe.",
                value: day.ahi,
                color: ahiColor(day.ahi)
            )

            eventRow(
                name: "Obstructive Apneas",
                description: "Airway physically blocked by relaxed throat tissue. Breathing stops for 10+ seconds.",
                value: day.oai
            )
            eventRow(
                name: "Central Apneas",
                description: "Brain temporarily stops sending the signal to breathe. Airway is open but no effort is made.",
                value: day.cai
            )
            eventRow(
                name: "Hypopneas",
                description: "Partial airway obstruction -- airflow drops by 30%+ for 10+ seconds with oxygen desaturation.",
                value: day.hi
            )
            eventRow(
                name: "Unclassified Apneas",
                description: "Breathing pauses that don't clearly fit obstructive or central patterns.",
                value: day.uai
            )
            eventRow(
                name: "Respiratory Effort-Related Arousals",
                description: "Increased breathing effort that disrupts sleep but doesn't meet apnea/hypopnea criteria.",
                value: day.rin
            )
        }
    }

    private var pressureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRESSURE").font(.caption).foregroundStyle(.secondary).tracking(1.5)
            percentileHeader()
            if let mp = day.maskPressure {
                percentileRow("Mask Press", p: mp, unit: "cmH\u{2082}O")
            }
            if let ip = day.targetIPAP {
                percentileRow("Target IPAP", p: ip, unit: "cmH\u{2082}O")
            }
            if let ep = day.targetEPAP {
                percentileRow("Target EPAP", p: ep, unit: "cmH\u{2082}O")
            }
        }
    }

    private var respiratorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RESPIRATORY").font(.caption).foregroundStyle(.secondary).tracking(1.5)
            percentileHeader()
            if let rr = day.respiratoryRate {
                percentileRow("Resp Rate", p: rr, unit: "br/min")
            }
            if let mv = day.minuteVentilation {
                percentileRow("Min Vent", p: mv, unit: "L/min")
            }
            if let tv = day.tidalVolume {
                percentileRow("Tidal Vol", p: tv, unit: "L")
            }
        }
    }

    private var maskSealSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MASK SEAL").font(.caption).foregroundStyle(.secondary).tracking(1.5)
            if let lk = day.leak {
                let (rating, ratingColor) = maskSealRating(p95Ls: lk.p95)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Mask Seal")
                            .font(.headline)
                        Text(rating)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(ratingColor)
                        Spacer()
                    }
                    // Header row — same column widths as the leak row
                    // below so p50 / p70 / p95 / max labels align.
                    HStack {
                        Text("").frame(width: Self.percentileLabelColumnW, alignment: .leading)
                        Text("p50").frame(width: Self.percentileValueColumnW, alignment: .trailing)
                        Text("p70").frame(width: Self.percentileValueColumnW, alignment: .trailing)
                        Text("p95").frame(width: Self.percentileValueColumnW, alignment: .trailing)
                        Text("max").frame(width: Self.percentileValueColumnW, alignment: .trailing)
                        Text("").foregroundStyle(.secondary)
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                    HStack {
                        Text("Leak").frame(width: Self.percentileLabelColumnW, alignment: .leading)
                        Text(String(format: "%.2f", lk.p50))
                            .frame(width: Self.percentileValueColumnW, alignment: .trailing)
                            .foregroundStyle(leakColor(lk.p50))
                        Text(String(format: "%.2f", lk.p70))
                            .frame(width: Self.percentileValueColumnW, alignment: .trailing)
                            .foregroundStyle(leakColor(lk.p70))
                        Text(String(format: "%.2f", lk.p95))
                            .frame(width: Self.percentileValueColumnW, alignment: .trailing)
                            .foregroundStyle(leakColor(lk.p95))
                        Text(String(format: "%.2f", lk.max))
                            .frame(width: Self.percentileValueColumnW, alignment: .trailing)
                            .foregroundStyle(leakColor(lk.max))
                        Text("L/s").foregroundStyle(.secondary)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Timeline

    /// Vertical step-chart timeline. Time runs top → bottom; sleep stages
    /// occupy three lanes (Awake / NREM / REM). Each contiguous stage
    /// block is a rounded vertical bar in its lane; consecutive blocks
    /// are connected by a thin gradient segment so transitions read as
    /// a step function (the "swim-lane" / Samsung-Health style, rotated
    /// 90° so the longer time axis fits the sheet).
    private var timelineSection: some View {
        let blocks = cachedBlocks
        let totalMins = max(1, blocks.map(\.minutes).reduce(0, +))
        // ~1.4 pt/minute keeps an 8-hour night around 670 pt — readable
        // without overflowing the sheet, and clamps a short nap to 360 pt.
        let height = max(360, CGFloat(totalMins) * 1.4)
        return VStack(alignment: .leading, spacing: 8) {
            Text("TIMELINE").font(.caption).foregroundStyle(.secondary).tracking(1.5)
            stageLegend
            stagesVerticalChart(blocks: blocks)
                .frame(height: height)
        }
    }

    /// The Canvas-backed step chart used by `timelineSection`.
    private func stagesVerticalChart(blocks: [TimelineStageBlock]) -> some View {
        let totalMins = max(1, blocks.map(\.minutes).reduce(0, +))
        // Chart is adaptive: if no block is Deep (either because the
        // model genuinely saw no Deep or because HR coverage was too
        // low and the runtime collapsed Deep → Light), drop the Deep
        // lane. Matches the product rule — show 4 stages only when we
        // trust all 4; show 3 stages (Awake / NREM / REM) otherwise.
        let presentStages = Set(blocks.map(\.stage))
        let threeClass = !presentStages.contains(.deep)
        let lanes: [SleepStage] = threeClass
            ? [.awake, .light, .rem]
            : [.awake, .light, .deep, .rem]
        let firstStart = blocks.first?.startDate ?? Date()
        return Canvas { ctx, size in
            // Wide enough for "10:00 PM PDT" (~78 pt at the 10 pt rounded
            // font we use). Was 56, which clipped the leading hour digit.
            let timeColW: CGFloat = 84
            let headerH: CGFloat = 22
            let chartX = timeColW + 12
            let chartTop = headerH + 4
            let chartH = size.height - chartTop - 8
            let chartW = size.width - chartX - 8
            guard chartW > 60, chartH > 40 else { return }

            let laneW = chartW / CGFloat(lanes.count)
            let barW = min(laneW * 0.6, 28)

            func laneCenter(_ stage: SleepStage) -> CGFloat {
                let i = lanes.firstIndex(of: stage) ?? 0
                return chartX + laneW * CGFloat(i) + laneW / 2
            }
            func y(forMinute m: Int) -> CGFloat {
                chartTop + CGFloat(m) / CGFloat(totalMins) * chartH
            }

            // Lane headers. In 3-class mode Light is relabeled NREM —
            // we can't distinguish Light from Deep without HR, so the
            // honest label is the superset category, not "Light".
            for stage in lanes {
                let name = (threeClass && stage == .light)
                    ? "NREM" : stage.rawValue
                let label = ctx.resolve(Text(name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(stage.color.opacity(0.9)))
                let lw = label.measure(in: CGSize(width: laneW, height: 16)).width
                ctx.draw(label, at: CGPoint(x: laneCenter(stage) - lw / 2 + lw / 2, y: 8))
            }

            // Faint lane backgrounds so the chart structure reads at a glance
            for stage in lanes {
                let cx = laneCenter(stage)
                let bg = CGRect(x: cx - laneW / 2 + 4, y: chartTop,
                                width: laneW - 8, height: chartH)
                ctx.fill(Path(roundedRect: bg, cornerRadius: 4),
                         with: .color(stage.color.opacity(0.04)))
            }

            // Hour-grid + time labels along the left axis
            let cal = Calendar.current
            let firstHour = cal.date(bySetting: .minute, value: 0, of: firstStart) ?? firstStart
            var hourCursor = firstHour
            while hourCursor <= firstStart.addingTimeInterval(Double(totalMins) * 60) {
                let offsetMin = Int(hourCursor.timeIntervalSince(firstStart) / 60)
                if offsetMin >= 0 && offsetMin <= totalMins {
                    let yy = y(forMinute: offsetMin)
                    var grid = Path()
                    grid.move(to: CGPoint(x: chartX, y: yy))
                    grid.addLine(to: CGPoint(x: chartX + chartW, y: yy))
                    ctx.stroke(grid, with: .color(.white.opacity(0.06)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    let label = ctx.resolve(Text(timeFmt.string(from: hourCursor))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.secondary))
                    let lw = label.measure(in: CGSize(width: timeColW, height: 14)).width
                    ctx.draw(label, at: CGPoint(x: timeColW - lw / 2, y: yy))
                }
                hourCursor = hourCursor.addingTimeInterval(3600)
            }

            // Per-corner rounded bars + thin 1pt connectors.
            //
            // Geometry:
            //   - A bar's corner is SQUARE only where the connector
            //     physically attaches to it. Every other corner keeps
            //     the rounded cap.
            //   - The connector is a 1pt-tall filled rect spanning
            //     the horizontal gap between the two bars' inner
            //     edges — visible only in that gap, since bars are
            //     drawn on top and cover the connector within their
            //     own horizontal range.
            //   - On the side where a connector attaches, the bar is
            //     EXTENDED by connectorThickness/2 into the line's y
            //     range (rather than shrunk away from it). Effect:
            //     the bar's last row occupies exactly the same pixel
            //     row(s) as the connector, so the bar's edge and the
            //     connector's edge are on the same horizontal row —
            //     no sub-pixel gap between them at the join.
            let connectorThickness: CGFloat = 1
            let barWHalf = barW / 2

            // Pass 1 — connectors (drawn first, under the bars).
            var prevCenterX: CGFloat?
            var prevStage: SleepStage?
            var minuteCursor = 0
            for block in blocks {
                let yJoin = y(forMinute: minuteCursor)
                let cx = laneCenter(block.stage)
                if let pcx = prevCenterX, let ps = prevStage, ps != block.stage {
                    let top = yJoin - connectorThickness / 2
                    let left = min(pcx, cx) + barWHalf
                    let right = max(pcx, cx) - barWHalf
                    if right > left {
                        let rect = CGRect(x: left, y: top,
                                          width: right - left,
                                          height: connectorThickness)
                        let psOp:  Double = ps == .awake          ? 0.95 : 0.85
                        let curOp: Double = block.stage == .awake ? 0.95 : 0.85
                        // Alpha tapers to 10% at the midpoint so the
                        // connector reads as a subtle tether rather
                        // than a solid bar — both endpoints stay at
                        // full stage-color visibility. Color transition
                        // happens during the low-alpha midpoint so
                        // there's no visible prev → curr color seam.
                        let stops: [Gradient.Stop] = [
                            .init(color: ps.color.opacity(psOp),           location: 0.00),
                            .init(color: ps.color.opacity(0.10),           location: 0.45),
                            .init(color: block.stage.color.opacity(0.10),  location: 0.55),
                            .init(color: block.stage.color.opacity(curOp), location: 1.00),
                        ]
                        let startX = pcx < cx ? left  : right
                        let endX   = pcx < cx ? right : left
                        ctx.fill(
                            Path(rect),
                            with: .linearGradient(
                                Gradient(stops: stops),
                                startPoint: CGPoint(x: startX, y: top),
                                endPoint:   CGPoint(x: endX,   y: top)
                            )
                        )
                    }
                }
                prevCenterX = cx
                prevStage = block.stage
                minuteCursor += block.minutes
            }

            // Pass 2 — bars (drawn on top of connectors). The extend
            // logic puts the bar's end row on the same pixel row as
            // the connector, so the two meet flush rather than on
            // adjacent rows with a sub-pixel seam.
            minuteCursor = 0
            for (i, block) in blocks.enumerated() {
                let yStart = y(forMinute: minuteCursor)
                let yEnd = y(forMinute: minuteCursor + block.minutes)
                let cx = laneCenter(block.stage)

                var corners = Corners.allRounded
                var topExtend: CGFloat = 0
                var bottomExtend: CGFloat = 0

                if i > 0 {
                    let pcx = laneCenter(blocks[i - 1].stage)
                    if pcx == cx {
                        corners.topLeft = false
                        corners.topRight = false
                    } else if pcx < cx {
                        corners.topLeft = false
                        topExtend = connectorThickness / 2
                    } else {
                        corners.topRight = false
                        topExtend = connectorThickness / 2
                    }
                }
                if i < blocks.count - 1 {
                    let ncx = laneCenter(blocks[i + 1].stage)
                    if ncx == cx {
                        corners.bottomLeft = false
                        corners.bottomRight = false
                    } else if ncx < cx {
                        corners.bottomLeft = false
                        bottomExtend = connectorThickness / 2
                    } else {
                        corners.bottomRight = false
                        bottomExtend = connectorThickness / 2
                    }
                }

                let barTop = yStart - topExtend
                let barBottom = yEnd + bottomExtend
                let rect = CGRect(x: cx - barWHalf,
                                  y: barTop,
                                  width: barW,
                                  height: max(1, barBottom - barTop))
                let path = barPath(rect: rect,
                                   corners: corners,
                                   radius: barWHalf)
                ctx.fill(path,
                         with: .color(block.stage.color.opacity(block.stage == .awake ? 0.95 : 0.85)))
                minuteCursor += block.minutes
            }
        }
    }

    private var stageLegend: some View {
        let dist = stageDistribution
        // Mirror the chart: hide the Deep swatch when HR coverage was
        // too low to produce reliable Deep blocks. In 3-class mode the
        // Light swatch is relabeled NREM for consistency with the
        // chart header — we can't distinguish Light from Deep from
        // respiratory + coverage signals alone, so "NREM" is the
        // honest label.
        let hasDeep = cachedBlocks.contains { $0.stage == .deep }
        let laneOrder: [SleepStage] = hasDeep
            ? [.awake, .light, .deep, .rem]
            : [.awake, .light, .rem]
        return HStack(spacing: 14) {
            ForEach(laneOrder, id: \.self) { stage in
                let mins = Int((dist[stage] ?? 0) * Double(totalMinutes))
                let name = (!hasDeep && stage == .light) ? "NREM" : stage.rawValue
                HStack(spacing: 4) {
                    Circle().fill(stage.color).frame(width: 8, height: 8)
                    Text("\(name) \(fmtDuration(mins))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Timeline entries

    /// One stage block on the timeline. Events that fall inside its time
    /// window are attached as `events` and rendered as sub-labels underneath
    /// the stage label — the stage's colored bar still runs uninterrupted
    /// alongside them.
    private struct TimelineStageBlock {
        let stage: SleepStage
        let minutes: Int
        let startDate: Date
        let endDate: Date
        let stageLabel: String    // "10:30 PM – 11:45 PM  Light (75m)"
        var events: [TimelineEventLabel]
    }

    private struct TimelineEventLabel {
        let label: String
        let color: Color
    }

    /// Equatable key for `.task(id:)`. Combines the day identity with
    /// the per-minute-data arrival signal so the task re-fires when
    /// perMinute transitions from empty to loaded.
    private struct TimelineBuildKey: Equatable {
        let dayStart: Date
        let perMinuteCount: Int
    }

    /// One discrete event to overlay on the timeline. Per-event timing is
    /// approximate — the Summary spool gives us per-day counts only, so
    /// we distribute instances of each type evenly across the session.
    private struct TimelineEvent {
        let time: Date
        let label: String
        let color: Color
    }

    /// Build the per-session stage blocks with attached events.
    private func buildTimelineBlocks() async -> [TimelineStageBlock] {
        var blocks: [TimelineStageBlock] = []
        let dist = stageDistribution

        for (i, sess) in realSessions.enumerated() {
            let dur = sess.durationMinutes
            guard dur > 0 else { continue }

            // --- 1. Build stage blocks for this session. Prefer real
            //        per-minute classifications from BLE telemetry when
            //        available; fall back to a 90-min-cycle template when
            //        per-minute data hasn't loaded (or this session
            //        predates the CPAP's on-device cache window).
            var sessBlocks: [TimelineStageBlock] =
                await buildBlocksFromPerMinute(sess: sess)
                ?? buildBlocksFromTemplate(sess: sess, dist: dist)

            // --- 2. Breathing events intentionally NOT on the timeline.
            // The only acceptable source is ResMed's own event labels
            // (OAI/CAI/H/RE with real timestamps and flow-shape-based
            // type classification). Those live in SD-card EVE.edf and
            // in the TherapyEvents spool, which errors out over BLE
            // (-32602 Invalid Params — RPC shape still unconfirmed).
            //
            // Synthesizing positions from Summary per-day counts and
            // heuristic MinVent-drop detection both produce a false
            // sense of precision, so we emit no events here until
            // official timestamps are accessible. Event counts are
            // already shown in the EVENTS section at the top of this
            // view for context.
            var sessEvents: [TimelineEvent] = []

            // Mask seal warning — only surfaced on the first session and
            // only if seal is below "Great". Placed at session start.
            if i == 0, let lk = day.leak {
                let (rating, ratingColor) = maskSealRating(p95Ls: lk.p95)
                if rating != "Great" {
                    let label = "Mask seal: \(rating) (leak p95: \(String(format: "%.0f", lk.p95 * 60)) L/min)"
                    sessEvents.append(TimelineEvent(
                        time: sess.startDate, label: label, color: ratingColor
                    ))
                }
            }
            sessEvents.sort { $0.time < $1.time }

            // --- 3. Attach each event to the stage block that contains
            // its start time, so the colored bar stays unbroken.
            for event in sessEvents {
                let idx = sessBlocks.firstIndex(where: {
                    event.time >= $0.startDate && event.time < $0.endDate
                }) ?? (sessBlocks.isEmpty ? nil : sessBlocks.count - 1)
                guard let idx else { continue }
                sessBlocks[idx].events.append(TimelineEventLabel(
                    label: event.label, color: event.color
                ))
            }

            // --- 4. Session start/end markers live inside the first and
            // last block (green for start, muted red for end).
            if !sessBlocks.isEmpty {
                let startLabel = "Session #\(i + 1) starts — \(timeFmt.string(from: sess.startDate))"
                sessBlocks[0].events.insert(
                    TimelineEventLabel(label: startLabel, color: .green), at: 0
                )
                let endLabel = "Session #\(i + 1) ends — \(timeFmt.string(from: sess.endDate)) (\(fmtDuration(dur)) total)"
                sessBlocks[sessBlocks.count - 1].events.append(
                    TimelineEventLabel(label: endLabel, color: .red.opacity(0.8))
                )
            }

            blocks.append(contentsOf: sessBlocks)

            // --- 5. Inter-session gap as an Awake block (same visual
            // treatment as other stages, keeps the bar flowing).
            if i < realSessions.count - 1 {
                let next = realSessions[i + 1]
                let gapMin = Int(next.startDate.timeIntervalSince(sess.endDate) / 60)
                if gapMin > 0 {
                    let label = "\(timeFmt.string(from: sess.endDate)) – \(timeFmt.string(from: next.startDate))  Awake (\(gapMin)m)"
                    blocks.append(TimelineStageBlock(
                        stage: .awake, minutes: gapMin,
                        startDate: sess.endDate, endDate: next.startDate,
                        stageLabel: label, events: []
                    ))
                }
            }
        }

        // Merge adjacent same-stage blocks. Three independent sources
        // can produce consecutive same-stage blocks in the raw list:
        //   (1) end of session N labeled Awake by the settle-in pass,
        //   (2) the inter-session gap Awake block,
        //   (3) start of session N+1 labeled Awake by settle-in.
        // Without merging, those render as three distinct pill-shaped
        // bars with 1pt gaps between them — the "round bubble plus a
        // box" visual user reported. Merging produces one continuous
        // bar spanning the full Awake duration.
        var merged: [TimelineStageBlock] = []
        merged.reserveCapacity(blocks.count)
        for b in blocks {
            if var last = merged.last, last.stage == b.stage {
                let mergedLabel = "\(timeFmt.string(from: last.startDate)) – \(timeFmt.string(from: b.endDate))  \(b.stage.rawValue) (\(last.minutes + b.minutes)m)"
                last = TimelineStageBlock(
                    stage: last.stage,
                    minutes: last.minutes + b.minutes,
                    startDate: last.startDate,
                    endDate: b.endDate,
                    stageLabel: mergedLabel,
                    events: last.events + b.events
                )
                merged[merged.count - 1] = last
            } else {
                merged.append(b)
            }
        }
        return merged
    }

    // MARK: - Stage-block builders

    /// Build stage blocks by running the trained 4-class TCN over the
    /// per-minute BLE telemetry and (when HealthKit is authorized) the
    /// heart-rate stream covering the same window. Returns `nil` if no
    /// per-minute data is available or if the model isn't loaded — the
    /// caller then falls back to the 4-class template.
    private func buildBlocksFromPerMinute(sess: DaySummary.Session) async -> [TimelineStageBlock]? {
        guard let pm = perMinuteSession(for: sess) else { return nil }
        guard let detector = SleepStageDetectorV2.shared else { return nil }

        let nMinutes = pm.channel(
            field: PerMinuteChannel.Kind.respRate.rawValue
        )?.values.count ?? 0
        guard nMinutes > 0 else { return nil }
        let endDate = pm.startDate.addingTimeInterval(Double(nMinutes) * 60)

        // HR fetch is opportunistic — empty dict is fine, the model
        // just sees hk_available=0 for every minute and falls back to
        // its CPAP-only regime.
        let hrByMinute = await HealthKitSync.fetchHeartRatePerMinute(
            from: pm.startDate, to: endDate
        )

        let rawStages = detector.predict(perMinute: pm, heartRate: hrByMinute)
        guard !rawStages.isEmpty else { return nil }

        // Mask-off-during-sleep override: where the Apple Watch (or
        // any non-OpenRM HealthKit writer) said the user was asleep,
        // overrule our Awake calls. Keeps the in-app chart consistent
        // with what HealthKit writes for the same night.
        let externalStages = await HealthKitSync.fetchExternalSleepStagesPerMinute(
            from: pm.startDate, to: endDate
        )
        let inputs = SleepStageDetectorV2.buildMinuteInputs(
            perMinute: pm, heartRate: hrByMinute
        )
        let stages = SleepStageDetectorV2.overrideWakeWithExternalSleep(
            stages: rawStages, minutes: inputs, externalStages: externalStages
        )

        let runs = SleepStageDetectorV2.runs(stages: stages, startDate: pm.startDate)
        var blocks: [TimelineStageBlock] = []
        blocks.reserveCapacity(runs.count)
        for run in runs {
            let minutes = Int(run.endDate.timeIntervalSince(run.startDate) / 60)
            let label = "\(timeFmt.string(from: run.startDate)) – \(timeFmt.string(from: run.endDate))  \(run.stage.rawValue) (\(minutes)m)"
            blocks.append(TimelineStageBlock(
                stage: run.stage, minutes: minutes,
                startDate: run.startDate, endDate: run.endDate,
                stageLabel: label, events: []
            ))
        }
        return blocks
    }

    /// Fallback: 3-class 90-min-cycle template scaled to the summary
    /// distribution, used when per-minute BLE telemetry isn't available
    /// for this session (session predates the CPAP cache window, BLE
    /// fetch failed, or session is shorter than the model's 30-min
    /// minimum input length).
    ///
    /// Deliberately emits NO Deep blocks. Distinguishing Light from
    /// Deep requires HR variability, which we don't have here — the
    /// template is a pure architectural guess at what sleep looked
    /// like, not an HR-informed classification. Emitting Deep blocks
    /// would contradict the "3-class chart when HR is partial or
    /// absent" rule: a single template-sourced Deep block on a day
    /// where all other sessions collapsed to 3-class would flip the
    /// chart to 4 lanes.
    ///
    /// REM grows as the night progresses; brief Awake fragments at
    /// cycle boundaries (not at sleep onset, since you don't wake
    /// right when you fall asleep).
    private func buildBlocksFromTemplate(sess: DaySummary.Session,
                                          dist: [SleepStage: Double]) -> [TimelineStageBlock] {
        var sessBlocks: [TimelineStageBlock] = []
        let dur = sess.durationMinutes
        let cycleMin = 90
        let cycles = max(1, dur / cycleMin)

        var remaining = dur
        for c in 0..<cycles {
            let chunkMin = c == cycles - 1 ? remaining : cycleMin
            guard chunkMin > 0 else { continue }

            let remFrac   = (dist[.rem]   ?? 0.20) * CGFloat(c + 1) / CGFloat(cycles) * 2
            let awakeFrac = dist[.awake] ?? 0.05

            let remMin   = max(0, Int(Double(chunkMin) * Double(remFrac)))
            let awakeMin = c > 0 ? max(0, Int(Double(chunkMin) * Double(awakeFrac))) : 0
            let lightMin = max(0, chunkMin - remMin - awakeMin)

            var offset = sess.startDate.addingTimeInterval(Double(dur - remaining) * 60)
            func addBlock(_ stage: SleepStage, _ mins: Int) {
                guard mins > 0 else { return }
                let end = offset.addingTimeInterval(Double(mins) * 60)
                let label = "\(timeFmt.string(from: offset)) – \(timeFmt.string(from: end))  \(stage.rawValue) (\(mins)m)"
                sessBlocks.append(TimelineStageBlock(
                    stage: stage, minutes: mins,
                    startDate: offset, endDate: end,
                    stageLabel: label, events: []
                ))
                offset = end
            }
            if awakeMin > 0 { addBlock(.awake, awakeMin) }
            addBlock(.light, lightMin)
            addBlock(.rem, remMin)
            remaining -= chunkMin
        }
        return sessBlocks
    }

    // MARK: - Helpers

    private func statCell(_ label: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
            HStack(spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(unit).font(.caption2).foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Width of the label column (first) in every percentile row.
    private static let percentileLabelColumnW: CGFloat = 100
    /// Width of each numeric percentile column. Monospaced caption
    /// with "%.2f" values maxes out around "99.99" = 5 chars ≈ 40 pt;
    /// 54 pt gives comfortable alignment and matches the header.
    private static let percentileValueColumnW: CGFloat = 54

    /// Column header above each section's percentile rows. The
    /// numbers are how ResMed's Summary spool reports distributions —
    /// p50 is the night-long median, p95 the upper tail, max the
    /// single peak observation. Leak rows add p70 (see below).
    private func percentileHeader() -> some View {
        HStack {
            Text("").frame(width: Self.percentileLabelColumnW, alignment: .leading)
            Text("p50").frame(width: Self.percentileValueColumnW, alignment: .trailing)
            Text("p95").frame(width: Self.percentileValueColumnW, alignment: .trailing)
            Text("max").frame(width: Self.percentileValueColumnW, alignment: .trailing)
            Text("").foregroundStyle(.secondary)
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private func percentileRow(_ label: String, p: DaySummary.Percentiles, unit: String) -> some View {
        HStack {
            Text(label).frame(width: Self.percentileLabelColumnW, alignment: .leading)
            Text(String(format: "%.2f", p.p50))
                .frame(width: Self.percentileValueColumnW, alignment: .trailing)
            Text(String(format: "%.2f", p.p95))
                .frame(width: Self.percentileValueColumnW, alignment: .trailing)
            Text(String(format: "%.2f", p.max))
                .frame(width: Self.percentileValueColumnW, alignment: .trailing)
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.system(.caption, design: .monospaced))
    }

    /// Show the raw per-hour index as the BLE Summary spool reports it
    /// (no rounding to event counts). Two decimals so small values are
    /// preserved instead of being smeared by integer rounding.
    private func eventRow(name: String, description: String, value: Double, color: Color? = nil) -> some View {
        let displayColor = color ?? (value > 0 ? .orange : .green)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                HStack(spacing: 4) {
                    Text(String(format: "%.2f", value))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(value > 0 ? displayColor : .green)
                    Text("/hr")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private func fmtSeconds(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        let m = s / 60, rem = s % 60
        return rem == 0 ? "\(m)m" : "\(m)m \(rem)s"
    }

    /// Color-code the combined AHI by clinical severity.
    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<5:  return .green
        case ..<15: return .yellow
        case ..<30: return .orange
        default:    return .red
        }
    }

    /// Build a rectangle path with optional rounded top and/or bottom
    /// corners. Used to make stage-bar runs read as a single column:
    /// only the first block in a run rounds its top, only the last
    /// rounds its bottom, and same-lane neighbors stay flat-edged.
    /// Per-corner rounding flags. When the connector enters/exits a
    /// bar from the side, the corner facing the connector is squared
    /// off so the thin connector line meets a flat edge instead of
    /// hitting the rounded cap's tip.
    private struct Corners {
        var topLeft: Bool
        var topRight: Bool
        var bottomLeft: Bool
        var bottomRight: Bool
        static let allRounded = Corners(topLeft: true, topRight: true,
                                        bottomLeft: true, bottomRight: true)
    }

    private func barPath(rect: CGRect, corners c: Corners, radius: CGFloat) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        var p = Path()
        if c.topLeft {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                     radius: r, startAngle: .degrees(180), endAngle: .degrees(270),
                     clockwise: false)
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX - (c.topRight ? r : 0), y: rect.minY))
        if c.topRight {
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                     radius: r, startAngle: .degrees(270), endAngle: .degrees(0),
                     clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - (c.bottomRight ? r : 0)))
        if c.bottomRight {
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                     radius: r, startAngle: .degrees(0), endAngle: .degrees(90),
                     clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.minX + (c.bottomLeft ? r : 0), y: rect.maxY))
        if c.bottomLeft {
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                     radius: r, startAngle: .degrees(90), endAngle: .degrees(180),
                     clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }

    private func fmtDuration(_ m: Int) -> String {
        let h = m / 60, mm = m % 60
        return h == 0 ? "\(mm)m" : "\(h)h \(mm)m"
    }

    /// Derive myAir-style mask seal rating from 95th percentile leak.
    /// Thresholds in L/min: <24 Great, 24-36 Good, 36-48 OK, >=48 Poor.
    /// Input is L/s (as stored in our protobuf); x60 for L/min.
    private func maskSealRating(p95Ls: Double) -> (String, Color) {
        let lpm = p95Ls * 60.0
        switch lpm {
        case ..<24: return ("Great", .green)
        case ..<36: return ("Good",  .cyan)
        case ..<48: return ("OK",    .yellow)
        default:    return ("Poor",  .red)
        }
    }

    /// Color-code an individual leak value (L/s) on the same scale.
    private func leakColor(_ ls: Double) -> Color {
        let lpm = ls * 60.0
        switch lpm {
        case ..<24: return .green
        case ..<36: return .cyan
        case ..<48: return .yellow
        default:    return .red
        }
    }
}
