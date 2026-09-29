import CryptoKit
import XCTest
@testable import RiftVMCore

/// The clipboard capture of a Host and an Agent that are updated
/// independently: every combination of old and new must behave as the old
/// pair did.
final class VMOmarchyClipboardCaptureTests: XCTestCase {
    private static let textMIME = "text/plain;charset=utf-8"
    private static let imageMIME = "image/png"
    private static let path = ".riftvm/.riftvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt"

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Wire format

    func testCaptureWithoutKnownDigestEncodesExactlyTheReleasedRequest() throws {
        let request = VMOmarchyClipboardRequest(
            relativePath: Self.path, mimeType: Self.textMIME, byteCount: 0, sha256: ""
        )
        let encoded = try object(JSONEncoder().encode(request))
        XCTAssertEqual(Set(encoded.keys), ["relativePath", "mimeType", "byteCount", "sha256"])
        XCTAssertEqual(encoded["relativePath"] as? String, Self.path)
        XCTAssertEqual(encoded["mimeType"] as? String, Self.textMIME)
        XCTAssertEqual(encoded["byteCount"] as? Int, 0)
        XCTAssertEqual(encoded["sha256"] as? String, "")
    }

    func testKnownDigestIsAnAdditionalOptionalField() throws {
        let known = Self.sha256("copied in the guest")
        let request = VMOmarchyClipboardRequest(
            relativePath: Self.path, mimeType: Self.textMIME, byteCount: 0, sha256: "",
            knownSHA256: known
        )
        let data = try JSONEncoder().encode(request)
        let encoded = try object(data)
        XCTAssertEqual(
            Set(encoded.keys), ["relativePath", "mimeType", "byteCount", "sha256", "knownSHA256"]
        )
        XCTAssertEqual(encoded["knownSHA256"] as? String, known)
        XCTAssertEqual(try JSONDecoder().decode(VMOmarchyClipboardRequest.self, from: data), request)

        // An old Agent decodes only the fields it knows; they are unchanged.
        struct ReleasedRequest: Decodable, Equatable {
            let relativePath: String
            let mimeType: String
            let byteCount: UInt64?
            let sha256: String?
        }
        XCTAssertEqual(
            try JSONDecoder().decode(ReleasedRequest.self, from: data),
            ReleasedRequest(relativePath: Self.path, mimeType: Self.textMIME, byteCount: 0, sha256: "")
        )
    }

    func testRequestFromAReleasedHostDecodesWithoutAKnownDigest() throws {
        let released = Data(
            #"{"relativePath":"\#(Self.path)","mimeType":"image/png","byteCount":0,"sha256":""}"#.utf8
        )
        let request = try JSONDecoder().decode(VMOmarchyClipboardRequest.self, from: released)
        XCTAssertNil(request.knownSHA256)
        XCTAssertEqual(request.mimeType, Self.imageMIME)
    }

    func testResponseFromAReleasedAgentIsAFullCapture() throws {
        let digest = Self.sha256("copied in the guest")
        let released = Data(
            #"{"success":true,"message":"Guest clipboard captured.","byteCount":19,"sha256":"\#(digest)"}"#.utf8
        )
        let result = try JSONDecoder().decode(VMOmarchyClipboardResult.self, from: released)
        XCTAssertNil(result.unchanged)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.byteCount, 19)
        XCTAssertEqual(result.sha256, digest)
        // The Host named this very digest; the old Agent staged the item
        // anyway and the Host must read it.
        XCTAssertFalse(result.confirmsUnchanged(knownSHA256: digest))

        let failure = try JSONDecoder().decode(
            VMOmarchyClipboardResult.self,
            from: Data(#"{"success":false,"message":"could not read the Wayland clipboard"}"#.utf8)
        )
        XCTAssertNil(failure.unchanged)
        XCTAssertNil(failure.sha256)
        XCTAssertFalse(failure.confirmsUnchanged(knownSHA256: digest))
    }

    func testResponseFromANewAgentDecodesInAReleasedHost() throws {
        // The released Host decodes this type; unknown keys are ignored.
        struct ReleasedResult: Decodable, Equatable {
            let success: Bool
            let message: String
            let byteCount: UInt64?
            let sha256: String?
        }
        let digest = Self.sha256("copied in the guest")
        let captured = Data(
            #"{"success":true,"message":"Guest clipboard captured.","byteCount":19,"sha256":"\#(digest)"}"#.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ReleasedResult.self, from: captured),
            ReleasedResult(
                success: true, message: "Guest clipboard captured.", byteCount: 19, sha256: digest
            )
        )
    }

