package dev.flutterreactembed

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.MutableContextWrapper
import android.graphics.Color
import android.net.Uri
import android.util.Log
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.annotation.AnyThread
import androidx.annotation.MainThread
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONException
import org.json.JSONObject

/**
 * One JavaScript runtime: a WebView document hosting a production React SPA.
 *
 * ### Threading
 * All state is confined to the main thread. Frames from JS arrive on the main
 * thread (WebMessageListener) or on WebView's JavaBridge thread
 * (`@JavascriptInterface` fallback); both hop to [EmbedThreads.onBridge] for
 * validation and back to main for delivery, preserving order.
 *
 * ### Lifecycle
 * The WebView is created at boot with a [MutableContextWrapper] over the
 * application context, so the document loads before any view is on screen.
 * [attach] swaps in the hosting Activity's context; [detach] swaps the
 * application context back so a retained runtime never pins an Activity.
 * [dispose] tears the WebView down completely.
 *
 * One WebView is one document, so a runtime is attached to at most one
 * platform view at a time.
 *
 * ### JS contract
 * - `window.__FRE_BOOT__`: `{runtimeId, contractVersion, transport, platform}`.
 * - JS -> host: `window.__freNative.postMessage(frameString)`.
 * - host -> JS: `window.__freReceive(frameString)`, which JS must define
 *   before posting its first frame. The first frame is the readiness signal:
 *   frames for JS are queued until it arrives.
 * - Host lifecycle notifications: `$/mount`, `$/updateProps`, `$/unmount`.
 */
