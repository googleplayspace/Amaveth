package com.aaazero.yueh

import android.app.Activity
import android.content.Intent
import java.util.concurrent.Executors
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.content.ContentValues
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.app.NotificationManager
import android.app.Notification
import android.net.Uri
import android.provider.Settings
import org.json.JSONObject
import com.onesignal.notifications.internal.badges.impl.shortcutbadger.ShortcutBadger

/** Process-wide link between native IM and the long-lived Flutter engine. */
internal object ShellRuntime {
    var bridge: ShellBridge? = null
        private set
    var top: Activity? = null
        private set

    fun attach(context: Context, messenger: io.flutter.plugin.common.BinaryMessenger) {
        if (bridge != null) return
        val app = context.applicationContext as android.app.Application
        bridge = ShellBridge(app, messenger)
        app.registerActivityLifecycleCallbacks(object : android.app.Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) { top = activity }
            override fun onActivityDestroyed(activity: Activity) { if (top === activity) top = null }
            override fun onActivityCreated(activity: Activity, state: android.os.Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: android.os.Bundle) {}
        })
        app.registerComponentCallbacks(object : android.content.ComponentCallbacks2 {
            override fun onTrimMemory(level: Int) {
                if (ShellMemoryPolicy.shouldWarn(level)) {
                    android.util.Log.i("SSGShell", "memory pressure level=$level")
                    bridge?.memory()
                }
            }
            override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {}
            @Deprecated("Deprecated in Java") override fun onLowMemory() {}
        })
    }
}

