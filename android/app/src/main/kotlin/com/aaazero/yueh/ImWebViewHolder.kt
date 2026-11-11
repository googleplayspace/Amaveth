package com.aaazero.yueh

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.MutableContextWrapper
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject

/**
 * Spec 8.4 / 10.5 / 10.6: the single IM WebView, owned by the process rather than by an
 * Activity. ImActivity only attaches and detaches it. Mock decisions belong to ShellStartup.
 */
internal object ImWebViewHolder {
    private class Config(val url: String, val origin: String, val script: String, val uaSuffix: String)

    private var config: Config? = null
    private var webView: WebView? = null
    private var scriptHandler: ScriptHandler? = null
    private var generation = 0
    var entryLoadCount = 0
        private set
    /** Page URL to restore after a rebuild; null means load the entry URL. */
    private var pendingUrl: String? = null
    private var entryReloadPending = false
    private var pendingTerminate: ((Boolean) -> Unit)? = null
    private val handler = Handler(Looper.getMainLooper())

    /** True once Dart asked for IM in this process; false after process death. */
    var opened = false
        private set
    var host: ImActivity? = null
        private set
    var loading = false
        private set
    var error: String? = null
        private set

    /** Spec 9.6: the page reported eventWebReady; the system splash may go. */
    var webReady = false
        private set

    /**
     * Spec 11.2 recovery, gated on webReady like the cold-start splash (9.6): from the
     * moment the hung renderer is ended until the replacement page reports webReady, the
     * Activity shows the brand cover instead of a frozen, blank or half-drawn page.
     * Capped like the splash, so a page that never gets ready is still shown.
     */
    var recovering = false
        private set
    private val endRecoveryCover = Runnable { setRecovering(false) }
    private fun setRecovering(value: Boolean) {
        handler.removeCallbacks(endRecoveryCover)
        if (value) handler.postDelayed(endRecoveryCover, RECOVERY_COVER_LIMIT_MS)
        if (recovering == value) return
        recovering = value
        android.util.Log.i("SSGShell", if (value) "recovery cover on" else "recovery cover off")
        host?.renderUi()
    }

    /** IM is the face of this process: opened by Dart, or preloaded from the last launch. */
    val active: Boolean get() = opened || webView != null

    /**
     * Until Dart is attached (imOpen answered), page and Activity events are queued and
     * replayed in order, so a preloaded page cannot lose eventWebReady / eventLogin.
     */
    private var live = false
    private val queued = ArrayList<() -> Unit>()

    private fun dispatch(action: () -> Unit) {
        if (live) action() else if (queued.size < MAX_QUEUED) queued.add(action)
    }

    /** Called after imOpen's result has reached Dart, which then knows the view id. */
    fun goLive() {
        if (live || replayScheduled) return
        // A preloaded page can report webReady before it has drawn (the splash holds the
        // first frame), and window.__ssgShell appears only afterwards. Dart reacts to the
        // replayed webReady / login by calling __ssgShell (openChat for a push tap), so
        // replay once it exists, as on a normal start. A page that is not ready yet
        // (Dart opened IM first) replays at once.
        val web = webView
        if (web == null || !webReady) return replay()
        replayScheduled = true
        val started = SystemClock.elapsedRealtime()
        fun check() {
            val current = webView
            if (current == null || SystemClock.elapsedRealtime() - started >= SHELL_WAIT_MS) {
                android.util.Log.i("SSGShell", "replay without __ssgShell after ${SystemClock.elapsedRealtime() - started}ms")
                return replay()
            }
            current.evaluateJavascript("!!(window.__ssgShell)") { found ->
                if (found == "true") {
                    android.util.Log.i("SSGShell", "replay after __ssgShell ready: ${SystemClock.elapsedRealtime() - started}ms")
                    replay()
                } else handler.postDelayed({ check() }, 100)
            }
        }
        check()
    }

    private var replayScheduled = false

    private fun replay() {
        if (live) return
        live = true
        val pending = queued.toList()
        queued.clear()
        pending.forEach { it() }
    }

    fun event(type: String, args: Map<String, Any?> = emptyMap()) {
        dispatch { ShellRuntime.bridge?.imEvent(type, args) }
    }

    private fun send(type: String, args: Map<String, Any?> = emptyMap()) = event(type, args)

