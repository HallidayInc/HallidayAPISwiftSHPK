import SwiftUI

// The grid-wave loader: a 4x4 pixel grid with a diagonal CRT-green sweep. Each cell runs the
// same 1.6s cycle, delayed by (row + col) * 0.1s, peaking 35% of the way through and easing
// back. Driven from a timeline rather than sixteen repeating animations so every cell reads
// the same clock and the diagonal cannot drift.
struct GridWave: View {
    var cell: CGFloat = 14
    var gap: CGFloat = 6

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let peak = 0.35
    // Seven diagonals, spread evenly across the cycle so the sweep is continuous. The
    // stylesheet's fixed 0.1s stagger only covered 0.6s of its 1.6s cycle, leaving the grid
    // fading together for the rest — which reads as the animation stopping.
    private static let diagonals = 7.0

    private typealias RGB = (r: Double, g: Double, b: Double)

    // #ECECEC on light, matching the stylesheet; the dark pill fill is its counterpart.
    private static let lightIdle: RGB = (236 / 255, 236 / 255, 236 / 255)
    private static let darkIdle: RGB = (38 / 255, 38 / 255, 38 / 255)
    private static let active: RGB = (61 / 255, 245 / 255, 123 / 255)

    private var idle: RGB { scheme == .dark ? Self.darkIdle : Self.lightIdle }

    var body: some View {
        // Always animates. The stylesheet freezes the grid under prefers-reduced-motion, but
        // a frozen loader reads as a broken image; since nothing here moves — it is only a
        // colour cross-fade — reduced motion slows the sweep and softens it instead.
        TimelineView(.animation) { context in
            cells(sweep(at: context.date.timeIntervalSinceReferenceDate))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    // Reduced motion slows the sweep but keeps its full contrast: dimming it as well made
    // it too faint to read as activity.
    private var duration: Double { reduceMotion ? 2.2 : 1.4 }
    private var stagger: Double { duration / Self.diagonals }

    // The grid holds resolved colours rather than a closure, so each tick puts new values
    // into the view tree for SwiftUI to notice.
    private func cells(_ colours: [Color]) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<4, id: \.self) { col in
                        Rectangle()
                            .fill(colours[row * 4 + col])
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }

    private func sweep(at time: TimeInterval) -> [Color] {
        (0..<16).map { index in
            let row = index / 4, col = index % 4
            let delay = Double(row + col) * stagger
            var phase = (time - delay).truncatingRemainder(dividingBy: duration) / duration
            if phase < 0 { phase += 1 }

            // CSS eases between each pair of keyframes, so the rise and the fall are eased
            // separately rather than as one curve across the whole cycle.
            let peak = Self.peak
            let progress = phase < peak ? phase / peak : 1 - (phase - peak) / (1 - peak)
            return blend(progress * progress * (3 - 2 * progress))
        }
    }

    private func blend(_ amount: Double) -> Color {
        let base = idle
        let lit = Self.active
        return Color(
            red: base.r + (lit.r - base.r) * amount,
            green: base.g + (lit.g - base.g) * amount,
            blue: base.b + (lit.b - base.b) * amount
        )
    }
}
