import Foundation
import Virtualization

struct OmarchyDisplaySize: Codable, Equatable {
    let width: Int
    let height: Int
}

struct OmarchyDynamicDisplayRoundTrip: Codable, Equatable {
    let observedAt: Date
    let guestBefore: OmarchyDisplaySize
    let guestAfter: OmarchyDisplaySize
    let hostViewAfter: OmarchyDisplaySize
}

enum OmarchyDynamicDisplayProbeState: Equatable {
    case notRun
    case running
    case passed(OmarchyDynamicDisplayRoundTrip)
    case failed(String)
}

// Automated implementation lives in Tools/OmarchyAcceptanceHarness.
