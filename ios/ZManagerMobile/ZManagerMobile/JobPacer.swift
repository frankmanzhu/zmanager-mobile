import Foundation

/// Injectable pacing seam for debug/device-E2E scenarios: an artificial
/// delay between non-terminal polls, so a simulator job stays observably
/// running long enough for Maestro (or a person) to exercise cancellation.
/// Every production request uses NoOpJobPacer; DelayingJobPacer is compiled
/// only into DEBUG builds, so a release build fails to compile if it is ever
/// referenced outside a `#if DEBUG` block. Android's JobPacer additionally
/// has a `beforeStart()` hook, since Android's foreground-service handoff
/// has a separate pre-start delay; iOS starts the job immediately and only
/// ever paced the poll loop, so there is no equivalent hook here. See
/// Track 5 in docs/mobile-code-health-remediation-plan.md.
protocol JobPacer: Sendable {
    func beforePoll(isTerminal: Bool) async
}

struct NoOpJobPacer: JobPacer {
    func beforePoll(isTerminal: Bool) async {}
}

#if DEBUG
struct DelayingJobPacer: JobPacer {
    private static let maxDelayNanoseconds: UInt64 = 30_000_000_000

    let delayNanoseconds: UInt64

    func beforePoll(isTerminal: Bool) async {
        guard !isTerminal, delayNanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: min(delayNanoseconds, Self.maxDelayNanoseconds))
    }
}
#endif
