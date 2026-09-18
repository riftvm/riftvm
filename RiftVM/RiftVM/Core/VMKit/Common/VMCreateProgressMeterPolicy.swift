import Foundation

/// Geometry and per-bar motion for the equalizer meter shown while a workspace
/// is prepared.
///
/// The meter doubles as the progress indicator: blocks light from the left as
/// the download advances, the block at the frontier bounces hardest, and the
/// blocks already behind it settle. Heights are a pure function of
/// `(index, progress, time)` so a paused frame — a background window, Reduce
/// Motion, or a screenshot — is reproducible instead of arbitrary.
public enum VMCreateProgressMeterGeometry {
    public static let barCount = 40
    public static let barWidth: Double = 8
    public static let gap: Double = 5
    public static let minimumHeight: Double = 12
    public static let maximumHeight: Double = 58
    /// Baseline drawn under the row; the row occupies `maximumHeight + gap`.
    public static let rowHeight: Double = maximumHeight + gap

    /// Width the whole row occupies. The preparation screen centres the row in a
    /// 680-point-wide content column, so the meter has to read as the subject of
    /// that space instead of a small strip in the middle of it.
    public static var rowWidth: Double {
        Double(barCount) * barWidth + Double(barCount - 1) * gap
    }

    /// Number of lit blocks, fractional while the frontier is inside a block.
    public static func litBars(progress: Double) -> Double {
        min(max(progress, 0), 1) * Double(barCount)
    }

    public static func isLit(index: Int, progress: Double) -> Bool {
        Double(index) < litBars(progress: progress)
    }

    /// Height a downloaded block settles to while the frontier is still ahead
    /// of it. Deliberately low: the frontier block is the one that should read
    /// as "in progress".
    public static func settledHeight(index: Int, progress: Double) -> Double {
        guard isLit(index: index, progress: progress) else { return minimumHeight }
        return minimumHeight + (maximumHeight - minimumHeight) * 0.30
    }

    /// The finished row, held for a beat when the workspace becomes ready. Taller
    /// than a settled block so the hand-off reads as "full", not "stopped".
    public static let readyRowHeight: Double = minimumHeight + (maximumHeight - minimumHeight) * 0.62

    /// How close a block sits to the download frontier, 0 ... 1. The frontier
    /// block carries the largest bounce, which is what makes the row read as a
    /// live level meter rather than a static progress bar.
    public static func frontierProximity(index: Int, progress: Double) -> Double {
        let lit = litBars(progress: progress)
        return max(0, 1 - abs(lit - Double(index) - 0.5) / 2.5)
    }

    /// Bounce envelope across the download: quiet at the start, livelier as the
    /// guest comes together.
    public static func envelope(progress: Double) -> Double {
        0.35 + 0.65 * min(max(progress, 0), 1)
    }

    public static func height(index: Int, progress: Double, time: Double) -> Double {
        guard isLit(index: index, progress: progress) else { return minimumHeight }
        let settled = min(1, (litBars(progress: progress) - Double(index)) / 3)
        let amplitude = (maximumHeight - minimumHeight)
            * (0.22 * envelope(progress: progress) + 0.5 * frontierProximity(index: index, progress: progress))
        let phase = sin(Double(index) * 1.7 + time * 3.1)
        let raw = minimumHeight
            + (maximumHeight - minimumHeight) * 0.30 * settled
            + amplitude * (0.5 + 0.5 * phase)
        return min(maximumHeight, max(minimumHeight, raw))
    }

    /// Static height used when motion is off: the finished row while the
    /// workspace is ready, otherwise the settled row for the progress reached so
    /// far.
    public static func restingHeight(index: Int, progress: Double, isReady: Bool = false) -> Double {
        guard isLit(index: index, progress: progress) else { return minimumHeight }
        return isReady ? readyRowHeight : settledHeight(index: index, progress: progress)
    }
}
