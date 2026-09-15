#if arch(arm64)
import SwiftUI

/// The rift that tears open while a workspace is being prepared.
///
/// `progress` is the real creation progress (0...1) rather than a decorative
/// loop, so the seam doubles as a progress indicator: the tear widens, deepens
/// and brightens as the download and install advance, then blooms into the
/// workspace icon once creation finishes.
///
/// A failed preparation renders nothing. The error screen should be read, not
/// decorated, and a frozen seam in the middle of the window reads as a
/// rendering fault rather than a state.
struct RiftCreationEffect: View {
    let isReady: Bool
    let isActive: Bool
    let isOmarchy: Bool
    var progress: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Motion stops when the window is in the background so a hidden window
    /// does not keep animating.
    private var animates: Bool { isActive && !reduceMotion && scenePhase == .active }

    /// Eased so the first bytes of a long download already move the seam.
    static func openness(_ progress: Double) -> Double {
        pow(min(max(progress, 0), 1), 0.6)
    }

    var body: some View {
        ZStack {
            if isReady || isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
                    RiftField(
                        // Freezing the clock under Reduce Motion renders one
                        // calm frame instead of an arbitrary mid-flight one.
                        time: animates ? context.date.timeIntervalSinceReferenceDate : 0,
                        openness: Self.openness(progress),
                        isReady: isReady
                    )
                }
            }
            if isReady {
                WorkspaceSystemIcon(isOmarchy: isOmarchy, size: 112)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: isReady)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: progress)
        .accessibilityHidden(true)
    }
}

/// One frame of the rift.
///
/// The drawing takes the animation clock as a value instead of reading it, so
/// the same code renders deterministically outside the app.
struct RiftField: View {
    let time: Double
    let openness: Double
    var isReady: Bool = false

    private static let frameHeight: Double = 190

    private let warm = Color(red: 1.0, green: 0.44, blue: 0.24)
    private let cool = Color(red: 0.28, green: 0.62, blue: 1.0)

    /// Half the width of the tear at its waist, and its total height. Kept
    /// narrow on purpose: a rift should read as a cut, not as a light bulb.
    /// When the workspace is ready the seam pulls back to a slit so the icon
    /// in front of it stays legible.
    private var waist: Double { isReady ? 10 : 1.5 + openness * 15 }
    private var tearHeight: Double { isReady ? 170 : 92 + openness * 74 }
    private var energy: Double { isReady ? 0.42 : 0.18 + openness * 0.72 }

    /// The tear has to carry its own width, because the seam gradient is laid
    /// out across the shape it fills rather than across this container.
    private var seamWidth: Double { max(waist * 2 + 12, 18) }

    var body: some View {
        ZStack {
            atmosphere
            chromaticFringe
            seam
            filament
            motes
        }
        .frame(width: 340, height: Self.frameHeight)
    }

