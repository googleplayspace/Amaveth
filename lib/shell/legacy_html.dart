import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'shell_config.dart';
import 'refresh_diagnostics.dart';

/// Experimental Android-only response adapter. Never strips CSP or bypasses TLS.
class LegacyHtml {
  static const scriptPath = '/__ssg_native_compat_v1.js';
  final String script, userAgent;
  final bool diagnosticWorker;
  final void Function(String) log;
  LegacyHtml({
    required this.script,
    required this.userAgent,
    required this.log,
    this.diagnosticWorker = false,
  });
  static String insertBootstrap(String html) {
    // A same-origin external script works with this site's script-src 'self'.
    // Preserve CSP meta/header and all original bytes except this insertion.
    final match =
        RegExp(
              r'<!--[\s\S]*?-->|<style\b[^>]*>[\s\S]*?</style\s*>|<script\b',
              caseSensitive: false,
            )
            .allMatches(html)
            .where((m) => m.group(0)!.toLowerCase().startsWith('<script'))
            .firstOrNull;
    if (match == null) {
      throw const FormatException(
        'The page has no identifiable application script for startup injection',
      );
    }
    return html.replaceRange(
      match.start,
      match.start,
      '<script src="$scriptPath" data-ssg-compat="v1"></script>',
    );
  }

  static bool isEntry(WebResourceRequest request) {
    final uri = request.url.uriValue;
    String path(Uri u) => u.path.isEmpty ? '/' : u.path;
    return request.isForMainFrame == true &&
        request.method == 'GET' &&
        ShellConfig.trusted(uri) &&
        path(uri) == path(ShellConfig.entry) &&
        !uri.queryParameters.containsKey('filename');
  }

  Future<WebResourceResponse?> intercept(WebResourceRequest request) async {
    final uri = request.url.uriValue;
    if (!ShellConfig.trusted(uri) || request.method != 'GET') return null;
    if (diagnosticWorker &&
        RegExp(r'^/928\.[a-f0-9]+\.js$').hasMatch(uri.path)) {
      return workerProbe(uri);
    }
    if (uri.path == scriptPath) {
      log('legacy bootstrap resource');
      return response('application/javascript', utf8.encode(script), {});
    }
    if (!isEntry(request)) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 20));
      req.followRedirects = false;
      req.headers.set('User-Agent', userAgent);
      req.headers.set('Accept', 'text/html');
      if (request.headers?['Accept-Language'] != null) {
        req.headers.set(
          'Accept-Language',
          request.headers!['Accept-Language']!,
        );
      }
      req.headers.set('Cache-Control', 'no-cache');
      final cookies = await CookieManager.instance().getCookies(
        url: request.url,
      );
      if (cookies.isNotEmpty) {
        req.headers.set(
          'Cookie',
          cookies.map((c) => '${c.name}=${c.value}').join('; '),
        );
      }
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 ||
          res.headers.contentType?.mimeType != 'text/html') {
        throw const FormatException(
          'The entry must return HTTP 200 HTML without a redirect',
        );
      }
      final charset = res.headers.contentType?.charset;
      if (charset != null &&
          !['utf-8', 'utf8', 'us-ascii'].contains(charset.toLowerCase())) {
        throw const FormatException('Unsupported entry encoding');
      }
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const FormatException('Entry HTML exceeds 2 MB');
        }
      }
      for (final cookie in res.cookies) {
        await CookieManager.instance().setCookie(
          url: request.url,
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path ?? '/',
          expiresDate: cookie.expires?.millisecondsSinceEpoch,
          isSecure: cookie.secure,
          isHttpOnly: cookie.httpOnly,
        );
      }
      final headers = <String, String>{};
      res.headers.forEach((k, v) {
        if (![
          'content-encoding',
          'content-length',
          'transfer-encoding',
          'connection',
          'set-cookie',
          'content-type',
          'cache-control',
          'etag',
          'last-modified',
        ].contains(k.toLowerCase())) {
          headers[k] = v.join(', ');
        }
      });
      if (headers.keys.any(
        (k) => [
          'content-security-policy',
          'content-security-policy-report-only',
          'cross-origin-opener-policy',
          'cross-origin-embedder-policy',
          'cross-origin-resource-policy',
          'permissions-policy',
        ].contains(k.toLowerCase()),
      )) {
        throw const FormatException(
          'HTML fallback cannot preserve the response security headers',
        );
      }
      final html = insertBootstrap(utf8.decode(bytes));
      log('legacy entry adapted; CSP retained');
      return response('text/html', utf8.encode(html), headers);
    } catch (e) {
      log('legacy entry rejected: ${e.runtimeType}');
      // Fail visibly; never fall back to running the business bundle before
      // shell setup or to disabling its security policy.
      return WebResourceResponse(
        contentType: 'text/html',
        contentEncoding: 'utf-8',
        statusCode: 502,
        reasonPhrase: 'Compatibility unavailable',
        data: Uint8List.fromList(
          utf8.encode(
            '<!doctype html><meta charset="utf-8"><p>Could not load the compatibility page. Retry or update Android System WebView.</p>',
          ),
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  static String traceWorker(String source) {
    // Debug-only observers at the two public worker branches. Comma expressions
    // retain the original return and do not suppress/rewrite any RPC outcome.
    source = source.replaceFirst(
      'if(n&&ve.has(n)||401===a)return i()',
      'if(n&&ve.has(n)||401===a)return self.postMessage({payloads:[{type:"ssgRefreshDiagnostic",code:"start:"+String(n)+",http:"+String(a)}]}),i()',
    );
    source = source.replaceFirst(
      'if("AUTH_KEY_UNREGISTERED"===l||"SESSION_REVOKED"===l)return c.Oig',
      'if("AUTH_KEY_UNREGISTERED"===l||"SESSION_REVOKED"===l)return self.postMessage({payloads:[{type:"ssgRefreshDiagnostic",code:"invoke:"+l+",method:"+e.className}]}),c.Oig',
    );
    return source;
  }

  Future<WebResourceResponse> workerProbe(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      req.headers.set('User-Agent', userAgent);
      final res = await req.close();
      if (res.statusCode != 200) throw StateError('Worker source unavailable');
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 8 * 1024 * 1024) {
          throw StateError('Worker too large');
        }
      }
      final headers = <String, String>{};
      res.headers.forEach((k, v) {
        if (![
          'content-length',
          'content-encoding',
          'transfer-encoding',
          'content-type',
          'cache-control',
        ].contains(k)) {
          headers[k] = v.join(', ');
        }
      });
      log('debug worker observer installed');
      return response(
        'application/javascript',
        utf8.encode(workerRefreshDiagnostics + traceWorker(utf8.decode(bytes))),
        headers,
      );
    } finally {
      client.close(force: true);
    }
  }

  WebResourceResponse response(
    String type,
    List<int> bytes,
    Map<String, String> headers,
  ) => WebResourceResponse(
    contentType: type,
    contentEncoding: 'utf-8',
    statusCode: 200,
    reasonPhrase: 'OK',
    headers: {
      ...headers,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
    data: Uint8List.fromList(bytes),
  );
}