    func testUnchangedAnswerIsTrustedOnlyForTheDigestThatWasAsked() throws {
        let digest = Self.sha256("copied in the guest")
        let data = Data(
            #"{"success":true,"message":"Guest clipboard unchanged.","byteCount":19,"sha256":"\#(digest)","unchanged":true}"#.utf8
        )
        let result = try JSONDecoder().decode(VMOmarchyClipboardResult.self, from: data)
        XCTAssertEqual(result.unchanged, true)
        XCTAssertTrue(result.confirmsUnchanged(knownSHA256: digest))
        XCTAssertFalse(result.confirmsUnchanged(knownSHA256: nil))
        XCTAssertFalse(result.confirmsUnchanged(knownSHA256: ""))
        XCTAssertFalse(result.confirmsUnchanged(knownSHA256: Self.sha256("another item")))
        XCTAssertFalse(
            VMOmarchyClipboardResult(success: false, message: "x", sha256: digest, unchanged: true)
                .confirmsUnchanged(knownSHA256: digest)
        )
        XCTAssertFalse(
            VMOmarchyClipboardResult(success: true, message: "x", sha256: nil, unchanged: true)
                .confirmsUnchanged(knownSHA256: digest)
        )
        XCTAssertFalse(
            VMOmarchyClipboardResult(success: true, message: "x", sha256: digest, unchanged: false)
                .confirmsUnchanged(knownSHA256: digest)
        )
    }

    // MARK: Host and Agent combinations

    /// The Guest selection: the items it offers, by MIME type.
    private struct Selection {
        var items: [String: String] = [:]
    }

    /// An Agent as the Host sees it. The released one stages every capture;
    /// the new one answers `unchanged` for the digest it is asked about.
    private struct Agent {
        let understandsKnownDigest: Bool
        var staged = 0

        mutating func capture(
            _ selection: Selection, mimeType: String, knownSHA256: String?
        ) -> (probe: VMOmarchyClipboardCaptureMemory.Probe, item: String?) {
            guard let item = selection.items[mimeType] else { return (.failed, nil) }
            let digest = VMOmarchyClipboardCaptureTests.sha256(item)
            if understandsKnownDigest, knownSHA256 == digest {
                return (.unchanged, nil)
            }
            staged += 1
            return (.captured(sha256: digest, usable: !item.hasPrefix("unusable")), item)
        }
    }

    /// The Host bridge around the capture: what it publishes and when.
    private struct Host {
        let remembers: Bool
        var memory = VMOmarchyClipboardCaptureMemory()
        var lastSent: String?
        var lastReceived: String?
        var published: [String] = []
        var probes = 0

        /// One capture tick, image first, exactly as the bridge orders it.
        mutating func tick(_ selection: Selection, agent: inout Agent) {
            var captured: String?
            memory.beginCapture()
            probing: for mimeType in [imageMIME, textMIME] {
                probes += 1
                let answer = agent.capture(
                    selection, mimeType: mimeType,
                    knownSHA256: remembers ? memory.knownSHA256(for: mimeType) : nil
                )
                switch memory.resolve(answer.probe, for: mimeType) {
                case .unchanged:
                    break probing
                case .captured:
                    captured = answer.item.map { "\(mimeType):\($0)" }
                    break probing
                case .tryNext:
                    continue
                }
            }
            memory.endCapture()
            if let captured, captured != lastSent, captured != lastReceived {
                published.append(captured)
                lastReceived = captured
            }
        }

        /// The user copied on the Mac and the item reached the Guest.
        mutating func send(_ item: String, mimeType: String, to selection: inout Selection) {
            memory.reset()
            selection.items = [mimeType: item]
            lastSent = "\(mimeType):\(item)"
            memory.reset()
        }
    }

    private enum Step {
        case guestCopies([String: String])
        case hostSends(String, mimeType: String)
        case tick
    }

    private struct Outcome: Equatable {
        let published: [String]
        let staged: Int
    }

