package com.meteor.kikoeruflutter

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.IntentFilter
import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.content.pm.ActivityInfo
import android.net.Uri
import android.app.RemoteAction
import android.graphics.Point
import android.graphics.drawable.Icon
import android.os.Build
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Rational
import android.view.Display
import android.view.OrientationEventListener
import android.view.Surface
import android.view.View
import android.view.ViewTreeObserver
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

class VideoPlayerBridge(private val activity: Activity, messenger: BinaryMessenger,
    private val updateKeepScreenOn: (Boolean) -> Unit) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.meteor.kikoeruflutter/video_player")
    private val handler = Handler(Looper.getMainLooper())
    private var originalBrightness: Float? = null
    private var pendingEnter: MethodChannel.Result? = null
    private var pendingBrightnessPermission: MethodChannel.Result? = null
    private var pendingWindowLayout: MethodChannel.Result? = null
    private var windowLayoutObserver: ViewTreeObserver? = null
    private var windowLayoutListener: ViewTreeObserver.OnPreDrawListener? = null
    private var windowLayoutTimeout: Runnable? = null
    private var deviceOrientation: Int? = null
    private var fullscreenEntryPortrait: Boolean? = null
    private val orientationListener = object : OrientationEventListener(activity) {
        override fun onOrientationChanged(orientation: Int) {
            if (orientation != ORIENTATION_UNKNOWN || deviceOrientation == null) {
                deviceOrientation = orientation
            }
            if (pendingWindowLayout != null) {
                activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)?.invalidate()
            }
        }
    }
    private var systemBrightnessMode = false
    private var originalOrientation: Int? = null
    private var fullscreenStatusBarHidden = false
    private var originalSystemBarsBehavior: Int? = null
    private var backgroundPlayback = false
    private var playing = false
    private var autoPictureInPicture = false
    private var aspectRatio = 16.0 / 9.0
    private val enterTimeout = Runnable { completeEnter(false) }

    init { channel.setMethodCallHandler(this); current = WeakReference(this) }

    companion object {
        var current: WeakReference<VideoPlayerBridge>? = null
        private const val BRIGHTNESS_PERMISSION_REQUEST = 41807
    }
    val isBackgroundPlaybackActive: Boolean get() = backgroundPlayback && playing

    @get:ChecksSdkIntAtLeast(api = Build.VERSION_CODES.O)
    private val supportsPip: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> result.success(mapOf("brightness" to true, "pictureInPicture" to supportsPip))
            "getBatteryStatus" -> {
                val battery = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                if (level < 0 || scale <= 0 || level > scale ||
                    status !in listOf(BatteryManager.BATTERY_STATUS_CHARGING,
                        BatteryManager.BATTERY_STATUS_FULL, BatteryManager.BATTERY_STATUS_DISCHARGING,
                        BatteryManager.BATTERY_STATUS_NOT_CHARGING)) {
                    result.success(null)
                } else {
                    result.success(mapOf("level" to (level.toLong() * 100 / scale).toInt(),
                        "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                            status == BatteryManager.BATTERY_STATUS_FULL)))
                }
            }
            "getBrightness" -> {
                val brightness = if (systemBrightnessMode) -1f else activity.window.attributes.screenBrightness
                result.success(if (brightness >= 0) brightness.toDouble() else
                    Settings.System.getInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128) / 255.0)
            }
            "setBrightness" -> {
                val value = call.argument<Number>("value")?.toFloat()
                if (value == null || !value.isFinite()) {
                    result.error("invalid_brightness", "Brightness must be finite.", null)
                    return
                }
                if (systemBrightnessMode) {
                    if (!Settings.System.canWrite(activity)) {
                        systemBrightnessMode = false
                        result.error("brightness_permission", "System brightness permission is required.", null)
                    } else {
                        Settings.System.putInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS,
                            (value.coerceIn(0f, 1f) * 255).toInt())
                        result.success(null)
                    }
                    return
                }
                val attributes = activity.window.attributes
                if (originalBrightness == null) originalBrightness = attributes.screenBrightness
                attributes.screenBrightness = value.coerceIn(0f, 1f)
                activity.window.attributes = attributes
                result.success(null)
            }
            "resetBrightness" -> { resetBrightness(); result.success(null) }
            "getSystemBrightnessMode" -> result.success(systemBrightnessMode && Settings.System.canWrite(activity))
            "setSystemBrightnessMode" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                systemBrightnessMode = enabled && Settings.System.canWrite(activity)
                if (systemBrightnessMode) {
                    val attributes = activity.window.attributes
                    if (originalBrightness == null) originalBrightness = attributes.screenBrightness
                    attributes.screenBrightness = -1f
                    activity.window.attributes = attributes
                } else resetBrightness()
                result.success(!enabled || systemBrightnessMode)
            }
            "requestSystemBrightnessPermission" -> {
                if (Settings.System.canWrite(activity)) { result.success(null); return }
                if (pendingBrightnessPermission != null) {
                    result.error("permission_pending", "Brightness permission is already open.", null)
                    return
                }
                pendingBrightnessPermission = result
                try {
                    activity.startActivityForResult(
                        Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${activity.packageName}")),
                        BRIGHTNESS_PERMISSION_REQUEST)
                } catch (_: ActivityNotFoundException) {
                    pendingBrightnessPermission = null
                    result.error("permission_unavailable", "System brightness permission settings are unavailable.", null)
                }
            }
            "setGravityOrientation" -> {
                if (call.argument<Boolean>("enabled") == true) {
                    if (originalOrientation == null) originalOrientation = activity.requestedOrientation
                    activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                } else resetOrientation()
                result.success(null)
            }
            "waitForWindowLayout" -> waitForWindowLayout(result)
            "setBackgroundPlayback" -> {
                backgroundPlayback = call.argument<Boolean>("enabled") == true
                updateBackgroundService()
                result.success(null)
            }
            "updateState" -> {
                val updated = call.argument<Boolean>("playing") == true
                if (playing != updated) {
                    playing = updated
                    updateBackgroundService()
                    updatePictureInPictureParams()
                }
                result.success(null)
            }
            "setAutoPictureInPicture" -> {
                autoPictureInPicture = call.argument<Boolean>("enabled") == true
                aspectRatio = validAspectRatio(call.argument<Number>("aspectRatio")?.toDouble())
                updatePictureInPictureParams()
                result.success(null)
            }
            "setKeepScreenOn" -> {
                updateKeepScreenOn(call.argument<Boolean>("enabled") == true)
                result.success(null)
            }
            "setFullscreenStatusBarHidden" -> {
                setFullscreenStatusBarHidden(call.argument<Boolean>("hidden") == true)
                result.success(null)
            }
            "enterPictureInPicture" -> {
                if (!supportsPip || pendingEnter != null) { result.success(false); return }
                if (activity.isInPictureInPictureMode) { result.success(true); return }
                aspectRatio = validAspectRatio(call.argument<Number>("aspectRatio")?.toDouble())
                pendingEnter = result
                handler.postDelayed(enterTimeout, 5000)
                try {
                    if (!activity.enterPictureInPictureMode(pictureInPictureParams())) completeEnter(false)
                } catch (_: IllegalStateException) { completeEnter(false) }
                  catch (_: IllegalArgumentException) { completeEnter(false) }
            }
            "exitPictureInPicture" -> {
                completeEnter(false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.isInPictureInPictureMode) {
                    activity.startActivity(Intent(activity, activity.javaClass)
                        .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                }
                result.success(null)
            }
            "dispose" -> { reset(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    fun onPictureInPictureModeChanged(active: Boolean) {
        channel.invokeMethod("pictureInPictureChanged", active)
        completeEnter(active)
    }

    fun onPostResume() {
        if (fullscreenStatusBarHidden) setFullscreenStatusBarHidden(true)
    }

    fun handleActivityResult(requestCode: Int): Boolean {
        if (requestCode != BRIGHTNESS_PERMISSION_REQUEST) return false
        val result = pendingBrightnessPermission
        pendingBrightnessPermission = null
        result?.success(null)
        return true
    }

    private fun validAspectRatio(value: Double?): Double =
        if (value != null && value.isFinite() && value > 0) value.coerceIn(1.0 / 2.39, 2.39) else 16.0 / 9.0

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun pictureInPictureParams(): PictureInPictureParams {
        val actions = listOf(
            remoteAction("rewind", android.R.drawable.ic_media_rew, R.string.video_rewind),
            remoteAction(if (playing) "pause" else "play", if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (playing) R.string.video_pause else R.string.video_play),
            remoteAction("forward", android.R.drawable.ic_media_ff, R.string.video_forward))
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((aspectRatio * 1000).toInt().coerceIn(419, 2390), 1000))
            .setActions(actions)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setAutoEnterEnabled(autoPictureInPicture && playing)
        return builder.build()
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun remoteAction(action: String, icon: Int, label: Int): RemoteAction {
        val title = activity.getString(label)
        return RemoteAction(Icon.createWithResource(activity, icon), title, title,
            VideoPlaybackService.actionIntent(activity, action))
    }

    private fun updatePictureInPictureParams() {
        if (supportsPip) activity.setPictureInPictureParams(pictureInPictureParams())
    }

    fun onUserLeaveHint() {
        if (supportsPip && autoPictureInPicture && playing && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try { activity.enterPictureInPictureMode(pictureInPictureParams()) }
            catch (_: IllegalStateException) { channel.invokeMethod("pictureInPictureChanged", false) }
        }
    }

    fun dispatchAction(action: String) {
        when (action) {
            "play" -> channel.invokeMethod("setPlaying", true)
            "pause" -> channel.invokeMethod("setPlaying", false)
            "rewind" -> channel.invokeMethod("skipByInterval", -10.0)
            "forward" -> channel.invokeMethod("skipByInterval", 10.0)
        }
    }

    private fun updateBackgroundService() {
        val intent = Intent(activity, VideoPlaybackService::class.java)
        if (backgroundPlayback && playing) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) activity.startForegroundService(intent)
            else activity.startService(intent)
        } else activity.stopService(intent)
    }

    private fun waitForWindowLayout(result: MethodChannel.Result) {
        clearWindowLayout()
        val view = activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
        if (view == null || !view.isAttachedToWindow) { result.success(null); return }
        pendingWindowLayout = result
        view.post {
            if (pendingWindowLayout !== result) return@post
            val observer = view.viewTreeObserver
            val listener = ViewTreeObserver.OnPreDrawListener {
                if (pendingWindowLayout !== result) return@OnPreDrawListener true
                val naturalPortrait = phoneNaturalPortrait()
                val autoRotate = Settings.System.getInt(
                    activity.contentResolver, Settings.System.ACCELEROMETER_ROTATION, 1
                ) != 0
                if (naturalPortrait != null && autoRotate && deviceOrientation == null &&
                    orientationListener.canDetectOrientation()
                ) {
                    return@OnPreDrawListener true
                }
                val targetPortrait = naturalPortrait?.let {
                    restoredVideoPortrait(
                        it, autoRotate,
                        Settings.System.getInt(activity.contentResolver, Settings.System.USER_ROTATION, 0),
                        deviceOrientation, fullscreenEntryPortrait
                    )
                }
                val actualPortrait = windowPortrait(view)
                if (targetPortrait != null && actualPortrait != targetPortrait) {
                    return@OnPreDrawListener true
                }
                completeWindowLayout(actualPortrait)
                true
            }
            windowLayoutObserver = observer
            windowLayoutListener = listener
            observer.addOnPreDrawListener(listener)
            // The system can ignore orientation requests; keep exit cancellation bounded.
            val timeout = Runnable {
                if (pendingWindowLayout === result) completeWindowLayout(windowPortrait(view))
            }
            windowLayoutTimeout = timeout
            handler.postDelayed(timeout, 2000)
            view.requestLayout()
            view.invalidate()
        }
    }

    @Suppress("DEPRECATION")
    private fun phoneNaturalPortrait(): Boolean? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            (activity.isInMultiWindowMode || activity.isInPictureInPictureMode)
        ) return null

        val display = activity.windowManager.defaultDisplay
        if (display.displayId != Display.DEFAULT_DISPLAY) return null
        if (activity.window.decorView.display?.displayId != display.displayId) return null
        val size = Point()
        display.getRealSize(size)
        if (minOf(size.x, size.y) / activity.resources.displayMetrics.density >= 600f) return null

        val currentPortrait = size.y >= size.x
        val rotated = display.rotation == Surface.ROTATION_90 || display.rotation == Surface.ROTATION_270
        return currentPortrait != rotated
    }

    private fun windowPortrait(view: View): Boolean? =
        if (view.isAttachedToWindow && view.width > 0 && view.height > 0) view.height >= view.width
        else null

    private fun completeWindowLayout(portrait: Boolean?) {
        val result = pendingWindowLayout
        pendingWindowLayout = null
        removeWindowLayoutListener()
        result?.success(portrait)
    }

    private fun removeWindowLayoutListener() {
        windowLayoutTimeout?.let(handler::removeCallbacks)
        windowLayoutTimeout = null
        val observer = windowLayoutObserver
        val listener = windowLayoutListener
        if (observer?.isAlive == true && listener != null) {
            observer.removeOnPreDrawListener(listener)
        }
        windowLayoutObserver = null
        windowLayoutListener = null
    }

    private fun clearWindowLayout() {
        completeWindowLayout(null)
    }

    private fun resetOrientation() {
        originalOrientation?.let { activity.requestedOrientation = it }
        originalOrientation = null
    }

    private fun completeEnter(active: Boolean) {
        handler.removeCallbacks(enterTimeout)
        val result = pendingEnter
        pendingEnter = null
        result?.success(active)
    }

    private fun resetBrightness() {
        originalBrightness?.let {
            val attributes = activity.window.attributes
            attributes.screenBrightness = it
            activity.window.attributes = attributes
        }
        originalBrightness = null
    }

    private fun setFullscreenStatusBarHidden(hidden: Boolean) {
        if (!hidden && !fullscreenStatusBarHidden) return
        val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
        if (hidden) {
            if (!fullscreenStatusBarHidden) {
                originalSystemBarsBehavior = controller.systemBarsBehavior
                fullscreenEntryPortrait = activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
                    ?.let(::windowPortrait)
                deviceOrientation = null
                orientationListener.enable()
            }
            fullscreenStatusBarHidden = true
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.statusBars())
        } else {
            orientationListener.disable()
            deviceOrientation = null
            fullscreenEntryPortrait = null
            fullscreenStatusBarHidden = false
            controller.show(WindowInsetsCompat.Type.statusBars())
            originalSystemBarsBehavior?.let { controller.systemBarsBehavior = it }
            originalSystemBarsBehavior = null
        }
    }

    private fun reset() {
        clearWindowLayout()
        pendingBrightnessPermission?.success(null)
        pendingBrightnessPermission = null
        completeEnter(false)
        resetBrightness()
        setFullscreenStatusBarHidden(false)
        updateKeepScreenOn(false)
        systemBrightnessMode = false
        resetOrientation()
        autoPictureInPicture = false
        backgroundPlayback = false
        playing = false
        updateBackgroundService()
        updatePictureInPictureParams()
    }

    fun dispose() { reset(); channel.setMethodCallHandler(null); current = null }
}
