package com.antigravity.terminalagent.terminal_agent

import android.content.Context

/**
 * Localized strings for native UI (notifications, channels).
 *
 * The app's language can differ from the device's (Settings → Language), so
 * Dart pushes its current translations through the method channel; they are
 * persisted so the foreground service shows the right language even when it is
 * recreated without the Flutter engine. Until Dart has pushed anything, the
 * Android string resources (values / values-es / values-ru / values-zh, picked
 * by the device locale) are used.
 */
object NativeStrings {
    private const val PREFS = "absssh_native_strings"

    fun save(context: Context, strings: Map<String, String>) {
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        editor.clear()
        for ((k, v) in strings) editor.putString(k, v)
        editor.apply()
    }

    fun get(context: Context, key: String, resId: Int): String {
        val pushed = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(key, null)
        return if (!pushed.isNullOrEmpty()) pushed else context.getString(resId)
    }
}
