import CoreGraphics
import Foundation

/// What the host shows as the pointer over the guest display.
public enum VMHostCursorChoice: Equatable, Sendable {
    /// The ordinary macOS arrow: outside the guest image, or before the guest
    /// has ever used its cursor plane (firmware, the boot console).
    case system
    /// The guest's own cursor image, set as the macOS cursor.
    case guestImage
    /// No cursor: the guest hid its pointer, or the pointer is captured and the
    /// guest cursor is composited instead.
    case hidden
}

/// Decides which cursor is visible over Custom VirGL, from facts only.
///
/// Omarchy's compositor draws its pointer on virtio-gpu's cursor plane, so the
/// guest hands the host the exact image, hotspot and visibility it wants. The
/// host shows that image *as the macOS cursor*: it sits at the true pointer
/// position with no input round trip or frame of lag, it carries the guest's
/// shape (I-beam, resize arrows), and there is only ever one of it. Nothing here
/// guesses from frame counts or timing.
public struct VMGuestCursorState: Equatable, Sendable {
    /// The guest has driven the cursor plane at least once this session.
    public private(set) var planeSeen = false
    /// The guest's latest cursor-plane update shows a cursor.
    public private(set) var visible = false
    /// When the plane last showed a cursor, on the caller's clock.
    private var lastShownAt: TimeInterval?

    /// A hide arriving hot on the heels of a show is the off-phase of the
    /// blink the compositor's legacy-KMS path produces on this backend — on
    /// a real display both land inside one refresh and are invisible, but
    /// applied literally they flickered the pointer four to eight times a
    /// second while it moved and left it hidden the moment it stopped
    /// (measured: 89 of 91 hides in a real session arrived within 22 ms of a
    /// show). An intent hide — typing with hide_on_key_press, a video player
    /// — arrives at rest, long after the last show, and still applies.
    public static let hideDebounce: TimeInterval = 0.1

    public init() {}

    /// The guest issued `UPDATE_CURSOR` or `MOVE_CURSOR` at `now`, on any
    /// steady clock the caller keeps using for every call.
    public mutating func noteCursorPlane(visible: Bool, at now: TimeInterval) {
        planeSeen = true
        if visible {
            self.visible = true
            lastShownAt = now
            return
        }
        if let lastShownAt, now - lastShownAt < Self.hideDebounce { return }
        self.visible = false
    }

    /// A new presentation session starts from an unknown cursor.
    public mutating func reset() {
        self = Self()
    }

    /// The macOS cursor to show for a pointer at a given place.
    public func hostCursor(
        absolutePointer: Bool,
        captured: Bool,
        insideGuestImage: Bool
    ) -> VMHostCursorChoice {
        if captured { return .hidden }
        guard absolutePointer, insideGuestImage, planeSeen else { return .system }
        return visible ? .guestImage : .hidden
    }

    /// Whether the composited cursor layer is shown. Only a captured, relative
    /// pointer needs it: the macOS cursor is hidden and frozen then, so the guest
    /// cursor has to be drawn into the view.
    public func showsCursorLayer(absolutePointer: Bool, captured: Bool) -> Bool {
        !absolutePointer && captured && planeSeen && visible
    }

    /// The macOS cursor's size and hotspot, in points, for a guest cursor image
    /// and hotspot in guest pixels shown at `scale` points per guest pixel. The
    /// hotspot stays inside the image, as `NSCursor` requires.
    public static func hostCursorGeometry(
        imagePixels: CGSize,
        hotspotPixels: CGPoint,
        scale: CGFloat
    ) -> (size: CGSize, hotSpot: CGPoint) {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let size = CGSize(width: imagePixels.width * scale, height: imagePixels.height * scale)
        let hotSpot = CGPoint(
            x: min(max(0, hotspotPixels.x * scale), max(0, size.width - 1)),
            y: min(max(0, hotspotPixels.y * scale), max(0, size.height - 1))
        )
        return (size, hotSpot)
    }
}
