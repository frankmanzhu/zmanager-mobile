package org.tzap.zmanager.mobile

import kotlinx.coroutines.delay
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEvent
import org.tzap.zmanager.mobile.bridge.generated.PollJobEventsResult

private const val JOB_POLL_BACKOFF_INITIAL_MILLIS = 100L
private const val JOB_POLL_BACKOFF_MAX_MILLIS = 1_000L

/**
 * Cursor/poll/backoff skeleton shared by every job kind's completion loop
 * (extraction, creation). Terminal handling stays with each caller since it
 * differs per job kind (commit-to-destination for extraction, volume-path
 * assembly for creation); this covers only the part that was identical
 * across all of them. Backoff starts at [JOB_POLL_BACKOFF_INITIAL_MILLIS] and
 * doubles up to [JOB_POLL_BACKOFF_MAX_MILLIS] while a poll returns no new
 * event, resetting on every event, so short jobs stay responsive and long
 * jobs stop waking the CPU every 150ms. See Track 8 in
 * docs/mobile-code-health-remediation-plan.md. [pacer] is the debug/E2E
 * pacing seam described in Track 5; production callers use the default
 * [NoOpJobPacer].
 */
suspend fun <T> pollJobUntilTerminal(
    poll: (cursor: ULong) -> PollJobEventsResult,
    pacer: JobPacer = NoOpJobPacer,
    onEvent: (MobileJobEvent) -> Unit,
    onTerminal: (PollJobEventsResult) -> T
): T {
    var cursor = 0UL
    var backoffMillis = JOB_POLL_BACKOFF_INITIAL_MILLIS
    while (true) {
        val update = poll(cursor)
        cursor = update.nextCursor
        val event = update.events.lastOrNull()
        if (event != null) {
            onEvent(event)
            backoffMillis = JOB_POLL_BACKOFF_INITIAL_MILLIS
        }
        pacer.beforePoll(update.isTerminal)
        if (update.isTerminal) {
            return onTerminal(update)
        }
        // Use the current backoff for this wait, then grow it for the next
        // one only if this poll was silent — growing before the first use
        // would mean the "initial" backoff is never actually observed.
        delay(backoffMillis)
        if (event == null) {
            backoffMillis = (backoffMillis * 2).coerceAtMost(JOB_POLL_BACKOFF_MAX_MILLIS)
        }
    }
}
