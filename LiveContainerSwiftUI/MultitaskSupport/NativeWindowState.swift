import Foundation

// Each attempt owns its callbacks. A late completion from an old guest must
// never terminate or complete a replacement launched in the same native scene.
struct LCNativeWindowState {
    enum Phase { case launching, running, terminated, closed }
    private(set) var phase: Phase = .launching
    private(set) var attempt = UUID()
    private(set) var startedAt: TimeInterval?
    private(set) var ranBeforeTermination = false
    private var automaticRestarts: [TimeInterval] = []
    private var recoveryAttempt: UUID?

    mutating func beginLaunch() {
        attempt = UUID()
        phase = .launching
        startedAt = nil
        ranBeforeTermination = false
    }

    @discardableResult
    mutating func initialized(attempt: UUID, succeeded: Bool, now: TimeInterval) -> Bool {
        guard self.attempt == attempt, phase == .launching else { return false }
        phase = succeeded ? .running : .terminated
        startedAt = succeeded ? now : nil
        return true
    }

    @discardableResult
    mutating func exited(attempt: UUID, now: TimeInterval) -> Bool {
        guard self.attempt == attempt, phase == .launching || phase == .running else { return false }
        ranBeforeTermination = phase == .running && startedAt.map { now - $0 >= 2 } == true
        phase = .terminated
        return true
    }

    mutating func close() { phase = .closed }

    mutating func reserveAutomaticRestart(now: TimeInterval) -> Bool {
        guard phase == .terminated, ranBeforeTermination, recoveryAttempt != attempt else { return false }
        automaticRestarts.removeAll { now - $0 >= 60 }
        guard automaticRestarts.count < 3 else { return false }
        automaticRestarts.append(now)
        recoveryAttempt = attempt
        return true
    }

    mutating func resetAutomaticRestarts() {
        automaticRestarts.removeAll()
        recoveryAttempt = nil
    }
}
