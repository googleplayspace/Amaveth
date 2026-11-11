import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

abstract final class AppPlatform {
  static const _channel = MethodChannel('yueh/shell');

  @visibleForTesting
  static bool? androidOverride;
  static bool get _android => androidOverride ?? Platform.isAndroid;

  static Future<Map<String, dynamic>> metadata() async =>
      await _channel.invokeMapMethod<String, dynamic>('metadata') ?? {};

  /// Face A's "save as" for a generated file. Android opens the system document
  /// picker (no storage permission); iOS opens the share sheet. The temp file is
  /// always deleted afterwards. This is not IM file download, which is not offered.
  static Future<void> exportTemporaryFile(
    File file, {
    required String name,
    required String mime,
    required void Function(String) onNotice,
  }) async {
    final safe = exportFileName(name);
    try {
      if (_android) {
        final saved = await _channel.invokeMethod<String>('exportFile', {
          'path': file.path,
          'name': safe,
          'mime': mime,
        });
        onNotice(
          saved == null ? 'Save cancelled' : 'Saved to the selected location',
        );
      } else {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: mime)],
            fileNameOverrides: [safe],
            sharePositionOrigin: const Rect.fromLTWH(20, 100, 100, 40),
          ),
        );
        onNotice('Opened the system save/share sheet');
      }
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}

/// Last path segment, no control characters, at most 120 characters.
String exportFileName(String name) {
  final base = name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[\x00-\x1f]'), '_');
  if (base.isEmpty) return 'export';
  return base.length <= 120 ? base : base.substring(base.length - 120);
}
