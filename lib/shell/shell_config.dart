class ShellConfig {
  /// Startup endpoint deciding A/B: 200 + h5url → B at that URL, 404 → A.
  static const configUrl = String.fromEnvironment(
    'SSG_CONFIG_URL',
    defaultValue: 'https://u4k2.top/api/config',
  );

  /// B address. Replaced by `h5url` from [configUrl] before B is started;
  /// the default only serves tests.
  static String webAddress = const String.fromEnvironment(
    'SSG_WEB_URL',
    defaultValue: 'https://web217-test-2.ssg18app.com',
  );

  /// Spec 2.1: the shell loads [webAddress] exactly as configured and never
  /// strips, renames or adds a channel parameter; Web reads `channelcode` in any
  /// case itself. This getter only reads the value back for diagnostics.
  static bool isChannelKey(String key) => key.toLowerCase() == 'channelcode';
  static String get channelCode {
    for (final e in Uri.parse(webAddress).queryParametersAll.entries) {
      if (!isChannelKey(e.key)) continue;
      for (final v in e.value) {
        if (v.trim().isNotEmpty) return v.trim();
      }
    }
    return '';
  }

  // Public client IDs, read from the user's OneSignal dashboard (aiyue App).
  // Platform credentials still need to be configured there; no server keys here.
  static const androidOneSignalId = String.fromEnvironment(
    'SSG_ANDROID_ONESIGNAL_ID',
    defaultValue: '',
  );
  static const iosOneSignalId = String.fromEnvironment(
    'SSG_IOS_ONESIGNAL_ID',
    defaultValue: '',
  );

  /// Parsed [webAddress], for origin / host checks only. Anything that loads the
  /// page must use the [webAddress] string itself, so the query reaches Web
  /// byte for byte (spec 2.1: no parsing or rebuilding of the query).
  static Uri get entry => Uri.parse(webAddress);
  static bool trusted(Uri? uri) =>
      uri != null && uri.scheme == 'https' && uri.origin == entry.origin;
}

/// A (colors) is the default; B (im) only after the config endpoint says so.
enum AppFace { tool, im }
