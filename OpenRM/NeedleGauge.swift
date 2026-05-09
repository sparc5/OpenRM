//
//  NeedleGauge.swift
//  OpenRM
//
//  Analog needle gauge drawn with SwiftUI Canvas. Shell matches the
//  LEDPanel styling (title top-left, unit top-right, black instrument
//  area, glass bezel) so the two can sit side-by-side in the dashboard
//  instrument cluster and read as the same kind of readout.
//

import SwiftUI

struct NeedleGauge: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let unit: String
    var color: Color = .green
    var tickCount: Int = 5
    var compact: Bool = false
    /// Optional marker drawn on the arc to show the user's configured target
    /// (e.g. the tube-temperature setting when the needle shows actual temp).
    var settingValue: Double? = nil
    /// Fades the whole gauge to signal "not actively doing anything" (e.g.
    /// humidifier/heater power is 0%).
    var dimmed: Bool = false

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private func fraction(for v: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private let sweepDegrees: Double = 270

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            // Title / unit header — mirrors LEDPanel exactly so the two
            // read as a coherent instrument row.
            HStack {
                Text(title)
                    .font(compact ? .system(size: 9) : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 2)
                Text(unit)
                    .font(compact ? .system(size: 9) : .caption)
                    .foregroundStyle(.secondary)
            }

            // Black instrument well — same visual treatment as the LED
            // digit box so the two tile types align on shared edges.
            GeometryReader { geo in
                gaugeCanvas(size: geo.size)
            }
            .aspectRatio(1.6, contentMode: .fit)
            .padding(.vertical, compact ? 4 : 12)
            .padding(.horizontal, compact ? 4 : 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: compact ? 6 : 8)
                    .fill(Color.black)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 6 : 8)
                    .stroke(Color.black.opacity(0.8), lineWidth: 1)
            )
            .shadow(color: color.opacity(0.3), radius: compact ? 4 : 8)
        }
        .padding(compact ? 6 : 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: compact ? 10 : 16))
        .opacity(dimmed ? 0.45 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: dimmed)
    }

    private func gaugeCanvas(size: CGSize) -> some View {
        Canvas { ctx, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height * 0.62)
            let radius = min(canvasSize.width * 0.45, canvasSize.height * 0.55)
            let startAngle = Angle.degrees(225)
            let endAngle = Angle.degrees(-45)

            // Arc track (dim background)
            var arcPath = Path()
            arcPath.addArc(center: center, radius: radius,
                           startAngle: startAngle, endAngle: endAngle,
                           clockwise: true)
            ctx.stroke(arcPath, with: .color(.white.opacity(0.15)),
                       lineWidth: 2.5)

            // Major ticks + labels
            for i in 0...tickCount {
                let t = Double(i) / Double(tickCount)
                let angle = Angle.degrees(225 - t * sweepDegrees)
                let c = Darwin.cos(angle.radians)
                let s = Darwin.sin(angle.radians)
                let outer = CGPoint(x: center.x + c * radius,
                                    y: center.y - s * radius)
                let inner = CGPoint(x: center.x + c * (radius - 7),
                                    y: center.y - s * (radius - 7))
                var tp = Path()
                tp.move(to: outer)
                tp.addLine(to: inner)
                ctx.stroke(tp, with: .color(.white.opacity(0.45)),
                           lineWidth: 1.5)

                let labelVal = range.lowerBound + t * (range.upperBound - range.lowerBound)
                let labelStr = String(format: "%.0f", labelVal)
                ctx.draw(
                    Text(labelStr)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55)),
                    at: CGPoint(x: center.x + c * (radius - 18),
                                y: center.y - s * (radius - 18))
                )
            }

            // Setting tick — a bright white notch on the arc at the
            // target value. Compact enough to not break up the arc
            // visually (earlier wide band looked like a gap).
            if let target = settingValue {
                let tFrac = fraction(for: target)
                let deg = 225 - tFrac * sweepDegrees
                let rad = deg * .pi / 180
                let c0 = Darwin.cos(rad)
                let s0 = Darwin.sin(rad)
                let outer = CGPoint(x: center.x + c0 * (radius + 4),
                                    y: center.y - s0 * (radius + 4))
                let inner = CGPoint(x: center.x + c0 * (radius - 10),
                                    y: center.y - s0 * (radius - 10))
                var tickPath = Path()
                tickPath.move(to: outer)
                tickPath.addLine(to: inner)
                ctx.stroke(tickPath, with: .color(.white), lineWidth: 3)
            }

            let needleAngle = Angle.degrees(225 - fraction * sweepDegrees)

            // Needle (rectangle)
            let needleLen = radius * 0.85
            let c = Darwin.cos(needleAngle.radians)
            let s = Darwin.sin(needleAngle.radians)
            let hw: CGFloat = 2
            let pc = Darwin.cos(needleAngle.radians + .pi / 2)
            let ps = Darwin.sin(needleAngle.radians + .pi / 2)
            let tipL = CGPoint(x: center.x + c * needleLen + pc * hw,
                               y: center.y - s * needleLen - ps * hw)
            let tipR = CGPoint(x: center.x + c * needleLen - pc * hw,
                               y: center.y - s * needleLen + ps * hw)
            let baseL = CGPoint(x: center.x + pc * hw,
                                y: center.y - ps * hw)
            let baseR = CGPoint(x: center.x - pc * hw,
                                y: center.y + ps * hw)
            var np = Path()
            np.move(to: tipL)
            np.addLine(to: tipR)
            np.addLine(to: baseR)
            np.addLine(to: baseL)
            np.closeSubpath()
            ctx.fill(np, with: .color(color))

            // Hub
            let dr: CGFloat = 4
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - dr, y: center.y - dr,
                                            width: dr * 2, height: dr * 2)),
                     with: .color(.white))

            // Digital readout
            let readout = range.upperBound - range.lowerBound >= 10
                ? String(format: "%.0f", value)
                : String(format: "%.1f", value)
            ctx.draw(
                Text(readout)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(color),
                at: CGPoint(x: center.x, y: center.y + radius * 0.55)
            )
        }
    }
}

#Preview {
    HStack(spacing: 8) {
        NeedleGauge(title: "HUMIDITY", value: 4, range: 0...8, unit: "level", color: .cyan, tickCount: 4, compact: true)
        NeedleGauge(title: "TUBE TEMP", value: 27, range: 16...30, unit: "°C", color: .orange, tickCount: 7, compact: true)
    }
    .padding()
    .frame(width: 360)
    .background(Color.gray.opacity(0.1))
    .preferredColorScheme(.dark)
}
