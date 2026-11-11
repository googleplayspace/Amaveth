package com.pichillilorenzo.flutter_inappwebview_android.webview;

import android.webkit.JavascriptInterface;
import java.lang.ref.WeakReference;
import java.util.HashMap;
import org.json.JSONObject;
import io.flutter.plugin.common.MethodChannel;
import com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview.InAppWebView;

/** The documented native jsBridge, available before any business script. */
public final class SSGNativeBridge {
  private final WeakReference<InAppWebView> owner;
  public SSGNativeBridge(InAppWebView view) { owner = new WeakReference<>(view); }

  @JavascriptInterface public void postMessage(String name, String json) {
    InAppWebView view = owner.get();
    if (view == null) return;
    view.post(() -> {
      if (view.plugin == null || view.plugin.messenger == null) return;
      HashMap<String, Object> data = new HashMap<>();
      data.put("name", name); data.put("json", json); data.put("viewId", String.valueOf(view.id));
      new MethodChannel(view.plugin.messenger, "colorgrab/shell").invokeMethod("webEvent", data);
    });
  }

  @JavascriptInterface public void postMessage(String json) {
    try {
      String event = new JSONObject(json).optString("eventName");
      String[] names = {"webReady", "register", "login", "logout", "messageSent", "webAlive", "chatOpen", "chatClose", "chatRead", "unreadCount"};
      for (String value : names) if (value.equals(event)) {
        postMessage("event" + Character.toUpperCase(value.charAt(0)) + value.substring(1), json); return;
      }
    } catch (Exception ignored) { }
  }
}