    /// A faint bleed of light just off the seam. Deliberately tight: a wide
    /// haze reads as a smudge on the window rather than as space bending.
    private var atmosphere: some View {
        ZStack {
            Ellipse()
                .fill(warm)
                .frame(width: 46 + waist * 1.4, height: tearHeight * 0.72)
                .blur(radius: 22)
                .offset(x: -(waist + 10))
            Ellipse()
                .fill(cool)
                .frame(width: 46 + waist * 1.4, height: tearHeight * 0.72)
                .blur(radius: 22)
                .offset(x: waist + 10)
            if isReady {
                // Keeps the workspace icon from sitting on a flat, dark field.
                Ellipse()
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.14), .clear],
                        center: .center, startRadius: 8, endRadius: 90
                    ))
                    .frame(width: 210, height: 190)
            }
        }
        .opacity(0.07 + energy * 0.16)
    }

    /// Warm and cool light bent along the lips of the tear. Narrow enough to
    /// trace the seam instead of pooling beside it.
    private var chromaticFringe: some View {
        ZStack {
            Ellipse()
                .fill(warm)
                .frame(width: 13 + waist * 0.9, height: tearHeight * 0.9)
                .blur(radius: 13)
                .offset(x: -(waist + 4))
            Ellipse()
                .fill(cool)
                .frame(width: 13 + waist * 0.9, height: tearHeight * 0.9)
                .blur(radius: 13)
                .offset(x: waist + 4)
        }
        .opacity(0.14 + energy * 0.46)
    }

    /// The tear itself: an irregular opening with lit lips.
    private var seam: some View {
        ZStack {
            RiftTear(waist: waist, height: tearHeight, jitter: 1, time: time)
                .fill(LinearGradient(stops: [
                    .init(color: warm, location: 0),
                    .init(color: warm.opacity(0.92), location: 0.2),
                    .init(color: warm.opacity(0.4), location: 0.4),
                    .init(color: .white, location: 0.5),
                    .init(color: cool.opacity(0.4), location: 0.6),
                    .init(color: cool.opacity(0.92), location: 0.8),
                    .init(color: cool, location: 1),
                ], startPoint: .leading, endPoint: .trailing))
                .frame(width: seamWidth, height: tearHeight)
                .blur(radius: 0.9)
                .shadow(color: warm.opacity(0.55), radius: 6)
                .shadow(color: cool.opacity(0.55), radius: 6)

            RiftTear(waist: waist, height: tearHeight, jitter: 1, time: time)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.9), .white.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.9
                )
                .frame(width: seamWidth, height: tearHeight)
                .blur(radius: 0.4)
                .opacity(0.35 + energy * 0.5)
        }
        .opacity(0.4 + energy * 0.6)
    }

    /// The hot line of light down the middle of the tear.
    private var filament: some View {
        let flicker = (sin(time * 5.3) + sin(time * 2.1 + 1.7)) / 2
        return ZStack {
            Capsule()
                .fill(.white)
                .frame(width: max(0.8 + openness * 1.2, 0.8), height: tearHeight * 0.8)
                .blur(radius: 5)
                .opacity(0.1 + energy * 0.2)
            Capsule()
                .fill(.white)
                .frame(width: max(0.6 + openness * 0.5, 0.6), height: tearHeight * 0.72)
                .blur(radius: 1.1)
                .opacity(0.2 + energy * 0.24 + flicker * 0.08)
                .offset(x: sin(time * 1.3) * (0.5 + openness * 0.9))
        }
    }

    /// Matter falling into the seam from both sides.
    private var motes: some View {
        ZStack {
            ForEach(0 ..< 10, id: \.self) { index in
                let seed = Double(index)
                let life = (time * (0.22 + openness * 0.3) + seed / 10).truncatingRemainder(dividingBy: 1)
                let fall = life * life
                let side: Double = index.isMultiple(of: 2) ? -1 : 1
                let spread = sin((seed + 1) * 2.4)
                let reached = waist + 4
                Circle()
                    .fill(side < 0 ? warm : cool)
                    .frame(width: 1.6 + (1 - life) * 1.8, height: 1.6 + (1 - life) * 1.8)
                    .blur(radius: 0.5)
                    .offset(
                        x: side * (118 - fall * (118 - reached)),
                        y: spread * tearHeight * 0.34
                    )
                    .opacity(sin(life * .pi) * (0.3 + energy * 0.6))
            }
        }
    }
}

/// The outline of the tear: two irregular lips that bow apart at the waist.
private struct RiftTear: Shape {
    var waist: Double
    var height: Double
    var jitter: Double
    var time: Double

    /// How wide the tear is at each point from the top tip to the bottom tip.
    /// The waist sits slightly above centre so the rip does not look machined.
    private static let profile: [(position: Double, width: Double)] = [
        (0.00, 0.11), (0.14, 0.33), (0.30, 0.72), (0.46, 1.00),
        (0.62, 0.74), (0.82, 0.35), (1.00, 0.13),
    ]

    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        let top = rect.midY - height / 2

        func point(_ index: Int, _ side: Double) -> CGPoint {
            let node = Self.profile[index]
            let taper = sin(node.position * .pi)
            let wobble = jitter * taper * (
                sin(time * 0.7 + Double(index) * 1.9 + side * 2.3) * 2.6 +
                    sin(time * 1.9 + Double(index) * 3.1) * 1.2
            )
            // The waist drifts along the tear so the rip never looks machined.
            let breathing = 1 + 0.18 * sin(time * 0.45 + Double(index) * 1.3)
            return CGPoint(
                x: midX + side * (waist * node.width * breathing + wobble),
                y: top + height * node.position
            )
        }

        var right: [CGPoint] = []
        var left: [CGPoint] = []
        for index in Self.profile.indices {
            right.append(point(index, 1))
            left.append(point(index, -1))
        }

        var path = smoothed(right)
        path.addLine(to: left[left.count - 1])
        path.addPath(smoothed(left.reversed()))
        path.closeSubpath()
        return path
    }

    /// Connects the nodes with quad curves through their midpoints, which keeps
    /// the wobble smooth instead of polygonal.
    private func smoothed(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        for index in 1 ..< points.count - 1 {
            let current = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
#endif
