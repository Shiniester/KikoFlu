package com.meteor.kikoeruflutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class VideoPlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    companion object {
        private const val CHANNEL = "video_playback"
        private const val NOTIFICATION = 41802

        fun actionIntent(context: Context, action: String): PendingIntent = PendingIntent.getBroadcast(
            context, 0, Intent(context, VideoPlaybackActionReceiver::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (VideoPlayerBridge.current?.get()?.isBackgroundPlaybackActive != true) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.video_playback), NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 41802,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this)
        val notification = builder.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(getString(R.string.video_playback)).setContentText("KikoFlu")
            .setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause,
                getString(R.string.video_pause), actionIntent(this, "pause")).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_view,
                getString(R.string.video_return), open).build()).build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else startForeground(NOTIFICATION, notification)
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "KikoFlu:VideoPlayback")
                .apply { setReferenceCounted(false); acquire() }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }
}

class VideoPlaybackActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        VideoPlayerBridge.current?.get()?.dispatchAction(intent.action ?: return)
    }
}
