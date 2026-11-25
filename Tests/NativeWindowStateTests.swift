import Foundation

@main
enum NativeWindowStateTests {
    static func main() {
        var state = LCNativeWindowState()
        let first = state.attempt
        precondition(state.initialized(attempt: first, succeeded: true, now: 0))
        precondition(!state.initialized(attempt: first, succeeded: true, now: 1))
        precondition(state.exited(attempt: first, now: 10))
        precondition(state.reserveAutomaticRestart(now: 10))
        precondition(!state.reserveAutomaticRestart(now: 10.5))
        state.beginLaunch()
        precondition(!state.exited(attempt: first, now: 11))
        precondition(!state.initialized(attempt: first, succeeded: false, now: 11))
        precondition(state.phase == .launching)

        // A failed launch and an immediate crash leave a manual retry screen.
        precondition(state.initialized(attempt: state.attempt, succeeded: false, now: 12))
        precondition(!state.reserveAutomaticRestart(now: 20))
        state.beginLaunch()
        state.initialized(attempt: state.attempt, succeeded: true, now: 21)
        state.exited(attempt: state.attempt, now: 22)
        precondition(!state.reserveAutomaticRestart(now: 25))

        // A repeated crash after startup must also stop, without disabling a manual retry.
        state.resetAutomaticRestarts()
        for index in 0..<4 {
            state.beginLaunch()
            state.initialized(attempt: state.attempt, succeeded: true, now: Double(index * 4))
            state.exited(attempt: state.attempt, now: Double(index * 4 + 3))
            precondition(state.reserveAutomaticRestart(now: Double(index * 4 + 3)) == (index < 3))
        }
        precondition(state.reserveAutomaticRestart(now: 70))
        state.close()
        precondition(!state.exited(attempt: state.attempt, now: 75))
        precondition(!state.reserveAutomaticRestart(now: 75))
        state.resetAutomaticRestarts()
        state.beginLaunch()
        precondition(state.initialized(attempt: state.attempt, succeeded: true, now: 80))
        let oldRequest = UUID(), newRequest = UUID()
        MultitaskManager.registerMultitaskContainer(container: "guest", request: oldRequest)
        MultitaskManager.registerMultitaskContainer(container: "guest", request: newRequest)
        MultitaskManager.unregisterMultitaskContainer(container: "guest", request: oldRequest)
        precondition(MultitaskManager.isUsing(container: "guest"))
        MultitaskManager.unregisterMultitaskContainer(container: "guest", request: newRequest)
        precondition(!MultitaskManager.isMultitasking())
        print("Native window recovery tests passed (stale callbacks, manual close, startup failures and crash loops).")
    }
}
