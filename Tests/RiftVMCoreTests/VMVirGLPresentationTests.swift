import Foundation
import Virtualization
import XCTest
@testable import RiftVMCore

final class VMVirGLPresentationTests: XCTestCase {
    func testVirGLPresentationEventFenceRejectsLateInvalidation() {
        var fence = VMGraphicsPresentationEventFence()
        XCTAssertTrue(fence.accept(1))
        XCTAssertTrue(fence.accept(3))
        XCTAssertFalse(fence.accept(2))
        XCTAssertFalse(fence.accept(3))
        XCTAssertEqual(fence.latestAcceptedSequence, 3)
    }

    func testVirGLPresentationHealthRequiresConsecutiveFailuresAndRecovers() {
        var health = VMGraphicsPresentationHealthTracker(failureThreshold: 3)

        XCTAssertEqual(health.record(success: false), .none)
        XCTAssertEqual(health.record(success: true), .none)
        XCTAssertEqual(health.record(success: false), .none)
        XCTAssertEqual(health.record(success: false), .none)
        XCTAssertEqual(health.record(success: false), .degraded)
        XCTAssertTrue(health.isDegraded)
        XCTAssertEqual(health.record(success: false), .none)
        XCTAssertEqual(health.record(success: true), .recovered)
        XCTAssertFalse(health.isDegraded)
        XCTAssertEqual(health.consecutiveFailures, 0)
    }

    func testVirGLPresentationLifecycleRejectsLateCompletionAfterStop() {
        var lifecycle = VMGraphicsPresentationLifecycle()
        let token = lifecycle.tokenForPresentation()

        XCTAssertNotNil(token)
        XCTAssertTrue(lifecycle.acceptsCompletion(token: token!))
        lifecycle.stop()
        XCTAssertNil(lifecycle.tokenForPresentation())
        XCTAssertFalse(lifecycle.acceptsCompletion(token: token!))
    }

    func testVirGLPresentationLifecycleStopIsIdempotent() {
        var lifecycle = VMGraphicsPresentationLifecycle()
        lifecycle.stop()
        let stoppedGeneration = lifecycle.generation

        lifecycle.stop()
        XCTAssertEqual(lifecycle.generation, stoppedGeneration)
        XCTAssertTrue(lifecycle.isStopped)
    }

    func testCustomVirGLIsTheOnlyBackend() {
        XCTAssertEqual(VMGraphicsBackendKind.customVirGL.displayName, "Custom VirGL")
        XCTAssertEqual(VMGraphicsBackendKind(rawValue: "appleVirtio"), nil, "Apple Virtio is no longer a backend")
        XCTAssertEqual(VMGraphicsBackendKind(rawValue: "appleMac"), nil, "macOS graphics is no longer a backend")
    }

    func testGuestInputReadinessIsScopedToMachineIdentity() throws {
        let suiteName = "VMLinuxFeatureConfigurationTests.readiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = Data("first-machine".utf8)
        let second = Data("second-machine".utf8)

        XCTAssertFalse(VMGuestAgentEnrollmentStore.isInputReady(machineIdentifierData: first, defaults: defaults))
        VMGuestAgentEnrollmentStore.markInputReady(machineIdentifierData: first, defaults: defaults)
        XCTAssertTrue(VMGuestAgentEnrollmentStore.isInputReady(machineIdentifierData: first, defaults: defaults))
        XCTAssertFalse(VMGuestAgentEnrollmentStore.isInputReady(machineIdentifierData: second, defaults: defaults))
    }
}
