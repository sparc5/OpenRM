//
//  LEDDisplay.swift
//  OpenRM
//
//  Seven-segment LED-style display rendered with SwiftUI Canvas.
//  No font dependency — segments are drawn as hexagonal slabs so it
//  looks like a real LED display, not monospaced text.
//

import SwiftUI

// MARK: - Public API

/// A seven-segment LED-style display that renders a string.
/// Supported characters: 0-9, '.', '-', ' '.
/// Unknown characters render as a blank slot (all segments off).
struct SevenSegmentDisplay: View {
    let text: String
    var onColor: Color = .red
    var digitWidth: CGFloat = 42
    var digitHeight: CGFloat = 76
    var spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                if ch == "." {
                    // Decimal point: a square "dot" taking the same baseline
                    // as a digit but much narrower.
                    DecimalDot(onColor: onColor)
                        .frame(width: digitWidth * 0.2, height: digitHeight)
                } else {
                    SevenSegmentDigit(char: ch, onColor: onColor)
                        .frame(width: digitWidth, height: digitHeight)
                }
            }
        }
    }
}

/// A single seven-segment digit.
struct SevenSegmentDigit: View {
    let char: Character
    var onColor: Color = .red

    var body: some View {
        Canvas { ctx, size in
            let segs = segments(for: char)
            drawDigit(ctx: &ctx, size: size, active: segs, onColor: onColor)
        }
    }
}

/// Just the decimal dot, rendered at the baseline.
private struct DecimalDot: View {
    let onColor: Color
    var body: some View {
        Canvas { ctx, size in
            let thick = min(size.width, size.height * 0.15)
            let dotRect = CGRect(
                x: (size.width - thick) / 2,
                y: size.height - thick - 2,
                width: thick,
                height: thick
            )
            ctx.fill(Path(ellipseIn: dotRect), with: .color(onColor))
        }
    }
}

// MARK: - Drawing

private func drawDigit(
    ctx: inout GraphicsContext,
    size: CGSize,
    active: Set<Character>,
    onColor: Color
) {
    let w = size.width
    let h = size.height
    let thick = min(w, h) * 0.16
    let gap = thick * 0.15

    // Off color: very dim version of the on color so unused segments
    // are faintly visible (authentic LCD/LED look).
    let offColor = onColor.opacity(0.08)

    func col(_ seg: Character) -> Color {
        active.contains(seg) ? onColor : offColor
    }

    // a: top horizontal
    ctx.fill(
        hSegment(x: 0, y: 0, w: w, thick: thick, gap: gap),
        with: .color(col("a"))
    )
    // g: middle horizontal
    ctx.fill(
        hSegment(x: 0, y: (h - thick) / 2, w: w, thick: thick, gap: gap),
        with: .color(col("g"))
    )
    // d: bottom horizontal
    ctx.fill(
        hSegment(x: 0, y: h - thick, w: w, thick: thick, gap: gap),
        with: .color(col("d"))
    )
    // f: top-left vertical
    ctx.fill(
        vSegment(x: 0, y: 0, h: h / 2, thick: thick, gap: gap),
        with: .color(col("f"))
    )
    // e: bottom-left vertical
    ctx.fill(
        vSegment(x: 0, y: h / 2, h: h / 2, thick: thick, gap: gap),
        with: .color(col("e"))
    )
    // b: top-right vertical
    ctx.fill(
        vSegment(x: w - thick, y: 0, h: h / 2, thick: thick, gap: gap),
        with: .color(col("b"))
    )
    // c: bottom-right vertical
    ctx.fill(
        vSegment(x: w - thick, y: h / 2, h: h / 2, thick: thick, gap: gap),
        with: .color(col("c"))
    )
}

/// Horizontal hexagonal segment (like a stretched hexagon lying flat).
private func hSegment(x: CGFloat, y: CGFloat, w: CGFloat, thick: CGFloat, gap: CGFloat) -> Path {
    var p = Path()
    let half = thick / 2
    p.move(to:    CGPoint(x: x + gap,           y: y + half))
    p.addLine(to: CGPoint(x: x + gap + half,    y: y))
    p.addLine(to: CGPoint(x: x + w - gap - half, y: y))
    p.addLine(to: CGPoint(x: x + w - gap,       y: y + half))
    p.addLine(to: CGPoint(x: x + w - gap - half, y: y + thick))
    p.addLine(to: CGPoint(x: x + gap + half,    y: y + thick))
    p.closeSubpath()
    return p
}

