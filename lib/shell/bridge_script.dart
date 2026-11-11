import 'dart:convert';

/// Transport handlers are native: addJavascriptInterface / WKScriptMessageHandler.
String shellScript(Map<String, dynamic> metadata, String origin) =>
    """
(() => {
 if (window !== window.top || location.origin !== ${jsonEncode(origin)}) return;
 window.__SSG_SHELL__ = ${jsonEncode(metadata)};
})();
""";
