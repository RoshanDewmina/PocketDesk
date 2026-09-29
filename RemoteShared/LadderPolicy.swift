import Foundation

/// Placeholder engine: stays at rung 0. W4 replaces it with the real policy (StreamLadder.swift
/// states the rules); the host wiring compiles against this shape.
struct LadderPolicy: LadderEngine {
    private(set) var state: LadderState

    init(targetFPS: Int) {
        state = LadderState.rungs(targetFPS: targetFPS)[0]
    }

    mutating func evaluate(_ inputs: LadderInputs, at time: TimeInterval) -> LadderState? {
        nil
    }
}

/// Placeholder busy policy: always "ok". W4 replaces it (BusyState.swift states the rules).
struct BusyPolicy {
    private(set) var state = BusyState.ok

    mutating func evaluate(ladder: LadderState, inputs: LadderInputs, at time: TimeInterval) -> BusyState? {
        nil
    }
}
