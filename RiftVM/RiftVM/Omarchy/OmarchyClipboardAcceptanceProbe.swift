import AppKit
import CryptoKit
import Foundation

struct OmarchyClipboardRoundTrip: Codable, Equatable {
    let observedAt: Date
    let advertisedCapabilities: Set<String>
    let hostToGuestTextSHA256: String
    let guestToHostTextSHA256: String
    let hostToGuestImageSHA256: String
    let guestToHostImageSHA256: String
}

enum OmarchyClipboardProbeState: Equatable {
    case notRun
    case running
    case passed(OmarchyClipboardRoundTrip)
    case failed(String)
}

// Automated implementation lives in Tools/OmarchyAcceptanceHarness.
