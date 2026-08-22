import Foundation

/// Cursor/poll/backoff skeleton shared by every job kind's completion loop
/// (extraction, creation). Terminal handling stays with each caller since it
/// differs per job kind (commit-to-destination for extraction, volume-path
/// assembly for creation); this covers only the part that was identical
/// across both. Backoff starts at 100ms and doubles up to 1s while a poll
/// returns no new event, resetting on every event, so short jobs stay
/// responsive and long jobs stop waking the CPU every 150ms. Mirrors
/// Android's pollJobUntilTerminal. See Track 8 in
/// docs/mobile-code-health-remediation-plan.md.
enum JobPollDriver {
    private static let backoffInitialNanoseconds: UInt64 = 100_000_000
    private static let backoffMaxNanoseconds: UInt64 = 1_000_000_000

    static func pollUntilTerminal<Result>(
        pacer: any JobPacer = NoOpJobPacer(),
        poll: (UInt64) throws -> PollJobEventsResult,
        onEvent: (MobileJobEvent) -> Void,
        onTerminal: (PollJobEventsResult) -> Result
    ) async throws -> Result {
        var cursor: UInt64 = 0
        var backoffNanoseconds = backoffInitialNanoseconds
        while true {
            let update = try poll(cursor)
            cursor = update.nextCursor
            let event = update.events.last
            if let event {
                onEvent(event)
                backoffNanoseconds = backoffInitialNanoseconds
            }
            await pacer.beforePoll(isTerminal: update.isTerminal)
            if update.isTerminal {
                return onTerminal(update)
            }
            // Use the current backoff for this wait, then grow it for the
            // next one only if this poll was silent — growing before the
            // first use would mean the "initial" backoff is never actually
            // observed.
            try await Task.sleep(nanoseconds: backoffNanoseconds)
            if event == nil {
                backoffNanoseconds = min(backoffNanoseconds * 2, backoffMaxNanoseconds)
            }
        }
    }
}
