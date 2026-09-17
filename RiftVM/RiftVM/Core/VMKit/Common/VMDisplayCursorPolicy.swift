import Foundation

/// Decides which cursor is visible while Custom VirGL runs in absolute pointer
/// mode.
///
/// Two sources can draw a cursor at once:
///
/// * virtio-gpu's cursor plane, which this app composites into its own layer and
///   hides in absolute mode, because the macOS cursor already sits at the exact
///   guest position; and
/// * the guest compositor's own cursor, painted into the scanout when it falls
///   back to software cursors. Those pixels cannot be hidden individually, so
///   the macOS cursor is the duplicate that has to yield.
///
/// The guest cannot announce which path it took, but the plane only exists while
/// the guest actually uses it: a guest that paints its own cursor never issues
/// `UPDATE_CURSOR`/`MOVE_CURSOR`. So a guest that repaints in response to
/// absolute pointer events without ever producing a cursor-plane update is
/// presenting its own cursor, and the macOS cursor must be hidden to leave
/// exactly one.
///
/// The decision is sticky in both directions: once the plane is seen the macOS
/// cursor keeps serving as the pointer, and once the guest proves it paints its
/// own cursor, a later plane update hands the pointer back.
public struct VMGuestCursorPresentationPolicy: Equatable, Sendable {
    /// Presented frames accepted after an absolute pointer event before the
    /// guest is considered to paint its own cursor. Pointer motion repaints the
    /// guest within a frame or two, so this only delays the decision, it does
    /// not require sustained animation.
    public static let repaintFrameThreshold = 10

    /// True when the macOS cursor must be hidden because the guest already drew
    /// a cursor into the presented frame.
    public private(set) var hidesSystemCursor = false

    private var cursorPlaneUpdates = 0
    private var absolutePointerEvents = 0
    private var framesSincePointerEvent = 0

    public init() {}

    /// The guest issued `UPDATE_CURSOR`/`MOVE_CURSOR`: it drives the cursor
    /// plane, so this app composites the cursor and the macOS cursor stays.
    public mutating func noteCursorPlaneUpdate() {
        cursorPlaneUpdates += 1
        framesSincePointerEvent = 0
        hidesSystemCursor = false
    }

    /// An absolute pointer position was delivered to the guest.
    public mutating func noteAbsolutePointerEvent() {
        absolutePointerEvents += 1
        framesSincePointerEvent = 0
    }

    /// The guest presented a frame. A guest that draws its own cursor repaints
    /// in response to pointer events; one that uses the plane does not.
    public mutating func notePresentedFrame() {
        guard absolutePointerEvents > 0, cursorPlaneUpdates == 0 else { return }
        framesSincePointerEvent += 1
        if framesSincePointerEvent >= Self.repaintFrameThreshold {
            hidesSystemCursor = true
        }
    }

    /// A new presentation session starts from an unknown cursor source.
    public mutating func reset() {
        self = Self()
    }
}