class ShellBridge(private val app: Context, messenger: io.flutter.plugin.common.BinaryMessenger) {
    private val channel = MethodChannel(messenger, "yueh/shell")
    private val activity: Activity get() = ShellRuntime.top ?: throw IllegalStateException("No foreground activity")
    private val handler = Handler(Looper.getMainLooper())
    // Face A's "save as" export only. IM file download is gone (spec 6 / 7), and so are
    // MediaStore writes and storage permissions: the system document picker needs none.
    private data class SaveRequest(val source: File, val result: MethodChannel.Result)
    private var pendingSave: SaveRequest? = null
    private val saveWorker = Executors.newSingleThreadExecutor()
    private var closed = false
    private val saveRequestCode = 43127
    private var running = false
    private var count = 0
    // Spec 11.2: the watchdog only checks on a tick, so a 1 s tick keeps "about 60 s" and
    // "within 10 s" accurate (5 s ticks let the reload check slip to 15 s). Spec 11.1's
    // heartbeat stays at 20 s.
    private val ticker = object : Runnable {
        override fun run() {
            if (!running) return
            channel.invokeMethod("tick", mapOf("heartbeat" to (++count % HEARTBEAT_TICKS == 0), "network" to network()))
            handler.postDelayed(this, TICK_MS)
        }
    }
    private companion object {
        const val TICK_MS = 1000L
        const val HEARTBEAT_TICKS = 20
    }
    /** §2.3: switching to A stops the native heartbeat (§11.1) and alive watch (§11.2). */
    fun stopMonitoring() {
        running = false
        handler.removeCallbacks(ticker)
    }
    private fun network(): String {
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none"
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return "none"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
    }
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "log" -> { android.util.Log.i("SSGShell", call.argument<String>("message") ?: ""); result.success(null) }
                "clearBadge" -> {
                    clearBadge()
                    result.success(ShortcutBadger.removeCount(app))
                }
                // Spec 5.4: the badge is Web's unread total. Launchers without badge support
                // simply ignore it, which is not an error worth retrying.
                "setBadge" -> {
                    val count = call.argument<Int>("count") ?: 0
                    if (count <= 0) clearBadge()
                    if (!ShortcutBadger.applyCount(app, count.coerceAtLeast(0))) android.util.Log.i("SSGShell", "launcher has no badge support")
                    result.success(true)
                }
                "clearThread" -> {
                    val chat = call.argument<String>("chatId") ?: ""
                    val thread = call.argument<String>("threadId") ?: chat
                    val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    manager.activeNotifications.forEach { item ->
                        val data = try { JSONObject(item.notification.extras.getString("custom") ?: "{}").optJSONObject("a") } catch (_: Exception) { null }
                        val id = data?.optString("chat_id").orEmpty().ifEmpty { data?.optString("chatId").orEmpty() }
                        if ((thread.isNotEmpty() && item.notification.group == thread) || (chat.isNotEmpty() && id == chat)) manager.cancel(item.tag, item.id)
                    }
                    result.success(null)
                }
                "openBatterySettings" -> {
                    activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    result.success(null)
                }
                "openWebViewUpdate" -> {
                    openWebViewUpdate(result)
                }
                "imPrepare" -> {
                    val raw = call.argument<String>("url")!!
                    if (!ShellStartup.accepts(raw)) result.error("stale_config", "The startup decision changed", null)
                    else result.success(ImWebViewHolder.prepare(app, raw, call.argument<String>("origin")!!, call.argument<String>("script")!!, call.argument<String>("uaSuffix")!!))
                }
                "imOpen" -> {
                    if (!ShellStartup.isB) { result.success(null); return@setMethodCallHandler }
                    val id = ImWebViewHolder.open(app)
                    val from = ShellRuntime.top
                    if (from !is ImActivity) {
                        val intent = Intent(app, ImActivity::class.java)
                        if (from != null) from.startActivity(intent) else app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    result.success(id)
                    // Replay what the page sent before Dart knew this view id (posted after the reply).
                    handler.post { ImWebViewHolder.goLive() }
                }
                "imForget" -> { ImWebViewHolder.forget(app); result.success(null) }
                "imRebuild" -> result.success(ImWebViewHolder.rebuild(app))
                "imEvaluate" -> ImWebViewHolder.evaluate(call.argument<String>("source")!!) { result.success(it) }
                "imUrl" -> result.success(ImWebViewHolder.currentUrl())
                "imReload" -> { ImWebViewHolder.reload(); result.success(null) }
                "imLoad" -> { ImWebViewHolder.load(call.argument<String>("url")!!); result.success(null) }
                "imTerminate" -> ImWebViewHolder.terminate { result.success(it) }
                "imState" -> { ImWebViewHolder.setUi(call.argument<Boolean>("loading") == true, call.argument<String>("error")); result.success(null) }
                "imToast" -> { android.widget.Toast.makeText(app, call.argument<String>("message") ?: "", android.widget.Toast.LENGTH_SHORT).show(); result.success(null) }
                "imDiagnostics" -> { ImWebViewHolder.host?.showDiagnostics(call.argument<String>("text") ?: ""); result.success(null) }
                "metadata" -> {
                    val pkg = app.packageManager.getPackageInfo(app.packageName, 0)
                    val provider = androidx.webkit.WebViewCompat.getCurrentWebViewPackage(app)
                    result.success(mapOf("platform" to "android", "bundleId" to app.packageName,
                        "shellVersion" to (pkg.versionName ?: ""), "deviceModel" to Build.MODEL,
                        "osVersion" to Build.VERSION.RELEASE, "sdk" to Build.VERSION.SDK_INT,
                        "webviewVersion" to (provider?.versionName ?: "unknown"),
                        "webviewPackage" to (provider?.packageName ?: "unknown"),
                        "networkType" to network()))
                }
                "active" -> {
                    running = call.argument<Boolean>("value") == true
                    count = 0; handler.removeCallbacks(ticker)
                    if (running) handler.postDelayed(ticker, TICK_MS)
                    result.success(null)
                }
                "exportFile" -> {
                    try {
                        val source = File(call.argument<String>("path")!!)
                        val name = call.argument<String>("name")!!.substringAfterLast('/').substringAfterLast('\\')
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        if (pendingSave != null) { result.error("busy", "A file is already waiting to be saved", null) }
                        else {
                            pendingSave = SaveRequest(source, result)
                            try {
                                activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = mime
                                    putExtra(Intent.EXTRA_TITLE, name)
                                }, saveRequestCode)
                            } catch (e: Exception) { pendingSave = null; result.error("save", e.message, null) }
                        }
                    } catch (e: Exception) { result.error("save", e.message, null) }
                }
                else -> result.notImplemented()
            }
        }
    }
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != saveRequestCode) return false
        val pending = pendingSave ?: return true
        pendingSave = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.result.success(null)
            return true
        }
        saveWorker.execute {
            try {
                activity.contentResolver.openOutputStream(uri, "w").use { out ->
                    requireNotNull(out) { "Could not write the selected file" }
                    pending.source.inputStream().use { it.copyTo(out, 128 * 1024) }
                }
                handler.post { if (!closed) pending.result.success(uri.toString()) }
            } catch (e: Exception) {
                handler.post { if (!closed) pending.result.error("save", e.message, null) }
            }
        }
        return true
    }
    fun memory() { channel.invokeMethod("memory", null) }
    fun imEvent(type: String, args: Map<String, Any?> = emptyMap()) { channel.invokeMethod("imEvent", args + ("type" to type)) }
    fun webEvent(name: String, json: String, viewId: Int) { channel.invokeMethod("webEvent", mapOf("name" to name, "json" to json, "viewId" to viewId.toString())) }
    private fun clearBadge() {
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // Badge APIs vary by launcher; preserve other conversations' notifications.
        if (Build.VERSION.SDK_INT >= 26) manager.activeNotifications.forEach { item ->
            val updated = Notification.Builder.recoverBuilder(app, item.notification)
                .setNumber(0).setBadgeIconType(Notification.BADGE_ICON_NONE).setOnlyAlertOnce(true).build()
            manager.notify(item.tag, item.id, updated)
        }
    }
    fun openWebViewUpdate(result: MethodChannel.Result? = null) {
        val provider = androidx.webkit.WebViewCompat.getCurrentWebViewPackage(app)
        if (provider == null) { result?.error("webview", "Could not identify the active WebView provider", null); return }
        val page = Uri.Builder().scheme("market").authority("details").appendQueryParameter("id", provider.packageName).build()
        try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, page).setPackage("com.android.vending"))
            result?.success(null)
        } catch (_: Exception) {
            try {
                val web = Uri.parse("https://play.google.com/store/apps/details").buildUpon().appendQueryParameter("id", provider.packageName).build()
                activity.startActivity(Intent(Intent.ACTION_VIEW, web))
                result?.success(null)
            } catch (_: Exception) { result?.error("store", "Could not open the app store", null) }
        }
    }
    fun close() { closed = true; pendingSave?.result?.error("cancelled", "The save screen was closed", null); pendingSave = null; saveWorker.shutdown(); running = false; handler.removeCallbacks(ticker); channel.setMethodCallHandler(null) }
}