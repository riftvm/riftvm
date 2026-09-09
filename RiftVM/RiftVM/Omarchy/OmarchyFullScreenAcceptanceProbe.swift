import AppKit
import Foundation

struct OmarchyFullScreenTransitionState: Equatable {
    private(set) var enteredAt: Date?
    private(set) var exitedAt: Date?

    mutating func observeEntered(at date: Date) -> Bool {
        guard enteredAt == nil, exitedAt == nil else { return false }
        enteredAt = date
        return true
    }

    mutating func observeExited(at date: Date) -> Bool {
        guard enteredAt != nil, exitedAt == nil else { return false }
        exitedAt = date
        return true
    }
}

// Automated implementation lives in Tools/OmarchyAcceptanceHarness.
