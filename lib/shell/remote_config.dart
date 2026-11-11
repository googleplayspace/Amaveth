import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shell_config.dart';

/// What one request to the face-config endpoint proved.
enum ConfigVerdict {
  /// HTTP 200 with a usable `h5url`: open B with that address.
  b,

  /// Only HTTP 404 explicitly disables B.
  a,

  /// Network error, timeout, 5xx or malformed body: nothing was proved.
  unknown,
}

class FaceConfig {
  final ConfigVerdict verdict;
  final String url, privacyUrl, termsUrl;
  const FaceConfig(
    this.verdict, {
    this.url = '',
    this.privacyUrl = '',
    this.termsUrl = '',
  });
  static const a = FaceConfig(ConfigVerdict.a);
  static const unknown = FaceConfig(ConfigVerdict.unknown);

  /// Pure parser for `GET /api/config`, kept separate so it can be unit tested.
  static FaceConfig parse(int status, String body) {
    if (status == 404) return a;
    if (status != 200) return unknown;
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return unknown;
    }
    if (json is! Map) return unknown;
    final nested = json['data'];
    final data = nested is Map ? nested : json;
    final raw = json['h5url'] ?? data['h5url'];
    final url = raw is String ? raw : '';
    final uri = Uri.tryParse(url);
    if (url != url.trim() ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return unknown;
    }
    String text(Object? v) => v is String ? v.trim() : '';
    return FaceConfig(
      ConfigVerdict.b,
      // Spec 2.1: keep the url exactly as delivered (channelcode in any case).
      url: url,
      privacyUrl: text(data['privacy_url']),
      termsUrl: text(data['terms_url']),
    );
  }
}

class RemoteConfig {
  static const startup = MethodChannel('yueh/startup');
  static Future<Map<String, dynamic>?> nativeSnapshot() async {
    try {
      final value = await startup.invokeMapMethod<String, dynamic>('snapshot');
      return value;
    } on MissingPluginException {
      return null;
    }
  }

  static const cacheKey = 'remoteConfig.url';

  /// Last successful B address, used only when the endpoint cannot be reached.
  @visibleForTesting
  static Future<FaceConfig> Function()? fetchOverride;

  static Future<FaceConfig> fetch() async {
    final override = fetchOverride;
    if (override != null) return override();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..userAgent = 'Amaveth';
    try {
      final request = await client
          .getUrl(Uri.parse(ShellConfig.configUrl))
          .timeout(const Duration(seconds: 6));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      return FaceConfig.parse(response.statusCode, body);
    } catch (_) {
      return FaceConfig.unknown;
    } finally {
      client.close(force: true);
    }
  }

  /// B address remembered from an earlier launch, read before the first frame.
  static Future<String?> cachedUrl() async {
    final native = await nativeSnapshot();
    if (native != null) {
      return native['face'] == 'b' ? native['url'] as String? : null;
    }
    try {
      final value = (await SharedPreferences.getInstance()).getString(cacheKey);
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// Server said A: drop the native preload config so the next cold start is A.
  static Future<void> forgetNative() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await const MethodChannel('yueh/shell').invokeMethod<void>('imForget');
    } catch (_) {}
  }

  /// Decides the face for this launch.
  ///
  /// Only a 404 clears a remembered B URL. No cache + exhausted retries shows A
  /// as the user's explicit 2026-11-11 clarification, not a persisted disable.
  static Future<FaceConfig> resolve({
    List<Duration> retries = const [Duration(seconds: 2), Duration(seconds: 5)],
  }) async {
    var result = await fetch();
    for (final delay in retries) {
      if (result.verdict != ConfigVerdict.unknown) break;
      await Future<void>.delayed(delay);
      result = await fetch();
    }
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    switch (result.verdict) {
      case ConfigVerdict.b:
        await prefs?.setString(cacheKey, result.url);
        return result;
      case ConfigVerdict.a:
        await prefs?.remove(cacheKey);
        return result;
      case ConfigVerdict.unknown:
        final cached = prefs?.getString(cacheKey) ?? '';
        return cached.isEmpty
            ? FaceConfig.a
            : FaceConfig(ConfigVerdict.b, url: cached);
    }
  }
}
