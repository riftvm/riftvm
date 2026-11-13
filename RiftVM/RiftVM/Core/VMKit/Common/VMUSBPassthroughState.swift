import Foundation

/// Tracks asynchronous USB operations without retaining hardware. Completions
/// from a released assignment or an old VM may clean up their own device, but
/// must never claim a new assignment or clear its pending operation.
public struct VMUSBPassthroughState {
    public struct Attachment: Equatable {
        fileprivate let id: UInt64
        fileprivate let session: UUID
        fileprivate let assignment: UUID
        fileprivate let operation = UUID()
    }
    private var session = UUID()
    private var active = false
    private var assignments: [UInt64: UUID] = [:]
    private var attaching: [UInt64: Attachment] = [:]
    private var detaching: [UInt64: UUID] = [:]

    public init() {}

    @discardableResult
    public mutating func start() -> UUID {
        session = UUID()
        active = true
        assignments.removeAll()
        attaching.removeAll()
        detaching.removeAll()
        return session
    }

    public mutating func stop() {
        active = false
        assignments.removeAll()
    }

    public func isCurrentSession(_ token: UUID) -> Bool { active && session == token }

    public mutating func assign(_ id: UInt64) { assignments[id] = UUID() }
    public mutating func release(_ id: UInt64) { assignments.removeValue(forKey: id) }

    public mutating func beginAttachment(_ id: UInt64) -> Attachment? {
        guard active, let assignment = assignments[id], attaching[id] == nil, detaching[id] == nil else { return nil }
        let token = Attachment(id: id, session: session, assignment: assignment)
        attaching[id] = token
        return token
    }

    /// True only when this operation still belongs to the active assignment.
    public mutating func finishAttachment(_ token: Attachment) -> Bool {
        guard attaching[token.id] == token else { return false }
        attaching.removeValue(forKey: token.id)
        return active && session == token.session && assignments[token.id] == token.assignment
    }

    public mutating func beginDetachment(_ id: UInt64) -> UUID {
        let token = UUID()
        detaching[id] = token
        return token
    }

    /// Old completions must not unblock a newer detach for the same registry ID.
    public mutating func finishDetachment(_ id: UInt64, token: UUID) -> Bool {
        guard detaching[id] == token else { return false }
        detaching.removeValue(forKey: id)
        return active
    }
}
