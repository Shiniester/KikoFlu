package com.meteor.kikoeruflutter

import android.app.Activity
import android.webkit.CookieManager
import android.webkit.WebStorage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class MissavBrowserBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val proxyCoordinator: WebViewProxyCoordinator
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "com.meteor.kikoeruflutter/missav_browser"
        private const val MISSAV_URL = "https://missav.ai/"
        private const val MISSAV_ORIGIN = "https://missav.ai"
        private const val MISSAV_DOMAIN = "missav.ai"
    }

    private class PendingCall(val result: MethodChannel.Result) {
        var completed = false
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val pendingCalls = mutableSetOf<PendingCall>()
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val pending = PendingCall(result)
        if (disposed) {
            completeError(pending, "bridge_disposed", "The browser bridge is unavailable.")
            return
        }
        pendingCalls.add(pending)

        try {
            when (call.method) {
                "configureProxy" -> configureProxy(call, pending)
                "resetProxy" -> {
                    if (hasNoArguments(call, pending)) resetProxy(pending)
                }
                "getCookies" -> {
                    if (hasNoArguments(call, pending)) {
                        completeSuccess(pending, CookieManager.getInstance().getCookie(MISSAV_URL))
                    }
                }
                "clearSession" -> {
                    if (hasNoArguments(call, pending)) clearMissavSession(pending)
                }
                else -> completeNotImplemented(pending)
            }
        } catch (error: Exception) {
            completeError(
                pending,
                "browser_bridge_failed",
                error.message ?: "The browser request failed."
            )
        }
    }

    private fun configureProxy(call: MethodCall, pending: PendingCall) {
        val arguments = call.arguments as? Map<*, *>
        val mode = arguments?.get("mode") as? String
        val rawProxyUrl = arguments?.get("proxyUrl")
        if (arguments == null || mode == null ||
            mode !in listOf("direct", "system", "manual") ||
            (rawProxyUrl != null && rawProxyUrl !is String)
        ) {
            completeError(pending, "invalid_arguments", "Invalid proxy configuration.")
            return
        }

        val proxyUrl = (rawProxyUrl as? String)?.trim()?.takeIf { it.isNotEmpty() }
        proxyCoordinator.acquire(
            WebViewProxyCoordinator.Owner.MISSAV,
            mode,
            proxyUrl
        ) { failure ->
            if (failure == null) completeSuccess(pending)
            else completeError(pending, failure.code, failure.message)
        }
    }

    private fun resetProxy(pending: PendingCall) {
        proxyCoordinator.release(WebViewProxyCoordinator.Owner.MISSAV) { failure ->
            if (failure == null) completeSuccess(pending)
            else completeError(pending, failure.code, failure.message)
        }
    }

    private fun clearMissavSession(pending: PendingCall) {
        val cookieManager = CookieManager.getInstance()
        val cookieNames = cookieManager.getCookie(MISSAV_URL)
            ?.split(';')
            ?.mapNotNull { pair ->
                val separator = pair.indexOf('=')
                if (separator <= 0) null else pair.substring(0, separator).trim()
            }
            ?.filter { it.isNotEmpty() }
            ?.distinct()
            .orEmpty()
        val deletions = cookieNames.flatMap { name ->
            buildList {
                add("$name=; Max-Age=0; Path=/; Secure; HttpOnly")
                if (!name.startsWith("__Host-")) {
                    add("$name=; Max-Age=0; Path=/; Secure; HttpOnly; Domain=$MISSAV_DOMAIN")
                }
            }
        }

        if (deletions.isEmpty()) {
            finishSessionClear(pending, cookieManager, true)
            return
        }

        var remaining = deletions.size
        var allCookiesCleared = true
        deletions.forEach { cookie ->
            try {
                cookieManager.setCookie(MISSAV_URL, cookie) { accepted ->
                    activity.runOnUiThread {
                        if (accepted != true) allCookiesCleared = false
                        remaining--
                        if (remaining == 0) {
                            finishSessionClear(pending, cookieManager, allCookiesCleared)
                        }
                    }
                }
            } catch (_: Exception) {
                allCookiesCleared = false
                remaining--
                if (remaining == 0) {
                    finishSessionClear(pending, cookieManager, allCookiesCleared)
                }
            }
        }
    }

    private fun finishSessionClear(
        pending: PendingCall,
        cookieManager: CookieManager,
        allCookiesCleared: Boolean
    ) {
        try {
            cookieManager.flush()
            WebStorage.getInstance().deleteOrigin(MISSAV_ORIGIN)
            if (allCookiesCleared) completeSuccess(pending)
            else completeError(pending, "cookie_clear_failed", "Some MissAV cookies could not be cleared.")
        } catch (error: Exception) {
            completeError(
                pending,
                "session_clear_failed",
                error.message ?: "The MissAV browser session could not be cleared."
            )
        }
    }

    private fun hasNoArguments(call: MethodCall, pending: PendingCall): Boolean {
        if (call.arguments == null) return true
        completeError(pending, "invalid_arguments", "This method does not accept arguments.")
        return false
    }

    private fun completeSuccess(pending: PendingCall, value: Any? = null) {
        if (pending.completed) return
        pending.completed = true
        pendingCalls.remove(pending)
        pending.result.success(value)
    }

    private fun completeError(pending: PendingCall, code: String, message: String) {
        if (pending.completed) return
        pending.completed = true
        pendingCalls.remove(pending)
        pending.result.error(code, message, null)
    }

    private fun completeNotImplemented(pending: PendingCall) {
        if (pending.completed) return
        pending.completed = true
        pendingCalls.remove(pending)
        pending.result.notImplemented()
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        pendingCalls.toList().forEach { pending ->
            completeError(pending, "bridge_disposed", "The browser bridge was closed.")
        }
        proxyCoordinator.release(WebViewProxyCoordinator.Owner.MISSAV)
    }
}
