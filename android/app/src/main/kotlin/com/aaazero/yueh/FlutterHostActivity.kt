package com.aaazero.yueh

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs

/**
 * Hosts Flutter (face A, and the Dart side of B). It is no longer the launcher: the
 * launcher alias `.MainActivity` targets ImActivity, which forwards here when B is off.
 */
class FlutterHostActivity : FlutterActivity() {
    private var startupCover: android.widget.FrameLayout? = null

    override fun onCreate(state: android.os.Bundle?) {
        super.onCreate(state)
        syncStartupCover()
    }

    /** A can only paint after attaching a Flutter surface; keep the native cover meanwhile. */
    fun syncStartupCover() {
        if (!ShellStartup.awaitingA) {
            startupCover?.let { (it.parent as? android.view.ViewGroup)?.removeView(it) }
            startupCover = null
            return
        }
        if (startupCover != null) return
        val cover = android.widget.FrameLayout(this).apply {
            setBackgroundColor(android.graphics.Color.WHITE)
            isClickable = true
            addView(android.widget.ImageView(context).apply { setImageResource(R.drawable.shell_splash_art) },
                android.widget.FrameLayout.LayoutParams((96 * resources.displayMetrics.density).toInt(),
                    (96 * resources.displayMetrics.density).toInt(), android.view.Gravity.CENTER))
        }
        (window.decorView as android.view.ViewGroup).addView(cover,
            android.view.ViewGroup.LayoutParams(android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT))
        startupCover = cover
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        ShellEngine.obtain(context, FlutterShellArgs.fromIntent(intent).toArray())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ShellEngine.configure(applicationContext, flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        syncStartupCover()
    }

    override fun onResume() {
        super.onResume()
        syncStartupCover()
        if (ImWebViewHolder.active) {
            startActivity(
                Intent(this, ImActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            if (intent?.action == Intent.ACTION_SEND) finish()
        }
    }

    @Deprecated("Forwarded for the tool's document export")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (ShellRuntime.bridge?.onActivityResult(requestCode, resultCode, data) != true) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
