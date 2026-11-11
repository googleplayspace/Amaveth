package com.aaazero.yueh

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** Native cached load precedes Flutter and all SDK initialization (§9.6). */
class ShellApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        ShellStartup.start(this)
    }
}

/** The one Flutter engine, shared by FlutterHostActivity and a B-only cold start. */
internal object ShellEngine {
    private fun id(context: Context) = "${context.packageName}.main_engine"

    fun obtain(context: Context, args: Array<String> = emptyArray()): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(id(context))?.let { return it }
        val app = context.applicationContext
        return FlutterEngine(app, args).also {
            configure(app, it)
            cache.put(id(context), it)
        }
    }

    fun configure(app: Context, engine: FlutterEngine) {
        ShellStartup.attach(engine.dartExecutor.binaryMessenger)
        ShellRuntime.attach(app, engine.dartExecutor.binaryMessenger)
        MethodChannel(engine.dartExecutor.binaryMessenger, "app/webview_info").setMethodCallHandler { call, result ->
            if (call.method == "getWebViewPackage") {
                val p = androidx.webkit.WebViewCompat.getCurrentWebViewPackage(app)
                result.success(p?.let { mapOf("packageName" to it.packageName, "versionName" to it.versionName) })
            } else result.notImplemented()
        }
    }

    /**
     * Start the bridge engine while ImActivity owns the native launch cover. Cached
     * loading already began in Application.onCreate, even before this engine exists.
     */
    fun warmUp(app: Application, args: Array<String> = emptyArray()) {
        val engine = obtain(app, args)
        if (!engine.dartExecutor.isExecutingDart) {
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }
}
