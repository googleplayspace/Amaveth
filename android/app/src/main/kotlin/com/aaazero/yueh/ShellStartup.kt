package com.aaazero.yueh

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.webkit.WebViewCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.Executors

/** §2.3/9.6: native is the sole mock decision/cache owner, before Dart exists. */
internal object ShellStartup {
    private lateinit var app: Application
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private var checking = false
    private var requestCount = 0
    private var url: String? = null
    private var face = "pending"
    var awaitingA = false
        private set
    private var revision = 0
    private var reason = "initial"
    private var started = 0
    private var background = false
    var startedAt = 0L
        private set
    val waiting get() = face == "pending"
    val isA get() = face == "a"
    val isB get() = face == "b"
    fun accepts(raw: String) = isB && raw == url
    private val prefs get() = app.getSharedPreferences("im_shell", Context.MODE_PRIVATE)

    fun start(application: Application) {
        app = application
        startedAt = SystemClock.elapsedRealtime()
        log("application.onCreate")
        val old = app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.remoteConfig.url", null)
        url = prefs.getString("preload.url", null)?.takeIf(::validUrl) ?: old?.takeIf(::validUrl)
        url?.let {
            face = "b"
            prepare(it)
            ImWebViewHolder.open(app)
        }
        // Observe process foreground, not transitions between the two host Activities.
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                if (++started == 1 && background) { background = false; refresh() }
            }
            override fun onActivityStopped(activity: Activity) {
                started--
                if (started == 0) background = true
            }
            override fun onActivityCreated(activity: Activity, state: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityDestroyed(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
        })
        refresh()
    }

    fun attach(messenger: BinaryMessenger) {
        if (channel != null) return
        channel = MethodChannel(messenger, "yueh/startup").also { c ->
            c.setMethodCallHandler { call, result ->
                when (call.method) {
                    "snapshot" -> result.success(snapshot())
                    "refresh" -> { refresh(); result.success(null) }
                    "ackA" -> {
                        if (isA && call.argument<Int>("revision") == revision) {
                            awaitingA = false
                            (ShellRuntime.top as? FlutterHostActivity)?.syncStartupCover()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
    private fun snapshot(): Map<String, Any?> = mapOf("face" to face, "url" to url,
        "revision" to revision, "reason" to reason)
    private fun publish() {
        if (isA && ImWebViewHolder.host != null) awaitingA = true
        revision++
        channel?.invokeMethod("decision", snapshot())
        ImWebViewHolder.host?.decisionChanged()
    }
    private fun prepare(raw: String) {
        val uri = URI(raw)
        val origin = "https://${uri.host.lowercase(java.util.Locale.ROOT)}" +
            (if (uri.port >= 0 && uri.port != 443) ":${uri.port}" else "")
        val pkg = app.packageManager.getPackageInfo(app.packageName, 0)
        val ver = pkg.versionName.orEmpty()
        val metadata = JSONObject().put("platform", "android").put("bundleId", app.packageName)
            .put("shellVersion", ver).put("webviewVersion", WebViewCompat.getCurrentWebViewPackage(app)?.versionName ?: "unknown")
            .put("deviceModel", android.os.Build.MODEL).put("osVersion", android.os.Build.VERSION.RELEASE)
        val script = "if(window===window.top&&location.origin===${JSONObject.quote(origin)}){window.__SSG_SHELL__=$metadata;}"
        ImWebViewHolder.prepare(app, raw, origin, script, " SSGShell/$ver Android")
    }
    private fun apply(status: Int, body: String) {
        log("mock.response status=$status")
        if (status == 404) {
            url = null; face = "a"; reason = "http404"
            ImWebViewHolder.forget(app)
            app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
                .remove("flutter.remoteConfig.url").apply()
            publish()
            return
        }
        val next = if (status == 200) parseUrl(body) else null
        if (next != null) {
            val changed = url != next || face != "b"
            url = next; face = "b"; reason = "http200"
            if (changed) {
                prepare(next)
                ImWebViewHolder.open(app)
                publish()
            }
        } else if (url == null && face == "pending") {
            // User clarification 2026-11-11: no cached B + exhausted request -> A,
            // but this is not a persisted "disabled" result. Foreground retries remain on.
            face = "a"; reason = "unavailableWithoutCache"; publish()
        }
    }
    fun refresh() {
        if (checking) return
        checking = true
        requestCount++
        log("mock.request")
        worker.execute {
            var status = -1
            var body = ""
            // One bounded request cycle, including body reads (max 256 KiB).
            for (attempt in 0..2) {
                var connection: HttpURLConnection? = null
                try {
                    connection = URL(BuildConfig.SHELL_CONFIG_URL).openConnection() as HttpURLConnection
                    connection.connectTimeout = 3000
                    connection.readTimeout = 3000
                    connection.instanceFollowRedirects = false
                    connection.setRequestProperty("Accept", "application/json")
                    status = connection.responseCode
                    if (status == 200) {
                        val deadline = SystemClock.elapsedRealtime() + 3000
                        val buffer = java.io.ByteArrayOutputStream()
                        connection.inputStream.use { stream ->
                            val chunk = ByteArray(4096)
                            while (buffer.size() <= 262144) {
                                if (SystemClock.elapsedRealtime() > deadline) throw java.io.IOException("Response deadline")
                                val count = stream.read(chunk)
                                if (count < 0) break
                                buffer.write(chunk, 0, count)
                            }
                        }
                        body = if (buffer.size() <= 262144) buffer.toString("UTF-8") else ""
                    }
                    if (status == 404 || (status == 200 && parseUrl(body) != null)) break
                } catch (_: Exception) { status = -1; body = "" }
                finally { connection?.disconnect() }
            }
            main.post { checking = false; apply(status, body) }
        }
    }
    private fun validUrl(raw: String): Boolean = try {
        val uri = URI(raw)
        raw == raw.trim() && uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.rawUserInfo == null
    } catch (_: Exception) { false }
    private fun parseUrl(body: String): String? = try {
        val json = JSONObject(body)
        // The endpoint answers {"code":200,"data":{"url":...}}; a top-level url is accepted too.
        val value = json.opt("url") ?: json.optJSONObject("data")?.opt("url")
        (value as? String)?.takeIf(::validUrl)
    } catch (_: Exception) { null }
    fun log(stage: String) {
        val now = SystemClock.elapsedRealtime()
        android.util.Log.i("SSGStartup", "$stage elapsedMs=${now - startedAt} processElapsedMs=${now - android.os.Process.getStartElapsedRealtime()}")
    }
}
