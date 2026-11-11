# Preserve entry points used by the Android manifest and injected JavaScript.
-keep class com.aaazero.yueh.ShellNotificationExtension { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

-keep class net.sqlcipher.** { *; }

-keep class net.zetetic.** { *; }
