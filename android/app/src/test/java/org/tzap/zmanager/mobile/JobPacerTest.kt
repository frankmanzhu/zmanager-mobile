package org.tzap.zmanager.mobile

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test

class JobPacerTest {
    @Test
    fun noOpJobPacerNeverDelaysAndHasNoTimeoutOverride() = runBlocking {
        val start = System.nanoTime()
        NoOpJobPacer.beforeStart()
        NoOpJobPacer.beforePoll(isTerminal = false)
        val elapsedMillis = (System.nanoTime() - start) / 1_000_000
        assertTrue("expected no delay, elapsed=${elapsedMillis}ms", elapsedMillis < 40L)
        assertTrue(NoOpJobPacer.timeoutBudgetMillis == null)
    }

    @Test
    fun delayingJobPacerDelaysBeforeNonTerminalPollsAndStartOnly() = runBlocking {
        val pacer = DelayingJobPacer(delayMillis = 50L, timeoutBudgetMillis = 1_000L)

        val startElapsed = timeMillis { pacer.beforeStart() }
        assertTrue("expected beforeStart to delay, elapsed=${startElapsed}ms", startElapsed >= 40L)

        val nonTerminalElapsed = timeMillis { pacer.beforePoll(isTerminal = false) }
        assertTrue("expected a non-terminal poll to delay, elapsed=${nonTerminalElapsed}ms", nonTerminalElapsed >= 40L)

        val terminalElapsed = timeMillis { pacer.beforePoll(isTerminal = true) }
        assertTrue("expected a terminal poll not to delay, elapsed=${terminalElapsed}ms", terminalElapsed < 40L)

        assertTrue(pacer.timeoutBudgetMillis == 1_000L)
    }

    private suspend fun timeMillis(block: suspend () -> Unit): Long {
        val start = System.nanoTime()
        block()
        return (System.nanoTime() - start) / 1_000_000
    }
}
