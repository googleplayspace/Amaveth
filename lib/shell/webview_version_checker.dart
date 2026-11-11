import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'kernel_policy.dart';

class WebViewVersionChecker {
  static const channel = MethodChannel('app/webview_info');
  static const dismissedKey = 'webview_update_prompt_dismissed';
  static bool _checking = false;

  /// Call after the first frame; detection errors must never block startup.
  static Future<void> checkAndPrompt(BuildContext context) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        _checking) {
      return;
    }
    _checking = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Preserve the previous version's one-time dismissal when upgrading the app.
      if (prefs.getBool(dismissedKey) == true ||
          prefs.getBool('shell.oldKernelNoticeShown') == true) {
        return;
      }
      final info = await channel.invokeMapMethod<String, dynamic>(
        'getWebViewPackage',
      );
      if (info == null) return;
      final version = info['versionName'] as String? ?? '';
      final package = info['packageName'] as String? ?? '';
      if (!shouldPromptWebViewUpgrade(version) ||
          package.isEmpty ||
          !context.mounted) {
        return;
      }
      final update = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Web component update recommended'),
          content: Text(
            'Your web component is outdated ($version). Some pages may not display correctly. Update Android System WebView or Chrome in the app store.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Ignore'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Update'),
            ),
          ],
        ),
      );
      // Both choices (or dismissing the dialog) count as the one-time prompt.
      await prefs.setBool(dismissedKey, true);
      if (update == true) await openStore(package);
    } catch (_) {
      // A missing provider, unavailable store, or failed preference read is nonfatal.
    } finally {
      _checking = false;
    }
  }

  static Future<bool> openStore(String package) async {
    if (package.isEmpty) return false;
    final market = Uri(
      scheme: 'market',
      host: 'details',
      queryParameters: {'id': package},
    );
    final web = Uri.https('play.google.com', '/store/apps/details', {
      'id': package,
    });
    try {
      if (await launchUrl(market, mode: LaunchMode.externalApplication)) {
        return true;
      }
    } catch (_) {
      /* still try HTTPS */
    }
    try {
      return await launchUrl(web, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