@SuppressLint("SetJavaScriptEnabled")
internal class WebRuntime(
    override val id: String,
    private val config: RuntimeConfig,
    private val appContext: Context,
    private val assetDir: String,
    private val threads: EmbedThreads,
    private val events: RuntimeEvents,
) : EmbedRuntime {
    private enum class Phase { CREATED, BOOTING, READY, CRASHED, DISPOSED }

    private val contextWrapper = MutableContextWrapper(appContext)
    private val useMessageListener = WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
    private val useDocumentStartScript = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)

    override val engine: String = Protocol.ENGINE_WEB

    private var phase = Phase.CREATED
    private var webView: WebView? = null
    private var replyProxy: JavaScriptReplyProxy? = null
    private val pendingOutbound = ArrayDeque<String>()
    private var bootListener: ((code: String?, message: String?) -> Unit)? = null
    private val bootTimeout = Runnable {
        failBoot(Protocol.E_BOOT_TIMEOUT, "JS did not send its first frame within ${Protocol.BOOT_TIMEOUT_MS} ms")
    }

    /** Disposal flag readable from the JavaBridge thread. */
    @Volatile
    private var disposed = false

    /** Platform view currently showing this runtime, if any. */
    var attachedViewId: Int? = null
        private set

    /** Cache key under which JS keeps the React tree mounted while detached. */
    var retainedCacheKey: String? = null
        private set

    override fun retains(cacheKey: String): Boolean = retainedCacheKey == cacheKey

    // -------------------------------------------------------------------------
    // Boot
    // -------------------------------------------------------------------------

    /**
     * Creates the WebView and loads the bundle. [onResult] receives `(null,
     * null)` once JS has sent its first frame, or an error code and message.
     */
    @MainThread
    fun boot(onResult: (code: String?, message: String?) -> Unit) {
        check(phase == Phase.CREATED) { "Runtime $id already booted" }
        phase = Phase.BOOTING
        bootListener = onResult

        val view = try {
            WebView(contextWrapper)
        } catch (e: RuntimeException) {
            // Thrown when the WebView provider is missing, disabled or updating.
            failBoot(Protocol.E_ENGINE_INIT_FAILED, "WebView unavailable: ${e.message}")
            return
        }
        webView = view
        configure(view)
        installBridge(view)
        view.webViewClient = Client(buildAssetLoader())
        view.webChromeClient = ChromeClient()

        threads.main.postDelayed(bootTimeout, Protocol.BOOT_TIMEOUT_MS)
        view.loadUrl("${Protocol.ORIGIN}/")
    }

    private fun configure(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = true
        }
        view.setBackgroundColor(Color.TRANSPARENT)
        if (config.enableDebugging) {
            // Process-wide switch; only ever turned on, never off, by this plugin.
            WebView.setWebContentsDebuggingEnabled(true)
        }
    }

    private fun bootScript(): String {
        val boot = JSONObject()
            .put("runtimeId", id)
            .put("contractVersion", config.contractVersion)
            .put("transport", if (useMessageListener) "webMessageListener" else "javascriptInterface")
            .put("platform", "android")
        // With WebMessageListener, host frames arrive as `message` events on
        // the injected object; route them into the bridge's receiver.
        val routeListener = if (useMessageListener) {
            "var n=window.${Protocol.JS_OBJECT};if(n){n.onmessage=function(e){if(window.__freReceive)window.__freReceive(e.data);};}"
        } else {
            ""
        }
        return "(function(){if(window.__FRE_BOOT__)return;" +
            "Object.defineProperty(window,'__FRE_BOOT__',{value:Object.freeze($boot)});" +
            routeListener +
            "})();"
    }

    private fun buildAssetLoader(): WebViewAssetLoader {
        // Without document-start script support, the boot script is inlined
        // into index.html as it is served.
        val inline = if (useDocumentStartScript) null else bootScript()
        return WebViewAssetLoader.Builder()
            .setDomain(Protocol.ASSET_HOST)
            .addPathHandler("/", BundlePathHandler(appContext.assets, assetDir, inline))
            .build()
    }

    @SuppressLint("JavascriptInterface", "AddJavascriptInterface")
    private fun installBridge(view: WebView) {
        val origins = setOf(Protocol.ORIGIN)
        if (useDocumentStartScript) {
            WebViewCompat.addDocumentStartJavaScript(view, bootScript(), origins)
        }
        if (useMessageListener) {
            // Callback runs on the main thread; only our origin's main frame
            // can reach it (allowedOriginRules + isMainFrame).
            WebViewCompat.addWebMessageListener(view, Protocol.JS_OBJECT, origins) { _, message, sourceOrigin, isMainFrame, proxy ->
                if (!isMainFrame || sourceOrigin.host != Protocol.ASSET_HOST) {
                    return@addWebMessageListener
                }
                replyProxy = proxy
                receiveFromJs(message.data)
            }
        } else {
            // Legacy WebView (< 86): JavascriptInterface, invoked on the
            // JavaBridge thread. It cannot check origins itself; navigation is
            // pinned to our origin in shouldOverrideUrlLoading instead.
            view.addJavascriptInterface(JavaScriptBridge(this), Protocol.JS_OBJECT)
        }
    }

    // -------------------------------------------------------------------------
    // JS -> Dart
    // -------------------------------------------------------------------------

    @AnyThread
    private fun receiveFromJs(frame: String?) {
        if (disposed || frame == null) return
        threads.onBridge {
            val bytes = utf8Length(frame)
            threads.onMain {
                when {
                    disposed -> Unit
                    bytes > config.maxMessageBytes -> events.onError(
                        id, "Dropped a $bytes-byte frame from JS (limit ${config.maxMessageBytes})", null, false,
                    )
                    else -> deliverInbound(frame)
                }
            }
        }
    }

    @MainThread
    private fun deliverInbound(frame: String) {
        if (phase == Phase.BOOTING) {
            // First frame = JS bridge is ready: flush queued frames, finish boot.
            phase = Phase.READY
            threads.main.removeCallbacks(bootTimeout)
            flushPendingOutbound()
            bootListener?.invoke(null, null)
            bootListener = null
            events.onState(id, Protocol.STATE_READY)
        }
        events.onFrame(id, frame)
    }

    // -------------------------------------------------------------------------
    // Dart -> JS
    // -------------------------------------------------------------------------

    /** Validates [frame] off the main thread, then queues or posts it. */
    @MainThread
    override fun deliverFromDart(frame: String, onResult: (code: String?, message: String?) -> Unit) {
        threads.onBridge {
            val bytes = utf8Length(frame)
            threads.onMain {
                when {
                    bytes > config.maxMessageBytes ->
                        onResult(Protocol.E_PAYLOAD_TOO_LARGE, "Frame is $bytes bytes; limit is ${config.maxMessageBytes}")
                    disposed || phase == Phase.CRASHED ->
                        onResult(Protocol.E_ENGINE_DISPOSED, "Runtime $id is ${phase.name.lowercase()}")
                    else -> onResult(postToJs(frame), null)
                }
            }
        }
    }

    /** Returns an error code, or null on success. */
    @MainThread
    private fun postToJs(frame: String): String? {
        val view = webView ?: return Protocol.E_ENGINE_DISPOSED
        if (phase != Phase.READY) {
            if (pendingOutbound.size >= Protocol.MAX_PENDING_OUTBOUND) return Protocol.E_QUEUE_FULL
            pendingOutbound.addLast(frame)
            return null
        }
        val proxy = replyProxy
        if (proxy != null) {
            proxy.postMessage(frame)
        } else {
            view.evaluateJavascript("window.__freReceive&&window.__freReceive(${JSONObject.quote(frame)})", null)
        }
        return null
    }

    @MainThread
    private fun flushPendingOutbound() {
        while (pendingOutbound.isNotEmpty()) {
            postToJs(pendingOutbound.removeFirst())
        }
    }

    // -------------------------------------------------------------------------
    // Surfaces
    // -------------------------------------------------------------------------

    /**
     * Moves the WebView into [container] and mounts [params] in JS.
     * Returns an error message, or null on success.
     */
    @MainThread
    override fun attach(viewId: Int, container: FrameLayout, hostContext: Context, params: SurfaceParams): String? {
        val view = webView ?: return "Runtime $id is not available (${phase.name.lowercase()})"
        val current = attachedViewId
        if (current != null && current != viewId) {
            return "Runtime $id is already attached to view $current; a WebView document can only be shown once"
        }
        val props = try {
            Protocol.parseObject(params.initialPropsJson)
        } catch (e: JSONException) {
            return "initialPropsJson is not a JSON object: ${e.message}"
        }

        contextWrapper.baseContext = hostContext
        (view.parent as? ViewGroup)?.removeView(view)
        container.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        view.onResume()
        attachedViewId = viewId

        val reattached = params.cacheKey != null && params.cacheKey == retainedCacheKey
        retainedCacheKey = params.cacheKey
        postToJs(
            Protocol.notification(
                "\$/mount",
                JSONObject()
                    .put("viewId", viewId)
                    .put("moduleName", params.moduleName)
                    .put("props", props)
                    .put("cacheKey", params.cacheKey ?: JSONObject.NULL)
                    .put("reattached", reattached),
            ),
        )
        return null
    }

    /**
     * Removes the WebView from its container and releases the host Activity.
     * With a [cacheKey], JS keeps the React tree mounted for a later reattach;
     * otherwise it is unmounted.
     */
    @MainThread
    override fun detach(viewId: Int, cacheKey: String?) {
        if (attachedViewId != viewId) return
        attachedViewId = null
        webView?.let { view ->
            (view.parent as? ViewGroup)?.removeView(view)
            view.onPause()
        }
        contextWrapper.baseContext = appContext
        if (cacheKey == null) {
            retainedCacheKey = null
            postToJs(Protocol.notification("\$/unmount", JSONObject().put("viewId", viewId)))
        }
    }

    /** Drops the retained React tree for [cacheKey] if it is not on screen. */
    @MainThread
    override fun evictCached(cacheKey: String) {
        if (retainedCacheKey != cacheKey || attachedViewId != null) return
        retainedCacheKey = null
        postToJs(Protocol.notification("\$/unmount", JSONObject().put("cacheKey", cacheKey)))
    }

    /** Sends new props for [viewId]. Returns an error code, or null. */
    @MainThread
    override fun updateProps(viewId: Int, props: JSONObject): String? {
        if (attachedViewId != viewId) return Protocol.E_UNKNOWN_VIEW
        return postToJs(Protocol.notification("\$/updateProps", JSONObject().put("viewId", viewId).put("props", props)))
    }

    // -------------------------------------------------------------------------
    // Failure and teardown
    // -------------------------------------------------------------------------

    @MainThread
    private fun failBoot(code: String, message: String) {
        val listener = bootListener ?: return
        bootListener = null
        threads.main.removeCallbacks(bootTimeout)
        listener(code, message)
    }

    @MainThread
    private fun onRendererGone(crashed: Boolean) {
        val reason = if (crashed) "crashed" else "was killed by the system to reclaim memory"
        if (phase == Phase.BOOTING) {
            failBoot(Protocol.E_ENGINE_INIT_FAILED, "WebView renderer $reason during boot")
        } else {
            events.onError(id, "WebView renderer $reason", null, true)
            events.onState(id, Protocol.STATE_CRASHED)
        }
        phase = Phase.CRASHED
        // A WebView whose renderer is gone cannot be reused; it must be destroyed.
        destroyWebView()
    }

    /** Releases every resource. Idempotent. */
    @MainThread
    override fun dispose() {
        if (disposed) return
        disposed = true
        failBoot(Protocol.E_ENGINE_DISPOSED, "Runtime $id was disposed during boot")
        phase = Phase.DISPOSED
        threads.main.removeCallbacks(bootTimeout)
        pendingOutbound.clear()
        attachedViewId = null
        retainedCacheKey = null
        destroyWebView()
    }

    @MainThread
    private fun destroyWebView() {
        val view = webView ?: return
        webView = null
        replyProxy = null
        (view.parent as? ViewGroup)?.removeView(view)
        if (useMessageListener) {
            WebViewCompat.removeWebMessageListener(view, Protocol.JS_OBJECT)
        } else {
            view.removeJavascriptInterface(Protocol.JS_OBJECT)
        }
        view.stopLoading()
        // Drop references to our clients so nothing reachable from the
        // (possibly still referenced) WebView points back at this runtime.
        view.webChromeClient = null
        view.webViewClient = WebViewClient()
        view.loadUrl("about:blank")
        view.onPause()
        view.removeAllViews()
        view.destroy()
        contextWrapper.baseContext = appContext
    }

    // -------------------------------------------------------------------------
    // WebView clients
    // -------------------------------------------------------------------------

    private inner class Client(private val assetLoader: WebViewAssetLoader) : WebViewClient() {
        // Called on a WebView background thread.
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
            assetLoader.shouldInterceptRequest(request.url)

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url
            if (url.scheme == "https" && url.host == Protocol.ASSET_HOST) return false
            // Everything else leaves the bundle: open user-initiated http(s)
            // links externally, block the rest.
            if (request.isForMainFrame && request.hasGesture() && (url.scheme == "https" || url.scheme == "http")) {
                openExternally(url)
            }
            return true
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame && phase == Phase.BOOTING) {
                failBoot(Protocol.E_ENGINE_INIT_FAILED, "Failed to load bundle: ${error.description}")
            }
        }

        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
            if (request.isForMainFrame && phase == Phase.BOOTING) {
                failBoot(Protocol.E_BUNDLE_NOT_FOUND, "Bundle entry returned HTTP ${response.statusCode}")
            }
        }

        // Without this override the app process is killed with the renderer.
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            onRendererGone(detail.didCrash())
            return true
        }
    }

    private inner class ChromeClient : WebChromeClient() {
        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
            if (message.messageLevel() == ConsoleMessage.MessageLevel.ERROR && message.message().startsWith("Uncaught")) {
                events.onError(id, message.message(), "${message.sourceId()}:${message.lineNumber()}", false)
            }
            return false // Keep logcat output.
        }
    }

    private fun openExternally(url: Uri) {
        val intent = Intent(Intent.ACTION_VIEW, url).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            appContext.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            Log.w(TAG, "No activity can open $url")
        }
    }

    /**
     * Legacy transport. Holds the runtime only through the WebView that owns
     * it, and ignores calls after disposal (they can race on JavaBridge).
     */
    private class JavaScriptBridge(private val runtime: WebRuntime) {
        @JavascriptInterface
        fun postMessage(frame: String?) {
            runtime.receiveFromJs(frame)
        }
    }
}
