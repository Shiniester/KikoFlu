package com.meteor.kikoeruflutter

import android.webkit.CookieManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class JableBrowserBridge(
    messenger: BinaryMessenger,
    private val proxyCoordinator: WebViewProxyCoordinator
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL_NAME = "com.meteor.kikoeruflutter/jable_browser"
        private const val JABLE_URL = "https://jable.tv/"
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
                        completeSuccess(pending, CookieManager.getInstance().getCookie(JABLE_URL))
                    }
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
            WebViewProxyCoordinator.Owner.JABLE,
            mode,
            proxyUrl
        ) { failure ->
            if (failure == null) completeSuccess(pending)
            else completeError(pending, failure.code, failure.message)
        }
    }

    private fun resetProxy(pending: PendingCall) {
        proxyCoordinator.release(WebViewProxyCoordinator.Owner.JABLE) { failure ->
            if (failure == null) completeSuccess(pending)
            else completeError(pending, failure.code, failure.message)
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
        proxyCoordinator.release(WebViewProxyCoordinator.Owner.JABLE)
    }
}
