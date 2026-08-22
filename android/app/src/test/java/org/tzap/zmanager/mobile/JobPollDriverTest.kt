package org.tzap.zmanager.mobile

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.tzap.zmanager.mobile.bridge.generated.MobileJobKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobStatus
import org.tzap.zmanager.mobile.bridge.generated.PollJobEventsResult

class JobPollDriverTest {
    // Regression test for a real bug found during a critical review of Track
    // 8 (docs/mobile-code-health-remediation-plan.md): the backoff variable
    // was doubled before its first use, so the first non-terminal poll
    // always waited ~200ms instead of the documented/named 100ms initial
    // value. This asserts the actual observed gaps, not just that the loop
    // eventually terminates.
    @Test
    fun backoffStartsAtTheInitialValueThenDoubles() = runBlocking {
        var pollCount = 0
        val pollTimestampsMillis = mutableListOf<Long>()
        val start = System.nanoTime()

        pollJobUntilTerminal(
            poll = { cursor ->
                pollTimestampsMillis += (System.nanoTime() - start) / 1_000_000
                pollCount += 1
                PollJobEventsResult(
                    jobId = "job",
                    kind = MobileJobKind.ZIP_EXTRACT,
                    status = if (pollCount >= 3) MobileJobStatus.COMPLETED else MobileJobStatus.RUNNING,
                    events = emptyList(),
                    nextCursor = cursor + 1UL,
                    minRetainedSequence = 0UL,
                    isTerminal = pollCount >= 3,
                    terminalSummary = null
                )
            },
            onEvent = {},
            onTerminal = { it }
        )

        assertTrue("expected exactly 3 polls, got $pollCount", pollCount == 3)
        val firstGapMillis = pollTimestampsMillis[1] - pollTimestampsMillis[0]
        val secondGapMillis = pollTimestampsMillis[2] - pollTimestampsMillis[1]
        assertTrue(
            "expected the gap before the 2nd poll to be close to the 100ms initial backoff, was ${firstGapMillis}ms",
            firstGapMillis in 70..170
        )
        assertTrue(
            "expected the gap before the 3rd poll to be close to the 200ms second backoff, was ${secondGapMillis}ms",
            secondGapMillis in 170..320
        )
    }
}
