package com.meteor.kikoeruflutter

import android.os.Handler
import android.os.Looper
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import java.net.URI
import java.util.Locale
import java.util.concurrent.Executor

internal object WebViewProxyCoordinator {
    enum class Owner {
        MISSAV,
        JAPANESE_ASMR
    }

    data class Failure(val code: String, val message: String)

    private data class AppConfiguration(val mode: String, val proxyUrl: String?)
    private data class OverrideTarget(val direct: Boolean, val proxyUrl: String?)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val callbackExecutor = Executor { command -> mainHandler.post(command) }
    private val owners = mutableSetOf<Owner>()
    private val completions = mutableListOf<(Failure?) -> Unit>()
    private var configuration = AppConfiguration("system", null)
    private var appliedTarget: OverrideTarget? = null
    private var operationInFlight = false

    fun acquire(
        owner: Owner,
        mode: String,
        proxyUrl: String?,
        completion: (Failure?) -> Unit
    ) {
        onMain {
            val parsed = parseConfiguration(mode, proxyUrl)
            if (parsed.second != null) {
                completion(parsed.second)
                return@onMain
            }
            configuration = parsed.first!!
            owners.add(owner)
            completions.add(completion)
            reconcile()
        }
    }

    fun release(owner: Owner, completion: (Failure?) -> Unit = {}) {
        onMain {
            owners.remove(owner)
            completions.add(completion)
            reconcile()
        }
    }

    fun updateConfiguration(
        mode: String,
        proxyUrl: String?,
        completion: (Failure?) -> Unit
    ) {
        onMain {
            val parsed = parseConfiguration(mode, proxyUrl)
            if (parsed.second != null) {
                completion(parsed.second)
                return@onMain
            }
            configuration = parsed.first!!
            if (owners.isEmpty()) {
                completion(null)
                return@onMain
            }
            completions.add(completion)
            reconcile()
        }
    }

    private fun reconcile() {
        if (operationInFlight) return

        val desiredTarget = desiredTarget()
        if (desiredTarget == appliedTarget) {
            completeWaiters(null)
            return
        }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            val failure = if (desiredTarget == null) {
                Failure(
                    "proxy_unsupported",
                    "This Android WebView cannot restore the system proxy."
                )
            } else {
                Failure(
                    "proxy_unsupported",
                    "This Android WebView cannot use the selected proxy configuration."
                )
            }
            completeWaiters(failure)
            return
        }

        operationInFlight = true
        try {
            if (desiredTarget == null) {
                ProxyController.getInstance().clearProxyOverride(
                    callbackExecutor,
                    Runnable {
                        operationInFlight = false
                        appliedTarget = null
                        reconcile()
                    }
                )
            } else {
                ProxyController.getInstance().setProxyOverride(
                    buildProxyConfig(desiredTarget),
                    callbackExecutor,
                    Runnable {
                        operationInFlight = false
                        appliedTarget = desiredTarget
                        reconcile()
                    }
                )
            }
        } catch (error: Exception) {
            operationInFlight = false
            val failure = if (desiredTarget == null) {
                Failure(
                    "proxy_reset_failed",
                    error.message ?: "The system proxy could not be restored."
                )
            } else {
                Failure(
                    "proxy_configuration_failed",
                    error.message ?: "The proxy configuration could not be applied."
                )
            }
            completeWaiters(failure)
        }
    }

    private fun desiredTarget(): OverrideTarget? {
        if (owners.isEmpty()) return null
        return when (configuration.mode) {
            "direct" -> OverrideTarget(direct = true, proxyUrl = null)
            "manual" -> OverrideTarget(direct = false, proxyUrl = configuration.proxyUrl)
            "system" -> configuration.proxyUrl?.let {
                OverrideTarget(direct = false, proxyUrl = it)
            }
            else -> null
        }
    }

    private fun buildProxyConfig(target: OverrideTarget): ProxyConfig {
        val builder = ProxyConfig.Builder()
        return if (target.direct) {
            builder.addDirect().build()
        } else {
            builder.addProxyRule(target.proxyUrl!!).build()
        }
    }

    private fun parseConfiguration(
        mode: String,
        rawProxyUrl: String?
    ): Pair<AppConfiguration?, Failure?> {
        if (mode !in listOf("direct", "system", "manual")) {
            return null to Failure("invalid_arguments", "Invalid proxy configuration.")
        }

        val proxyUrl = rawProxyUrl?.trim()?.takeIf { it.isNotEmpty() }
        if (mode == "manual" && proxyUrl == null) {
            return null to Failure("invalid_arguments", "A proxy URL is required.")
        }
        if (mode != "direct" && proxyUrl != null && !isValidProxyUrl(proxyUrl)) {
            return null to Failure("invalid_arguments", "Invalid proxy URL.")
        }
        return AppConfiguration(mode, proxyUrl) to null
    }

    private fun isValidProxyUrl(value: String): Boolean {
        return try {
            val uri = URI(value)
            val scheme = uri.scheme?.lowercase(Locale.ROOT)
            val port = uri.port
            scheme in listOf("http", "https") &&
                !uri.host.isNullOrBlank() &&
                uri.userInfo == null &&
                (port == -1 || port in 1..65535) &&
                (uri.rawPath.isNullOrEmpty() || uri.rawPath == "/") &&
                uri.rawQuery == null &&
                uri.rawFragment == null
        } catch (_: Exception) {
            false
        }
    }

    private fun completeWaiters(failure: Failure?) {
        val pending = completions.toList()
        completions.clear()
        pending.forEach { it(failure) }
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action()
        else mainHandler.post { action() }
    }
}
