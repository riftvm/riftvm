import Foundation

/// Decides who owns the pointer while Custom VirGL runs in absolute pointer
/// mode.
///
/// Two sources can draw a cursor:
///
/// * virtio-gpu's cursor plane, which this view composites into its own layer,
///   positioned from the guest's own `MOVE_CURSOR` updates; and
/// * the guest compositor's own cursor, painted into the scanout when it falls
///   back to software cursors.
///
/// Either way the guest is drawing a cursor at the position the host feeds it,
/// and the macOS cursor is the one that must yield: it lags the guest's cursor
/// by the agent round trip, so leaving it visible shows two pointers — one
/// trailing the other — and every pointer move makes the window server redraw
/// it over the guest's frame. Blanking the macOS cursor leaves the single
/// cursor the guest draws.
///
/// The macOS cursor stays as the pointer until the guest proves it draws one:
/// the first cursor-plane update, or a repaint in response to absolute pointer
/// events (a software cursor). Before that the guest is still booting and has
/// no cursor to show.
public struct VMGuestCursorPresentationPolicy: Equatable, Sendable {
    /// Presented frames accepted after an absolute pointer event before a guest
    /// that never touches the cursor plane is considered to paint its own
    /// cursor. Pointer motion repaints such a guest within a frame or two, so
    /// this only delays the decision, it does not require sustained animation.
    public static let repaintFrameThreshold = 10

    /// True when the macOS cursor must be blanked because the guest draws the
    /// cursor itself, through the plane or into the scanout.
    public private(set) var hidesSystemCursor = false

    /// Diagnostics for the graphics log line.
    public private(set) var cursorPlaneUpdates = 0
    public private(set) var absolutePointerEvents = 0
    public private(set) var presentedFrames = 0

    private var framesSincePointerEvent = 0

    public init() {}

    /// The guest issued `UPDATE_CURSOR`/`MOVE_CURSOR`: it drives the cursor
    /// plane, which this view composites, so the macOS cursor yields to it.
    public mutating func noteCursorPlaneUpdate() {
        cursorPlaneUpdates += 1
        framesSincePointerEvent = 0
        hidesSystemCursor = true
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
