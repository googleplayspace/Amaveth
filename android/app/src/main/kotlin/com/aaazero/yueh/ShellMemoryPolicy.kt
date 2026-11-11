package com.aaazero.yueh

import android.content.ComponentCallbacks2

/** Spec 11.4: only real pressure while running. Background levels are not warnings. */
internal object ShellMemoryPolicy {
    @Suppress("DEPRECATION")
    fun shouldWarn(level: Int): Boolean =
        level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
            level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL
}