    private func run(_ steps: [Step], hostRemembers: Bool, agentUnderstands: Bool) -> Outcome {
        var selection = Selection()
        var agent = Agent(understandsKnownDigest: agentUnderstands)
        var host = Host(remembers: hostRemembers)
        for step in steps {
            switch step {
            case let .guestCopies(items): selection.items = items
            case let .hostSends(item, mimeType): host.send(item, mimeType: mimeType, to: &selection)
            case .tick: host.tick(selection, agent: &agent)
            }
        }
        return Outcome(published: host.published, staged: agent.staged)
    }

    private static let scenarios: [(name: String, steps: [Step])] = [
        ("idle text", [.guestCopies([textMIME: "a"]), .tick, .tick, .tick, .tick]),
        ("empty selection", [.tick, .tick, .guestCopies([textMIME: "a"]), .tick, .tick]),
        ("text then other text", [
            .guestCopies([textMIME: "a"]), .tick, .tick,
            .guestCopies([textMIME: "b"]), .tick, .tick,
        ]),
        ("text, image, the same text again", [
            .guestCopies([textMIME: "a"]), .tick, .tick,
            .guestCopies([imageMIME: "png"]), .tick, .tick,
            .guestCopies([textMIME: "a"]), .tick, .tick,
        ]),
        ("image, text, the same image again", [
            .guestCopies([imageMIME: "png"]), .tick, .tick,
            .guestCopies([textMIME: "a"]), .tick,
            .guestCopies([imageMIME: "png"]), .tick, .tick,
        ]),
        ("image with a text alternative", [
            .guestCopies([imageMIME: "png", textMIME: "a"]), .tick, .tick,
            .guestCopies([textMIME: "a"]), .tick, .tick,
            .guestCopies([imageMIME: "png", textMIME: "a"]), .tick, .tick,
        ]),
        ("undecodable image falls back to text", [
            .guestCopies([imageMIME: "unusable png", textMIME: "a"]), .tick, .tick, .tick,
            .guestCopies([imageMIME: "unusable png", textMIME: "b"]), .tick, .tick,
            .guestCopies([imageMIME: "png", textMIME: "b"]), .tick, .tick,
        ]),
        ("unusable text", [
            .guestCopies([textMIME: "unusable bytes"]), .tick, .tick,
            .guestCopies([textMIME: "a"]), .tick, .tick,
        ]),
        ("host item is not echoed back", [
            .hostSends("from the mac", mimeType: textMIME), .tick, .tick,
            .guestCopies([textMIME: "a"]), .tick, .tick,
        ]),
        ("guest copies the earlier item right after the host sent one", [
            .guestCopies([textMIME: "a"]), .tick, .tick,
            .hostSends("from the mac", mimeType: textMIME),
            .guestCopies([textMIME: "a"]), .tick, .tick,
        ]),
        ("guest copies the item the host sent before", [
            .hostSends("first", mimeType: textMIME), .tick,
            .hostSends("second", mimeType: textMIME), .tick,
            .guestCopies([textMIME: "first"]), .tick, .tick,
        ]),
        ("received item, host sends, guest copies the received item again", [
            .guestCopies([textMIME: "a"]), .tick,
            .hostSends("from the mac", mimeType: imageMIME), .tick, .tick,
            .guestCopies([textMIME: "a"]), .tick, .tick,
            .guestCopies([textMIME: "b"]), .tick,
            .guestCopies([textMIME: "a"]), .tick,
        ]),
        ("selection disappears and returns", [
            .guestCopies([textMIME: "a"]), .tick, .tick,
            .guestCopies([:]), .tick, .tick,
            .guestCopies([textMIME: "a"]), .tick, .tick,
            .guestCopies([textMIME: "b"]), .tick,
            .guestCopies([:]), .tick,
            .guestCopies([textMIME: "a"]), .tick,
        ]),
    ]

    func testEveryHostAndAgentCombinationPublishesWhatTheReleasedPairPublishes() {
        for scenario in Self.scenarios {
            let released = run(scenario.steps, hostRemembers: false, agentUnderstands: false)
            for (host, agent) in [(true, false), (false, true), (true, true)] {
                let outcome = run(scenario.steps, hostRemembers: host, agentUnderstands: agent)
                XCTAssertEqual(
                    outcome.published, released.published,
                    "\(scenario.name): new host=\(host) new agent=\(agent)"
                )
                if !(host && agent) {
                    // One side is old: every capture is staged, as before.
                    XCTAssertEqual(
                        outcome.staged, released.staged,
                        "\(scenario.name): new host=\(host) new agent=\(agent)"
                    )
                } else {
                    XCTAssertLessThanOrEqual(outcome.staged, released.staged, scenario.name)
                }
            }
        }
    }