/// Vertical hexagonal segment (hexagon standing up).
private func vSegment(x: CGFloat, y: CGFloat, h: CGFloat, thick: CGFloat, gap: CGFloat) -> Path {
    var p = Path()
    let half = thick / 2
    p.move(to:    CGPoint(x: x + half,         y: y + gap))
    p.addLine(to: CGPoint(x: x + thick,        y: y + gap + half))
    p.addLine(to: CGPoint(x: x + thick,        y: y + h - gap - half))
    p.addLine(to: CGPoint(x: x + half,         y: y + h - gap))
    p.addLine(to: CGPoint(x: x,                y: y + h - gap - half))
    p.addLine(to: CGPoint(x: x,                y: y + gap + half))
    p.closeSubpath()
    return p
}

/// Which segments are lit for a given character.
private func segments(for char: Character) -> Set<Character> {
    switch char {
    case "0": return ["a", "b", "c", "d", "e", "f"]
    case "1": return ["b", "c"]
    case "2": return ["a", "b", "g", "e", "d"]
    case "3": return ["a", "b", "g", "c", "d"]
    case "4": return ["f", "g", "b", "c"]
    case "5": return ["a", "f", "g", "c", "d"]
    case "6": return ["a", "c", "d", "e", "f", "g"]
    case "7": return ["a", "b", "c"]
    case "8": return ["a", "b", "c", "d", "e", "f", "g"]
    case "9": return ["a", "b", "c", "d", "f", "g"]
    case "-": return ["g"]
    default:  return []   // blank / unknown
    }
}

// MARK: - Panel wrapper (black bezel + title + LEDs)

/// A finished "instrument panel" containing a title row, the LED digits
/// on a black background, and a unit label. Use this as the dashboard tile.
///
/// The outer card uses Liquid Glass (iOS 26 / macOS Tahoe 26) — the title
/// and unit text float on a translucent glass surface, while the LED area
/// keeps its opaque black background so the seven-segment display stays
/// legible (glass-on-glass would muddle the segments and violates Apple's
/// "no stacking glass" guidance).
struct LEDPanel: View {
    let title: String
    let valueText: String       // pre-formatted (e.g. " 4.0", "12.3")
    let unit: String
    var color: Color = .red
    var size: CGSize = CGSize(width: 42, height: 76)
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
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
            SevenSegmentDisplay(
                text: valueText,
                onColor: color,
                digitWidth: size.width,
                digitHeight: size.height,
                spacing: compact ? 3 : 6
            )
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
    }
}

// MARK: - PIN entry components

/// Four LED-style digit slots displaying the entered PIN. Empty slots
/// render as "8" with all segments off (the authentic "ghost" look).
struct PINDisplay: View {
    let pin: String
    var color: Color = .red
    var digitWidth: CGFloat = 42
    var digitHeight: CGFloat = 76

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                let chars = Array(pin)
                let ch: Character = i < chars.count ? chars[i] : " "
                SevenSegmentDigit(char: ch, onColor: color)
                    .frame(width: digitWidth, height: digitHeight)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)
        )
        .shadow(color: color.opacity(0.3), radius: 8)
    }
}

/// 3×4 numeric keypad (1–9, backspace, 0). Calls back per tap.
struct PINKeypad: View {
    let onDigit: (Character) -> Void
    let onBackspace: () -> Void

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["",  "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        let label = rows[r][c]
                        keyButton(label)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ label: String) -> some View {
        if label.isEmpty {
            Color.clear.frame(width: 64, height: 56)
        } else if label == "⌫" {
            Button(action: onBackspace) {
                Image(systemName: "delete.left")
                    .font(.title2)
                    .frame(width: 64, height: 56)
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                onDigit(label.first!)
            } label: {
                Text(label)
                    .font(.title)
                    .frame(width: 64, height: 56)
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        LEDPanel(title: "MASK PRESSURE", valueText: " 4.0", unit: "cmH₂O")
        LEDPanel(title: "SET PRESSURE",  valueText: "12.8", unit: "cmH₂O", color: .green)
        LEDPanel(title: "RAMP",          valueText: "30.0", unit: "sec",   color: .orange)
        PINDisplay(pin: "12")
        PINKeypad(onDigit: { _ in }, onBackspace: {})
    }
    .padding()
    .frame(width: 480)
    .background(Color.gray.opacity(0.1))
}
