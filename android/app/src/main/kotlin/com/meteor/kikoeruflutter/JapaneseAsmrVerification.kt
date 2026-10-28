package com.meteor.kikoeruflutter

import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONTokener

internal class JapaneseAsmrVerification(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val proxyCoordinator: WebViewProxyCoordinator
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "com.meteor.kikoeruflutter/japanese_asmr"
        private const val READ_TIMEOUT_MS = 25_000L
        private const val DOCUMENT_SCRIPT =
            "({html: document.documentElement ? document.documentElement.outerHTML : '', " +
                "challenge: typeof window._cf_chl_opt !== 'undefined' || " +
                "(document.documentElement && document.documentElement.innerHTML.includes('/orchestrate/chl_page/'))})"
    }

    private class PendingRequest(
        val result: MethodChannel.Result,
        val isRead: Boolean,
        val id: Int? = null
    ) {
        var dialog: Dialog? = null
        var webView: WebView? = null
        var pageCheck: Runnable? = null
        var timeout: Runnable? = null
        var cleanup: Runnable? = null
        var finishing = false
        var mainFrameUrl: String? = null
        var statusCode = 200
        var headers: Map<String, String> = emptyMap()
    }

    private data class DocumentState(val html: String, val challenge: Boolean)

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val handler = Handler(Looper.getMainLooper())
    private var pendingRequest: PendingRequest? = null
    private var retainedWebView: WebView? = null
    private var hasVerifiedSession = false
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "The verification bridge was disposed.", null)
            return
        }
        when (call.method) {
            "verify" -> verify(call, result)
            "read" -> read(call, result)
            "cancel" -> cancel(call, result)
            else -> result.notImplemented()
        }
    }

    private fun verify(call: MethodCall, result: MethodChannel.Result) {
        if (pendingRequest != null) {
            result.error("already_active", "A site verification is already active.", null)
            return
        }
        val url = call.argument<String>("url")
        val proxyMode = call.argument<String>("proxyMode")
        val proxyAddress = call.argument<String>("proxyAddress")
        val title = call.argument<String>("title")
        val closeLabel = call.argument<String>("closeLabel")
        if (url == null || !isSiteUrl(Uri.parse(url)) || !isProxyArgumentsValid(proxyMode, proxyAddress) ||
            title.isNullOrBlank() || closeLabel.isNullOrBlank()
        ) {
            result.error("invalid_arguments", "Invalid site verification arguments.", null)
            return
        }

        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            result.error("proxy_unsupported", "This Android WebView cannot use the selected proxy mode.", null)
            return
        }

        val request = PendingRequest(result, isRead = false)
        request.mainFrameUrl = url
        pendingRequest = request
        try {
            val webView = obtainWebView()
            request.webView = webView
            val progress = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal)
            webView.webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView, newProgress: Int) {
                    if (!isCurrent(request)) return
                    progress.progress = newProgress
                    progress.visibility = if (newProgress == 100) View.GONE else View.VISIBLE
                }
            }
            configureWebViewClient(request, webView)

            val dialog = Dialog(activity, android.R.style.Theme_Material_Light_NoActionBar)
            request.dialog = dialog
            val header = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                setPadding(dp(16), dp(8), dp(8), dp(8))
                addView(TextView(activity).apply {
                    text = title
                    textSize = 18f
                }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                addView(Button(activity).apply {
                    text = closeLabel
                    setOnClickListener { finish(request) }
                })
            }
            dialog.setContentView(LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(header)
                addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)))
                addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
            })
            dialog.setOnDismissListener {
                if (!request.finishing) finish(request)
            }
            dialog.show()
            dialog.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)

            applyProxy(request, proxyMode!!, proxyAddress) {
                webView.loadUrl(url)
            }
        } catch (error: Exception) {
            finish(request, errorCode = "verification_unavailable", errorMessage = error.message)
        }
    }

    private fun read(call: MethodCall, result: MethodChannel.Result) {
        if (pendingRequest != null) {
            result.error("already_active", "A site request is already active.", null)
            return
        }
        val id = call.argument<Int>("id")
        val url = call.argument<String>("url")
        val proxyMode = call.argument<String>("proxyMode")
        val proxyAddress = call.argument<String>("proxyAddress")
        if (id == null || url == null || !isSiteUrl(Uri.parse(url)) ||
            !isProxyArgumentsValid(proxyMode, proxyAddress)
        ) {
            result.error("invalid_arguments", "Invalid site request arguments.", null)
            return
        }
        val webView = retainedWebView
        if (webView == null || !hasVerifiedSession) {
            result.error("verification_required", "Complete site verification before reading pages.", null)
            return
        }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            result.error("proxy_unsupported", "This Android WebView cannot use the selected proxy mode.", null)
            return
        }

        val request = PendingRequest(result, isRead = true, id = id)
        request.mainFrameUrl = url
        request.webView = webView
        pendingRequest = request
        try {
            webView.webChromeClient = null
            configureWebViewClient(request, webView)
            val timeout = Runnable {
                if (pendingRequest === request && !request.finishing) {
                    finish(request, errorCode = "timeout", errorMessage = "The page did not load within 25 seconds.")
                }
            }
            request.timeout = timeout
            handler.postDelayed(timeout, READ_TIMEOUT_MS)
            applyProxy(request, proxyMode!!, proxyAddress) {
                webView.loadUrl(url)
            }
        } catch (error: Exception) {
            finish(request, errorCode = "network_error", errorMessage = error.message)
        }
    }

    private fun cancel(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Int>("id")
        if (id == null) {
            result.error("invalid_arguments", "A request id is required.", null)
            return
        }
        val request = pendingRequest
        if (request?.isRead == true && request.id == id && !request.finishing) {
            finish(request, errorCode = "cancelled", errorMessage = "The page request was cancelled.")
        }
        result.success(null)
    }

    private fun obtainWebView(): WebView {
        retainedWebView?.let { return it }
        val webView = WebView(activity)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }
        retainedWebView = webView
        return webView
    }

    private fun configureWebViewClient(request: PendingRequest, webView: WebView) {
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, navigation: WebResourceRequest): Boolean {
                if (!isCurrent(request)) return true
                if (!navigation.isForMainFrame) return false
                if (isSiteUrl(navigation.url)) {
                    request.mainFrameUrl = navigation.url.toString()
                    return false
                }
                finish(request, errorCode = "external_navigation", errorMessage = "Navigation outside the site was blocked.")
                return true
            }

            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                if (!isCurrent(request)) return
                request.pageCheck?.let { view.removeCallbacks(it) }
                request.pageCheck = null
                request.statusCode = 200
                request.headers = emptyMap()
                if (url == null || !isSiteUrl(Uri.parse(url))) {
                    finish(request, errorCode = "external_navigation", errorMessage = "Navigation outside the site was blocked.")
                } else {
                    request.mainFrameUrl = url
                }
            }

            override fun onReceivedError(view: WebView, navigation: WebResourceRequest, error: WebResourceError) {
                if (isCurrent(request) && navigation.isForMainFrame) {
                    finish(request, errorCode = "network_error", errorMessage = error.description.toString())
                }
            }

            override fun onReceivedHttpError(view: WebView, navigation: WebResourceRequest, response: WebResourceResponse) {
                if (isCurrent(request) && navigation.isForMainFrame) {
                    request.statusCode = response.statusCode
                    request.headers = response.responseHeaders?.toMap() ?: emptyMap()
                }
            }

            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                handler.cancel()
                if (isCurrent(request) && error.url == request.mainFrameUrl) {
                    finish(request, errorCode = "network_error", errorMessage = "The site's SSL connection failed.")
                }
            }

            override fun onPageFinished(view: WebView, url: String?) {
                if (!isCurrent(request) || url == null || view.url != url) return
                if (!isSiteUrl(Uri.parse(url))) {
                    finish(request, errorCode = "external_navigation", errorMessage = "Navigation outside the site was blocked.")
                    return
                }
                if (request.isRead) finishRead(request, view, url)
                else checkVerificationPage(request, view, url)
            }
        }
    }

    private fun checkVerificationPage(request: PendingRequest, view: WebView, url: String) {
        request.pageCheck?.let { view.removeCallbacks(it) }
        val check = object : Runnable {
            override fun run() {
                if (!isCurrent(request) || view.url != url || request.pageCheck !== this) return
                view.evaluateJavascript(DOCUMENT_SCRIPT) { value ->
                    if (!isCurrent(request) || view.url != url || request.pageCheck !== this) {
                        return@evaluateJavascript
                    }
                    val document = parseDocument(value)
                    val cookie = CookieManager.getInstance().getCookie(url)
                        ?.split(';')
                        ?.map { it.trim() }
                        ?.firstOrNull { it.startsWith("cf_clearance=") && it.substringAfter('=').isNotBlank() }
                    if (document != null && !document.challenge && request.statusCode in 200..299 && cookie != null) {
                        CookieManager.getInstance().flush()
                        hasVerifiedSession = true
                        finish(request, mapOf(
                            "cookie" to cookie,
                            "userAgent" to view.settings.userAgentString,
                            "url" to url,
                            "data" to document.html,
                            "statusCode" to request.statusCode,
                            "headers" to request.headers.toMap()
                        ))
                    } else {
                        view.postDelayed(this, 500)
                    }
                }
            }
        }
        request.pageCheck = check
        check.run()
    }

    private fun finishRead(request: PendingRequest, view: WebView, url: String) {
        view.evaluateJavascript(DOCUMENT_SCRIPT) { value ->
            if (!isCurrent(request) || view.url != url) return@evaluateJavascript
            val document = parseDocument(value)
            if (document == null) {
                finish(request, errorCode = "page_unavailable", errorMessage = "The page content could not be read.")
                return@evaluateJavascript
            }
            finish(request, mapOf(
                "url" to url,
                "data" to document.html,
                "statusCode" to request.statusCode,
                "headers" to request.headers.toMap()
            ))
        }
    }

    private fun parseDocument(value: String?): DocumentState? {
        if (value == null) return null
        return try {
            val document = JSONTokener(value).nextValue() as? JSONObject ?: return null
            DocumentState(document.optString("html"), document.optBoolean("challenge"))
        } catch (_: Exception) {
            null
        }
    }

    private fun applyProxy(request: PendingRequest, proxyMode: String, proxyAddress: String?, load: () -> Unit) {
        proxyCoordinator.acquire(
            WebViewProxyCoordinator.Owner.JAPANESE_ASMR,
            proxyMode,
            proxyAddress
        ) { failure ->
            if (!isCurrent(request)) return@acquire
            if (failure != null) {
                finish(
                    request,
                    errorCode = if (failure.code == "proxy_configuration_failed") {
                        if (request.isRead) "network_error" else "verification_unavailable"
                    } else {
                        failure.code
                    },
                    errorMessage = failure.message
                )
            } else {
                try {
                    load()
                } catch (error: Exception) {
                    finish(
                        request,
                        errorCode = if (request.isRead) "network_error" else "verification_unavailable",
                        errorMessage = error.message
                    )
                }
            }
        }
    }

    private fun isProxyArgumentsValid(proxyMode: String?, proxyAddress: String?): Boolean {
        return proxyMode in listOf("direct", "system", "manual") &&
            (proxyMode != "manual" || !proxyAddress.isNullOrBlank())
    }

    private fun isCurrent(request: PendingRequest): Boolean {
        return pendingRequest === request && !request.finishing
    }

    private fun isSiteUrl(uri: Uri): Boolean {
        return uri.scheme == "https" && uri.host == "japaneseasmr.com" &&
            uri.port in listOf(-1, 443) && uri.userInfo == null
    }

    private fun dp(value: Int): Int = (value * activity.resources.displayMetrics.density).toInt()

    private fun finish(
        request: PendingRequest,
        value: Map<String, Any?>? = null,
        errorCode: String? = null,
        errorMessage: String? = null
    ) {
        if (request.finishing) return
        request.finishing = true
        request.dialog?.setOnDismissListener(null)
        request.dialog?.dismiss()
        request.dialog = null
        request.timeout?.let { handler.removeCallbacks(it) }
        request.timeout = null
        val webView = request.webView
        var completionErrorCode = errorCode
        var completionErrorMessage = errorMessage
        webView?.let { view ->
            request.pageCheck?.let { view.removeCallbacks(it) }
            request.pageCheck = null
            view.stopLoading()
            view.webChromeClient = null
            (view.parent as? ViewGroup)?.removeView(view)
        }

        val complete = Runnable {
            if (pendingRequest !== request) return@Runnable
            request.cleanup = null
            request.webView = null
            pendingRequest = null
            val finalErrorCode = completionErrorCode
            if (disposed) request.result.error("disposed", "The verification bridge was disposed.", null)
            else if (finalErrorCode == null) request.result.success(value)
            else request.result.error(finalErrorCode, completionErrorMessage, null)
        }

        val clearProxy = Runnable {
            if (pendingRequest !== request) return@Runnable
            request.cleanup = null
            proxyCoordinator.release(WebViewProxyCoordinator.Owner.JAPANESE_ASMR) { failure ->
                if (failure != null) {
                    completionErrorCode = "proxy_cleanup_failed"
                    completionErrorMessage = failure.message
                }
                complete.run()
            }
        }
        request.cleanup = clearProxy

        if (webView == null || disposed) {
            webView?.let { view ->
                view.webViewClient = WebViewClient()
                if (disposed) {
                    view.destroy()
                    if (retainedWebView === view) retainedWebView = null
                }
            }
            clearProxy.run()
            return
        }

        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                if (disposed) {
                    request.cleanup?.run()
                    return
                }
                if (pendingRequest !== request || !request.finishing || url != "about:blank" || view.url != url) return
                view.webViewClient = WebViewClient()
                request.cleanup?.run()
            }

            override fun onReceivedError(view: WebView, navigation: WebResourceRequest, error: WebResourceError) {
                if (disposed) {
                    request.cleanup?.run()
                    return
                }
                if (pendingRequest !== request || !navigation.isForMainFrame ||
                    navigation.url.toString() != "about:blank"
                ) return
                completionErrorCode = "webview_cleanup_failed"
                completionErrorMessage = error.description.toString()
                view.stopLoading()
                view.webViewClient = WebViewClient()
                request.cleanup?.run()
            }
        }
        try {
            webView.loadUrl("about:blank")
        } catch (error: Exception) {
            completionErrorCode = "webview_cleanup_failed"
            completionErrorMessage = error.message
            webView.stopLoading()
            webView.webViewClient = WebViewClient()
            request.cleanup?.run()
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        pendingRequest?.let { request ->
            if (!request.finishing) {
                finish(request, errorCode = "disposed", errorMessage = "The verification bridge was disposed.")
            }
            request.cleanup?.run()
        }
        retainedWebView?.let { view ->
            (view.parent as? ViewGroup)?.removeView(view)
            view.stopLoading()
            view.webChromeClient = null
            view.webViewClient = WebViewClient()
            view.destroy()
        }
        retainedWebView = null
        hasVerifiedSession = false
    }
}
