package com.aaazero.yueh

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

/** Spec 8.4: native host for the IM WebView. It attaches the singleton; it never owns it. */
class ImActivity : ComponentActivity() {
    private lateinit var content: FrameLayout
    private lateinit var overlay: LinearLayout
    private lateinit var cover: FrameLayout
    private lateinit var message: TextView
    private lateinit var retry: Button
    private lateinit var update: Button
    private var chooser: ValueCallback<Array<Uri>>? = null
    private var pendingMic: PermissionRequest? = null
    private var customView: View? = null
    private var customCallback: WebChromeClient.CustomViewCallback? = null
    private var resumed = false
    private var lastBack = 0L
    private val volumePresses = ArrayDeque<Long>()

    private val pickOne = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        finishChooser(uri?.let { arrayOf(it) })
    }
    private val pickMany = registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        finishChooser(uris.takeIf { it.isNotEmpty() }?.toTypedArray())
    }
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val request = pendingMic
        pendingMic = null
        if (request != null) {
            if (granted) request.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE)) else request.deny()
        }
        if (!granted && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) showMicGuide()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        if (ShellStartup.isA) { showA(); return }
        // §9.6 allows system splash -> identical native splash -> ready page.
        // This OEM omits the starting-window icon. Hand off once our native cover is
        // attached, rather than holding an empty OEM window until WebReady. The
        // process-owned cover remains until WebReady, an error, or its 30s cap.
        if (isTaskRoot && savedInstanceState == null) {
            val shownAt = SystemClock.elapsedRealtime()
            splash.setKeepOnScreenCondition {
                !::cover.isInitialized && SystemClock.elapsedRealtime() - shownAt < SPLASH_LIMIT_MS
            }
            splash.setOnExitAnimationListener { it.remove(); applyWhiteSystemBars() }
        }
        window.decorView.setBackgroundColor(Color.WHITE)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        applyWhiteSystemBars()
        setContentView(buildLayout())
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = goBack()
        })
        ImWebViewHolder.onHostAttached(this)
        renderUi()
        ShellEngine.warmUp(application, io.flutter.embedding.engine.FlutterShellArgs.fromIntent(intent).toArray())
    }

    fun decisionChanged() {
        if (ShellStartup.isA) { if (resumed) showA() } else renderUi()
    }

    private fun showA() {
        startActivity(Intent(this, FlutterHostActivity::class.java).apply {
            action = intent.action
            data = intent.data
            intent.extras?.let { putExtras(it) }
            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        })
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    private fun buildLayout(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }
        // Spec 9.4: turn every inset into padding so the page reads env(safe-area-inset-*) = 0.
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime() or WindowInsetsCompat.Type.displayCutout(),
            )
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
        content = FrameLayout(this).apply { setBackgroundColor(Color.WHITE) }
        root.addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        // Order inside content: WebView (inserted at 0) < recovery cover < error overlay.
        cover = buildCover()
        content.addView(cover, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        overlay = buildOverlay()
        content.addView(overlay, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        return root
    }

    /** Spec 11.2 recovery: the same brand image as the system splash (9.6), until webReady. */
    private fun buildCover() = FrameLayout(this).apply {
        setBackgroundColor(Color.WHITE)
        isClickable = true
        visibility = View.GONE
        addView(
            ImageView(context).apply { setImageResource(R.drawable.shell_splash_art) },
            FrameLayout.LayoutParams(dp(96), dp(96), Gravity.CENTER),
        )
    }

    private fun buildOverlay() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setBackgroundColor(Color.WHITE)
        isClickable = true
        setPadding(dp(24), dp(24), dp(24), dp(24))
        message = TextView(context).apply {
            gravity = Gravity.CENTER
            setTextColor(Color.DKGRAY)
            setPadding(0, dp(16), 0, dp(8))
        }
        update = plainButton("Update Android System WebView") { ShellRuntime.bridge?.openWebViewUpdate() }
        retry = plainButton("Retry") { ImWebViewHolder.event("retry") }
        addView(message)
        addView(update)
        addView(retry)
    }

    private fun plainButton(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        setOnClickListener { onClick() }
    }

    /** Loading / error state is decided in Dart and mirrored here. */
    fun renderUi() {
        if (!::overlay.isInitialized) return
        val error = ImWebViewHolder.error
        cover.visibility = if ((ImWebViewHolder.recovering || ShellStartup.waiting || ShellStartup.awaitingA) && error == null) View.VISIBLE else View.GONE
        overlay.visibility = if (error != null) View.VISIBLE else View.GONE
        message.text = error ?: ""
        update.visibility = if (error != null) View.VISIBLE else View.GONE
        retry.visibility = if (error != null) View.VISIBLE else View.GONE
    }

    fun attachWeb(web: WebView) {
        if (!::content.isInitialized) return
        (web.parent as? ViewGroup)?.removeView(web)
        content.addView(web, 0, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    /**
     * Spec 11.6 hidden entry, now that IM is full screen: five volume-down presses within
     * three seconds. The key still changes the volume.
     */
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN && event.repeatCount == 0) {
            val now = SystemClock.elapsedRealtime()
            volumePresses.addLast(now)
            while (volumePresses.isNotEmpty() && now - volumePresses.first() > DIAGNOSTIC_WINDOW_MS) volumePresses.removeFirst()
            if (volumePresses.size >= DIAGNOSTIC_PRESSES) {
                volumePresses.clear()
                ImWebViewHolder.event("diagnostics")
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /** Spec 9.1: Web history first; at the bottom confirm, then leave without destroying IM. */
    private fun goBack() {
        if (customView != null) return hideCustomView()
        val web = ImWebViewHolder.current()
        if (web != null && web.canGoBack()) return web.goBack()
        val now = SystemClock.elapsedRealtime()
        if (now - lastBack <= EXIT_WINDOW_MS) {
            lastBack = 0
            moveTaskToBack(true)
        } else {
            lastBack = now
            Toast.makeText(this, "Press back again to exit", Toast.LENGTH_SHORT).show()
        }
    }

    /**
     * Spec 9.4: white status and navigation bars with dark icons, on every page and in dark
     * mode. The SplashScreen library re-applies the post-splash theme's bar colors when the
     * splash exits, so ImShellTheme carries the same values and this runs again afterwards.
     */
    private fun applyWhiteSystemBars() {
        // Without this flag the legacy theme forces black bars over our white root.
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        @Suppress("DEPRECATION")
        window.statusBarColor = Color.WHITE
        @Suppress("DEPRECATION")
        window.navigationBarColor = Color.WHITE
        if (Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        if (ShellStartup.isA) { showA(); return }
        applyWhiteSystemBars()
        if (ImWebViewHolder.host === this) {
            ImWebViewHolder.current()?.onResume()
            ImWebViewHolder.event("visible", mapOf("value" to true))
        }
    }

    /** onPause() only, never pauseTimers(): it would freeze the page's Worker (spec 10.3). */
    override fun onPause() {
        resumed = false
        if (ImWebViewHolder.host === this) {
            ImWebViewHolder.current()?.onPause()
            ImWebViewHolder.event("visible", mapOf("value" to false))
        }
        super.onPause()
    }

    override fun onDestroy() {
        finishChooser(null)
        pendingMic?.deny()
        pendingMic = null
        hideCustomView()
        ImWebViewHolder.onHostDetached(this)
        super.onDestroy()
    }

    /** Spec 7.3: system photo picker only, and always answer the callback. */
    fun pickMedia(callback: ValueCallback<Array<Uri>>, params: WebChromeClient.FileChooserParams) {
        finishChooser(null)
        chooser = callback
        val types = params.acceptTypes.orEmpty().flatMap { it.split(',') }.map { it.trim().lowercase() }
        val images = types.any { it.startsWith("image/") }
        val videos = types.any { it.startsWith("video/") }
        val media: ActivityResultContracts.PickVisualMedia.VisualMediaType = when {
            images && !videos -> ActivityResultContracts.PickVisualMedia.ImageOnly
            videos && !images -> ActivityResultContracts.PickVisualMedia.VideoOnly
            else -> ActivityResultContracts.PickVisualMedia.ImageAndVideo
        }
        val request = PickVisualMediaRequest.Builder().setMediaType(media).build()
        try {
            if (params.mode == WebChromeClient.FileChooserParams.MODE_OPEN_MULTIPLE) pickMany.launch(request) else pickOne.launch(request)
        } catch (_: Exception) {
            finishChooser(null)
        }
    }

    private fun finishChooser(result: Array<Uri>?) {
        val callback = chooser ?: return
        chooser = null
        callback.onReceiveValue(result)
    }

    fun requestMicrophone(request: PermissionRequest) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            request.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
            return
        }
        pendingMic?.deny()
        pendingMic = request
        micPermission.launch(Manifest.permission.RECORD_AUDIO)
    }

    fun cancelMicrophone(request: PermissionRequest) {
        if (pendingMic === request) pendingMic = null
    }

    private fun showMicGuide() {
        AlertDialog.Builder(this)
            .setMessage("Microphone permission is disabled. Enable it in device settings.")
            .setPositiveButton("Settings") { _, _ -> openAppSettings() }
            .setNegativeButton("Close", null)
            .show()
    }

    /** Spec 6.2 / 10.3: offered from diagnostics, never prompted at launch. */
    private fun openBatterySettings() {
        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    private fun openAppSettings() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    }

    fun showCustomView(view: View, callback: WebChromeClient.CustomViewCallback) {
        if (customView != null) return callback.onCustomViewHidden()
        customView = view
        customCallback = callback
        (window.decorView as ViewGroup).addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        WindowInsetsControllerCompat(window, window.decorView).hide(WindowInsetsCompat.Type.systemBars())
    }

    fun hideCustomView() {
        val view = customView ?: return
        customView = null
        (window.decorView as ViewGroup).removeView(view)
        WindowInsetsControllerCompat(window, window.decorView).show(WindowInsetsCompat.Type.systemBars())
        customCallback?.onCustomViewHidden()
        customCallback = null
    }

    /** Spec 11.6: hidden entry; the text itself is assembled and redacted in Dart. */
    fun showDiagnostics(text: String) {
        val body = TextView(this).apply {
            this.text = text
            setTextIsSelectable(true)
            setPadding(dp(16), dp(8), dp(16), dp(8))
        }
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(plainButton("Notification settings") { openAppSettings() })
            addView(plainButton("Battery settings") { openBatterySettings() })
            addView(plainButton("Update WebView") { ShellRuntime.bridge?.openWebViewUpdate() })
            addView(
                plainButton("Export") {
                    val share = Intent(Intent.ACTION_SEND).setType("text/plain")
                        .putExtra(Intent.EXTRA_SUBJECT, "im-diagnostics.json")
                        .putExtra(Intent.EXTRA_TEXT, text.take(MAX_EXPORT_CHARS))
                    startActivity(Intent.createChooser(share, "Export diagnostics"))
                },
            )
        }
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(actions)
            addView(body)
        }
        AlertDialog.Builder(this)
            .setTitle("Diagnostics")
            .setView(ScrollView(this).apply { addView(page) })
            .setPositiveButton("Close", null)
            .show()
    }

    private fun dp(value: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), resources.displayMetrics).toInt()

    private companion object {
        const val EXIT_WINDOW_MS = 2000L
        const val DIAGNOSTIC_WINDOW_MS = 3000L
        const val DIAGNOSTIC_PRESSES = 5
        const val MAX_EXPORT_CHARS = 200_000
        const val SPLASH_LIMIT_MS = 30_000L
    }
}