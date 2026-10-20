package com.antigravity.terminalagent.terminal_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that keeps the app process (and therefore every running
 * PTY/SSH shell) alive while ABSssh is in the background, mirroring the way
 * Termux stays alive. It shows a persistent notification with two actions:
 *
 *  - "Adquirir/Liberar wakelock": toggles a partial wakelock so long-running
 *    tasks keep executing while the screen is off.
 *  - "Salir": tears everything down and fully closes the app.
 */
class TerminalService : Service() {

    companion object {
        const val ACTION_START = "com.antigravity.terminalagent.action.START"
        const val ACTION_STOP = "com.antigravity.terminalagent.action.STOP"
        const val ACTION_REFRESH = "com.antigravity.terminalagent.action.REFRESH"
        const val ACTION_TOGGLE_WAKELOCK =
            "com.antigravity.terminalagent.action.TOGGLE_WAKELOCK"

        /** True between onCreate and onDestroy. */
        @Volatile var isRunning = false

        // Channel id kept from the Kammel era: renaming it would create a new
        // channel and drop the user's per-channel notification settings.
        private const val CHANNEL_ID = "kammel_background"
        private const val NOTIFICATION_ID = 1001
        private const val WAKELOCK_TAG = "ABSssh::BackgroundWakeLock"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_TOGGLE_WAKELOCK -> toggleWakeLock()
        }

        startForegroundWithNotification()
        // START_STICKY: if the OS kills the service under memory pressure it is
        // recreated as soon as resources allow, re-establishing the notification.
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
    }

    override fun onDestroy() {
        isRunning = false
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startForegroundWithNotification() {
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        // Re-creating an existing channel only updates its name/description,
        // which is how a language change reaches the system settings screen.
        val channel = NotificationChannel(
            CHANNEL_ID,
            NativeStrings.get(this, "fg_channel_name", R.string.fg_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = NativeStrings.get(this@TerminalService, "fg_channel_desc", R.string.fg_channel_desc)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val held = wakeLock?.isHeld == true

        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            PendingIntent.getActivity(this, 0, it, pendingFlags())
        }

        val wakeLockIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, TerminalService::class.java).setAction(ACTION_TOGGLE_WAKELOCK),
            pendingFlags(),
        )

        val exitIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, TerminalService::class.java).setAction(ACTION_STOP),
            pendingFlags(),
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(NativeStrings.get(this, "fg_title", R.string.fg_title))
            .setContentText(
                if (held) NativeStrings.get(this, "fg_text_wakelock", R.string.fg_text_wakelock)
                else NativeStrings.get(this, "fg_text", R.string.fg_text),
            )
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(contentIntent)
            .addAction(
                0,
                if (held) NativeStrings.get(this, "fg_release", R.string.fg_release)
                else NativeStrings.get(this, "fg_acquire", R.string.fg_acquire),
                wakeLockIntent,
            )
            .addAction(0, NativeStrings.get(this, "fg_exit", R.string.fg_exit), exitIntent)
            .build()
    }

    private fun toggleWakeLock() {
        if (wakeLock?.isHeld == true) {
            releaseWakeLock()
        } else {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        // Refresh the notification so the action label/text reflects the change.
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun releaseWakeLock() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
    }

    private fun stopEverything() {
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        // Fully close the app, matching Termux's "Exit" behaviour: kill the
        // whole process so no detached shells linger.
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    private fun pendingFlags(): Int {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return flags
    }
}
