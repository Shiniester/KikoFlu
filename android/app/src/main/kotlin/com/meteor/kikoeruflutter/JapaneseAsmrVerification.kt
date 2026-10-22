package com.meteor.kikoeruflutter

import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
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

internal class JapaneseAsmrVerification(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val proxyCoordinator: WebViewProxyCoordinator
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "com.meteor.kikoeruflutter/japanese_asmr"
    }

    private class PendingRequest(val result: MethodChannel.Result) {
        var dialog: Dialog? = null
        var webView: WebView? = null
        var finishing = false
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private var pendingRequest: PendingRequest? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "verify") {
            result.notImplemented()
            return
        }
        if (pendingRequest != null) {
            result.error("already_active", "A site verification is already active.", null)
            return
        }

        val url = call.argument<String>("url")
        val proxyMode = call.argument<String>("proxyMode")
        val proxyAddress = call.argument<String>("proxyAddress")
        val title = call.argument<String>("title")
        val closeLabel = call.argument<String>("closeLabel")
        if (url == null || !isSiteUrl(Uri.parse(url)) ||
            proxyMode !in listOf("direct", "system", "manual") ||
            (proxyMode == "manual" && proxyAddress.isNullOrBlank()) ||
            title.isNullOrBlank() || closeLabel.isNullOrBlank()
        ) {
            result.error("invalid_arguments", "Invalid site verification arguments.", null)
            return
        }

        val request = PendingRequest(result)
        pendingRequest = request
        try {
            val supportsProxy = WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)
            if (!supportsProxy) {
                finish(request, errorCode = "proxy_unsupported",
                    errorMessage = "This Android WebView cannot use the selected proxy mode.")
                return
            }

            val webView = WebView(activity)
            request.webView = webView
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

            val progress = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal)
            var pageFailed = false
            webView.webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView, newProgress: Int) {
                    progress.progress = newProgress
                    progress.visibility = if (newProgress == 100) View.GONE else View.VISIBLE
                }
            }
            webView.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    return request.isForMainFrame && !isSiteUrl(request.url)
                }

                override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                    pageFailed = false
                    if (url == null || !isSiteUrl(Uri.parse(url))) {
                        pageFailed = true
                        view.stopLoading()
                    }
                }

                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) pageFailed = true
                }

                override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                    if (request.isForMainFrame) pageFailed = true
                }

                override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                    pageFailed = true
                    handler.cancel()
                }

                override fun onPageFinished(view: WebView, url: String?) {
                    if (request.finishing || pageFailed || url == null ||
                        view.url != url || !isSiteUrl(Uri.parse(url))
                    ) return
                    view.evaluateJavascript(
                        "location.origin === 'https://japaneseasmr.com' && " +
                            "document.querySelector('#site-main, .site-main') !== null"
                    ) { loaded ->
                        if (loaded == "true" && !request.finishing && !pageFailed && view.url == url) {
                            val cookie = CookieManager.getInstance().getCookie(url)
                                ?.split(';')
                                ?.map { it.trim() }
                                ?.firstOrNull { it.startsWith("cf_clearance=") }
                                .orEmpty()
                            finish(request, mapOf("cookie" to cookie, "userAgent" to view.settings.userAgentString))
                        }
                    }
                }
            }

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
            dialog.setOnDismissListener { finish(request) }
            dialog.show()
            dialog.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)

            val load = Runnable {
                if (!request.finishing) webView.loadUrl(url)
            }
            proxyCoordinator.acquire(
                WebViewProxyCoordinator.Owner.JAPANESE_ASMR,
                proxyMode!!,
                proxyAddress
            ) { failure ->
                if (failure != null) {
                    finish(
                        request,
                        errorCode = if (failure.code == "proxy_configuration_failed") {
                            "verification_unavailable"
                        } else {
                            failure.code
                        },
                        errorMessage = failure.message
                    )
                } else {
                    load.run()
                }
            }
        } catch (error: Exception) {
            finish(request, errorCode = "verification_unavailable", errorMessage = error.message)
        }
    }

    private fun isSiteUrl(uri: Uri): Boolean {
        return uri.scheme == "https" && uri.host == "japaneseasmr.com" &&
            uri.port in listOf(-1, 443) && uri.userInfo == null
    }

    private fun dp(value: Int): Int = (value * activity.resources.displayMetrics.density).toInt()

    private fun finish(
        request: PendingRequest,
        value: Map<String, String>? = null,
        errorCode: String? = null,
        errorMessage: String? = null
    ) {
        if (request.finishing) return
        request.finishing = true
        request.dialog?.setOnDismissListener(null)
        request.dialog?.dismiss()
        request.dialog = null
        request.webView?.apply {
            stopLoading()
            webChromeClient = null
            webViewClient = WebViewClient()
            (parent as? ViewGroup)?.removeView(this)
            destroy()
        }
        request.webView = null

        val complete = Runnable {
            if (pendingRequest === request) {
                pendingRequest = null
                if (errorCode == null) request.result.success(value)
                else request.result.error(errorCode, errorMessage, null)
            }
        }
        proxyCoordinator.release(WebViewProxyCoordinator.Owner.JAPANESE_ASMR) { failure ->
            if (failure != null) {
                if (pendingRequest === request) {
                    pendingRequest = null
                    request.result.error("proxy_cleanup_failed", failure.message, null)
                }
            } else {
                complete.run()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pendingRequest?.let { finish(it) }
    }
}
