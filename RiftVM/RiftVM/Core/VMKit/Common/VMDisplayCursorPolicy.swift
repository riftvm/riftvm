import Foundation

/// Decides which cursor is visible while Custom VirGL runs in absolute pointer
/// mode.
///
/// Two sources can draw a cursor at once:
///
/// * virtio-gpu's cursor plane, which this view composites into its own layer
///   and hides in absolute mode, because the macOS cursor already sits at the
///   exact position the host feeds the guest; and
/// * the guest compositor's own cursor, painted into the scanout when it falls
///   back to software cursors. Those pixels cannot be hidden individually.
///
/// The macOS cursor is the pointer, because it is always at the true position:
/// a cursor the guest paints lags by the input round trip and the frame it is
/// painted into, so hiding the macOS cursor and trusting the guest's makes
/// clicks land where the pointer is, not where the cursor appears to be.
///
/// The policy therefore only decides whether the *system* cursor should be
/// hidden when the guest paints its own: that is a cosmetic duplicate, while a
/// missing pointer is not. It is sticky in both directions, and a cursor-plane
/// update proves the guest is not painting one, so the system cursor returns.
public struct VMGuestCursorPresentationPolicy: Equatable, Sendable {
    /// Presented frames accepted after an absolute pointer event before a guest
    /// that never touches the cursor plane is considered to paint its own
    /// cursor. Pointer motion repaints such a guest within a frame or two, so
    /// this only delays the decision, it does not require sustained animation.
    public static let repaintFrameThreshold = 10

    /// True when the guest paints a cursor into the scanout, so the system
    /// cursor would be a second, lagging pointer.
    public private(set) var hidesSystemCursor = false

    /// Diagnostics for the graphics log line.
    public private(set) var cursorPlaneUpdates = 0
    public private(set) var absolutePointerEvents = 0
    public private(set) var presentedFrames = 0

    private var framesSincePointerEvent = 0

    public init() {}

    /// The guest issued `UPDATE_CURSOR`/`MOVE_CURSOR`: it drives the cursor
    /// plane, which this view hides in absolute mode, so the macOS cursor stays
    /// as the pointer.
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
    /// in response to pointer events while never touching the cursor plane.
    public mutating func notePresentedFrame() {
        guard absolutePointerEvents > 0, cursorPlaneUpdates == 0 else { return }
        presentedFrames += 1
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