    fun prepare(ctx: Context, url: String, origin: String, script: String, uaSuffix: String): Map<String, Any> {
        val next = Config(url, origin, script, uaSuffix)
        save(ctx, next)
        val web = webView
        val current = config
        config = next
        if (web != null && current != null) {
            if (current.url != next.url || current.origin != next.origin) {
                // The server moved B: the preloaded page is the wrong site.
                pendingUrl = next.url
                entryReloadPending = true
                live = false
                queued.clear()
                web.stopLoading()
                webReady = false
                loading = true
                error = null
                scriptHandler?.remove()
                scriptHandler = WebViewCompat.addDocumentStartJavaScript(web, next.script, setOf(next.origin))
                web.settings.userAgentString = WebSettings.getDefaultUserAgent(ctx) + next.uaSuffix
                setRecovering(true)
                entryLoadCount++
                web.loadUrl(next.url)
                host?.renderUi()
            } else {
                if (current.uaSuffix != next.uaSuffix) {
                    web.settings.userAgentString = WebSettings.getDefaultUserAgent(ctx) + next.uaSuffix
                }
                if (current.script != next.script) {
                    // The running document already ran the saved copy; this one applies from the next load.
                    scriptHandler?.remove()
                    scriptHandler = WebViewCompat.addDocumentStartJavaScript(web, next.script, setOf(next.origin))
                }
            }
        }
        return mapOf(
            "documentStart" to WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT),
            "ua" to WebSettings.getDefaultUserAgent(ctx) + uaSuffix,
        )
    }

    /** HTTP 404 deactivates immediately, without deleting website data. */
    fun forget(ctx: Context) {
        opened = false
        live = false
        queued.clear()
        config = null
        pendingUrl = null
        error = null
        setRecovering(false)
        destroyCurrent()
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove(KEY_URL).remove(KEY_ORIGIN).remove(KEY_SCRIPT).remove(KEY_UA).apply()
    }

    private fun save(ctx: Context, cfg: Config) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_URL, cfg.url).putString(KEY_ORIGIN, cfg.origin)
            .putString(KEY_SCRIPT, cfg.script).putString(KEY_UA, cfg.uaSuffix).apply()
    }

    /** Returns the view id, or null when this device cannot host IM (see Dart's error state). */
    fun open(ctx: Context): Int? {
        if (config == null || !ShellStartup.isB) return null
        opened = true
        ensure(ctx) ?: return null
        return generation
    }

    private fun ensure(ctx: Context): WebView? {
        webView?.let { return it }
        val cfg = config ?: return null
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) return null
        // A rebuild resumes the page the user was on instead of dropping them back
        // to the entry route; only a trusted same-origin URL is reused.
        val resume = pendingUrl?.takeIf { trusted(Uri.parse(it)) }
        pendingUrl = null
        setRecovering(true)
        return create(ctx, cfg).also {
            webView = it
            host?.attachWeb(it)
            ShellStartup.log("webview.loadUrl cachedOrEntry")
            entryLoadCount++
            it.loadUrl(resume ?: cfg.url)
        }
    }

    /**
     * Last-resort recovery: the old instance cannot be reused. The page URL is
     * kept so the user does not lose their place, and cookies, cache, DOM storage,
     * IndexedDB and the Service Worker are untouched (spec 8.3).
     */
    fun rebuild(ctx: Context): Int? {
        setRecovering(true)
        // onRenderProcessGone already destroyed the instance and saved its URL;
        // keep that instead of overwriting it with null.
        if (entryReloadPending) pendingUrl = config?.url
        else currentUrl()?.let { pendingUrl = it }
        entryReloadPending = false
        destroyCurrent()
        return open(ctx)
    }

    fun current(): WebView? = webView
    fun currentUrl(): String? = webView?.url
    fun reload() { webView?.reload() }
    fun load(url: String) { webView?.loadUrl(url) }

    fun evaluate(source: String, done: (String?) -> Unit) {
        val web = webView ?: return done(null)
        web.evaluateJavascript(source) { done(it) }
    }

    fun setUi(loading: Boolean, error: String?) {
        this.loading = loading
        this.error = error
        host?.renderUi()
    }

    /** Spec 11.2: never attach a replacement to a CPU-bound renderer; confirm its exit first. */
    fun terminate(done: (Boolean) -> Unit) {
        val web = webView ?: return done(true)
        if (pendingTerminate != null) return done(false)
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.GET_WEB_VIEW_RENDERER) ||
            !WebViewFeature.isFeatureSupported(WebViewFeature.WEB_VIEW_RENDERER_TERMINATE)
        ) {
            // Spec 11.2: old kernels cannot end the renderer; only a new process escapes it.
            if (!restartProcess()) done(false)
            return
        }
        val renderer = WebViewCompat.getWebViewRenderProcess(web) ?: return done(false)
        pendingTerminate = done
        // The page is about to vanish: cover it now, through the rebuild, until webReady.
        setRecovering(true)
        if (!renderer.terminate()) {
            pendingTerminate = null
            setRecovering(false)
            return done(false)
        }
        handler.postDelayed({
            if (pendingTerminate === done) {
                pendingTerminate = null
                setRecovering(false)
                done(false)
            }
        }, 2500)
    }

    /** Bounded across restarts, since the backoff kept in Dart does not survive one. */
    private fun restartProcess(): Boolean {
        val activity = host ?: return false
        val prefs = activity.getSharedPreferences("im_shell", Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        if (now - prefs.getLong(LAST_RESTART, 0) < RESTART_BACKOFF_MS) return false
        val launch = activity.packageManager.getLaunchIntentForPackage(activity.packageName) ?: return false
        prefs.edit().putLong(LAST_RESTART, now).commit()
        android.util.Log.i("SSGShell", "renderer cannot be terminated; restarting process")
        activity.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        android.os.Process.killProcess(android.os.Process.myPid())
        return true
    }

    private const val LAST_RESTART = "lastRendererRestart"
    private const val RESTART_BACKOFF_MS = 600_000L
    private const val PREFS = "im_shell"
    private const val KEY_URL = "preload.url"
    private const val KEY_ORIGIN = "preload.origin"
    private const val KEY_SCRIPT = "preload.script"
    private const val KEY_UA = "preload.uaSuffix"
    private const val MAX_QUEUED = 500
    private const val SHELL_WAIT_MS = 3_000L
    private const val RECOVERY_COVER_LIMIT_MS = 30_000L

    fun onHostAttached(activity: ImActivity) {
        host = activity
        val web = webView ?: return
        (web.context as? MutableContextWrapper)?.baseContext = activity
        activity.attachWeb(web)
    }

    fun onHostDetached(activity: ImActivity) {
        if (host !== activity) return
        host = null
        val web = webView ?: return
        (web.parent as? ViewGroup)?.removeView(web)
        (web.context as? MutableContextWrapper)?.baseContext = activity.applicationContext
    }

    private fun destroyCurrent() {
        val web = webView ?: return
        webView = null
        scriptHandler = null
        webReady = false
        (web.parent as? ViewGroup)?.removeView(web)
        web.destroy()
    }

    private fun trusted(uri: Uri?): Boolean {
        val cfg = config ?: return false
        if (uri == null || uri.scheme != "https" || uri.host == null) return false
        val origin = Uri.parse(cfg.origin)
        return uri.host == origin.host && uri.port == origin.port
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    private fun create(ctx: Context, cfg: Config): WebView {
        val app = ctx.applicationContext
        val base: Context = host ?: app
        val web = WebView(MutableContextWrapper(base))
        val id = ++generation
        webReady = false
        WebView.setWebContentsDebuggingEnabled(app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        web.setBackgroundColor(Color.WHITE)
        // Spec 8.4 (5): keep the renderer while visible; it drops back by itself when hidden.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            web.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, true)
        }
        web.overScrollMode = View.OVER_SCROLL_NEVER
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            mediaPlaybackRequiresUserGesture = false
            loadsImagesAutomatically = true
            blockNetworkImage = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_DEFAULT
            textZoom = 100
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            setSupportMultipleWindows(true)
            javaScriptCanOpenWindowsAutomatically = true
            allowFileAccess = false
            userAgentString = WebSettings.getDefaultUserAgent(app) + cfg.uaSuffix
        }
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
        web.addJavascriptInterface(JsBridge(web, id), "jsBridge")
        scriptHandler = WebViewCompat.addDocumentStartJavaScript(web, cfg.script, setOf(cfg.origin))
        web.webViewClient = Client()
        web.webChromeClient = Chrome()
        return web
    }

    /** Spec 3.3: object name and both overloads are part of the contract. */
    private class JsBridge(private val web: WebView, private val id: Int) {
        @JavascriptInterface
        fun postMessage(name: String, json: String) {
            web.post {
                if (name == "eventWebReady" && web === webView) {
                    webReady = true
                    setRecovering(false)
                    host?.renderUi()
                    // Diagnostics: native → Web callbacks (spec 4) need this from webReady on.
                    web.evaluateJavascript("!!(window.__ssgShell)") {
                        android.util.Log.i("SSGShell", "webReady: __ssgShell=$it")
                    }
                }
                dispatch { ShellRuntime.bridge?.webEvent(name, json, id) }
            }
        }

        @JavascriptInterface
        fun postMessage(json: String) {
            val event = try { JSONObject(json).optString("eventName") } catch (_: Exception) { return }
            if (event !in EVENTS) return
            postMessage("event" + event.replaceFirstChar { it.uppercase() }, json)
        }

        private companion object {
            val EVENTS = setOf(
                "webReady", "register", "login", "logout", "messageSent",
                "webAlive", "chatOpen", "chatClose", "chatRead", "unreadCount",
            )
        }
    }

    private class Client : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val uri = request.url
            val scheme = uri.scheme?.lowercase()
            // Spec 7.1: same-origin HTTPS and blob:/data: (media preview) pass through untouched.
            if (trusted(uri) || scheme == "blob" || scheme == "data" || uri.toString() == "about:blank") return false
            if (request.isForMainFrame) openExternal(view.context, uri)
            return true
        }

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            if (view === webView) {
                entryReloadPending = false
                send("loadStart", mapOf("url" to url))
            }
        }

        override fun onPageFinished(view: WebView, url: String?) {
            if (view === webView) send("loadStop", mapOf("url" to url))
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (view === webView && request.isForMainFrame) send("loadError", mapOf("url" to request.url.toString()))
        }

        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
            if (view === webView && request.isForMainFrame) {
                send("httpError", mapOf("url" to request.url.toString(), "status" to response.statusCode))
            }
        }

        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            handler.cancel()
            send("tls", mapOf("host" to Uri.parse(error.url).host))
        }

        /** Spec 7.1: the old instance is unusable; returning false would kill the app. */
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            if (view === webView) {
                // Keep the URL: the rebuild Dart is about to run resumes this page.
                pendingUrl = view.url
                destroyCurrent()
                val done = pendingTerminate
                pendingTerminate = null
                // A requested terminate is answered once, through imTerminate, and Dart
                // rebuilds from that. Also sending "gone" made Dart rebuild a second time,
                // tearing down the replacement that had just started loading.
                if (done != null) done(true) else send("gone")
            } else {
                (view.parent as? ViewGroup)?.removeView(view)
                view.destroy()
            }
            return true
        }
    }

    private class Chrome : WebChromeClient() {
        override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
            val activity = host
            if (activity == null) callback.onReceiveValue(null) else activity.pickMedia(callback, params)
            return true
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            val activity = host
            // Spec 6.1: the page only ever gets the microphone, and only from our origin.
            if (activity == null || !trusted(request.origin) ||
                PermissionRequest.RESOURCE_AUDIO_CAPTURE !in request.resources
            ) return request.deny()
            activity.requestMicrophone(request)
        }

        override fun onPermissionRequestCanceled(request: PermissionRequest) {
            host?.cancelMicrophone(request)
        }

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            val activity = host
            if (activity == null) callback.onCustomViewHidden() else activity.showCustomView(view, callback)
        }

        override fun onHideCustomView() { host?.hideCustomView() }

        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
            send("console", mapOf("level" to message.messageLevel().name, "message" to message.message().take(8192)))
            return true
        }

        /** window.open / target=_blank: capture the URL with a throwaway view, never a second page. */
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
            val temp = WebView(view.context)
            var handled = false
            fun route(url: String?) {
                if (handled || url.isNullOrEmpty() || url == "about:blank") return
                handled = true
                val uri = Uri.parse(url)
                // Off-site links open natively: with B cached there may be no Flutter
                // Activity for Dart's url_launcher. Same-site URLs still go to Dart.
                if (trusted(uri) || uri.scheme == "blob" || uri.scheme == "data") send("window", mapOf("url" to url))
                else openExternal(view.context, uri)
                temp.post { temp.destroy() }
            }
            temp.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                    route(request.url.toString())
                    return true
                }

                override fun onPageStarted(v: WebView, url: String?, favicon: Bitmap?) {
                    route(url)
                    v.stopLoading()
                }
            }
            (resultMsg.obj as WebView.WebViewTransport).webView = temp
            resultMsg.sendToTarget()
            return true
        }
    }

    private fun openExternal(context: Context, uri: Uri) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            android.util.Log.i("SSGShell", "no handler for scheme ${uri.scheme}")
        }
    }
}