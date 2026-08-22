package org.tzap.zmanager.mobile

import kotlinx.coroutines.delay

/**
 * Injectable pacing seam for debug/device-E2E scenarios: an artificial delay
 * before a job starts and between non-terminal polls, plus an optional
 * shortened timeout budget so the platform-timeout path can be exercised
 * deterministically. Every production request uses [NoOpJobPacer], which
 * does nothing; [DelayingJobPacer] is constructed only by the
 * `BuildConfig.DEBUG`-gated buttons in MainActivity.kt, the same runtime
 * gating every other debug-only affordance in this file already uses. See
 * Track 5 in docs/mobile-code-health-remediation-plan.md.
 */
interface JobPacer {
    suspend fun beforeStart() {}
    suspend fun beforePoll(isTerminal: Boolean) {}
    val timeoutBudgetMillis: Long? get() = null
}

object NoOpJobPacer : JobPacer

class DelayingJobPacer(
    private val delayMillis: Long,
    override val timeoutBudgetMillis: Long? = null
) : JobPacer {
    override suspend fun beforeStart() {
        if (delayMillis > 0L) delay(delayMillis.coerceIn(0L, MAX_DELAY_MILLIS))
    }

    override suspend fun beforePoll(isTerminal: Boolean) {
        if (!isTerminal && delayMillis > 0L) delay(delayMillis.coerceIn(0L, MAX_DELAY_MILLIS))
    }

    private companion object {
        const val MAX_DELAY_MILLIS = 30_000L
    }
}