    func testNewHostAndAgentStageAnIdleSelectionOnce() {
        let idle = Self.scenarios[0].steps
        XCTAssertEqual(run(idle, hostRemembers: false, agentUnderstands: false).staged, 4)
        XCTAssertEqual(run(idle, hostRemembers: true, agentUnderstands: true).staged, 1)
        let image: [Step] = [.guestCopies([Self.imageMIME: "png", Self.textMIME: "a"]), .tick, .tick, .tick]
        XCTAssertEqual(run(image, hostRemembers: true, agentUnderstands: true).staged, 1)
    }

    // MARK: Memory

    func testMemoryNamesOnlyWhatThePreviousCaptureProbed() {
        var memory = VMOmarchyClipboardCaptureMemory()
        XCTAssertNil(memory.knownSHA256(for: Self.textMIME))

        memory.beginCapture()
        XCTAssertEqual(memory.resolve(.failed, for: Self.imageMIME), .tryNext)
        XCTAssertEqual(memory.resolve(.captured(sha256: "text-1", usable: true), for: Self.textMIME), .captured)
        memory.endCapture()
        XCTAssertNil(memory.knownSHA256(for: Self.imageMIME))
        XCTAssertEqual(memory.knownSHA256(for: Self.textMIME), "text-1")

        // An image became the result: text was not probed and is forgotten.
        memory.beginCapture()
        XCTAssertEqual(memory.resolve(.captured(sha256: "image-1", usable: true), for: Self.imageMIME), .captured)
        memory.endCapture()
        XCTAssertEqual(memory.knownSHA256(for: Self.imageMIME), "image-1")
        XCTAssertNil(memory.knownSHA256(for: Self.textMIME))

        memory.beginCapture()
        XCTAssertEqual(memory.resolve(.unchanged, for: Self.imageMIME), .unchanged)
        memory.endCapture()
        XCTAssertEqual(memory.knownSHA256(for: Self.imageMIME), "image-1")

        memory.reset()
        XCTAssertNil(memory.knownSHA256(for: Self.imageMIME))
        XCTAssertEqual(memory, VMOmarchyClipboardCaptureMemory())
    }

    func testUnchangedUnusableItemIsSkippedWithoutBeingTheResult() {
        var memory = VMOmarchyClipboardCaptureMemory()
        memory.beginCapture()
        XCTAssertEqual(memory.resolve(.captured(sha256: "broken", usable: false), for: Self.imageMIME), .tryNext)
        XCTAssertEqual(memory.resolve(.captured(sha256: "text-1", usable: true), for: Self.textMIME), .captured)
        memory.endCapture()
        XCTAssertEqual(memory.knownSHA256(for: Self.imageMIME), "broken")

        memory.beginCapture()
        XCTAssertEqual(memory.resolve(.unchanged, for: Self.imageMIME), .tryNext)
        XCTAssertEqual(memory.resolve(.unchanged, for: Self.textMIME), .unchanged)
        memory.endCapture()
    }

    func testUnchangedWithoutARememberedItemIsNotAResult() {
        var memory = VMOmarchyClipboardCaptureMemory()
        memory.beginCapture()
        XCTAssertEqual(memory.resolve(.unchanged, for: Self.imageMIME), .tryNext)
        XCTAssertEqual(memory.resolve(.unchanged, for: Self.textMIME), .tryNext)
        memory.endCapture()
        XCTAssertNil(memory.knownSHA256(for: Self.textMIME))
    }

    func testFailedProbeForgetsTheItem() {
        var memory = VMOmarchyClipboardCaptureMemory()
        memory.beginCapture()
        _ = memory.resolve(.failed, for: Self.imageMIME)
        _ = memory.resolve(.captured(sha256: "text-1", usable: true), for: Self.textMIME)
        memory.endCapture()
        memory.beginCapture()
        _ = memory.resolve(.failed, for: Self.imageMIME)
        XCTAssertEqual(memory.resolve(.failed, for: Self.textMIME), .tryNext)
        memory.endCapture()
        XCTAssertNil(memory.knownSHA256(for: Self.textMIME))
    }
}

private let imageMIME = "image/png"
private let textMIME = "text/plain;charset=utf-8"
