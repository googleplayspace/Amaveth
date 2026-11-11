import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// What the shell logic needs from the page, wherever the WebView lives.
abstract class ShellWeb {
  String get id;
  Future<Object?> evaluate(String source);
  Future<Uri?> url();
  Future<void> reload();
  Future<void> pause();
  Future<void> resume();
}

/// Retained legacy adapter; the current IM does not instantiate a Flutter WebView.
class InAppShellWeb implements ShellWeb {
  final InAppWebViewController controller;
  InAppShellWeb(this.controller);
  @override
  String get id => '${controller.getViewId()}';
  @override
  Future<Object?> evaluate(String source) =>
      controller.evaluateJavascript(source: source);
  @override
  Future<Uri?> url() async => (await controller.getUrl())?.uriValue;
  @override
  Future<void> reload() => controller.reload();
  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> resume() => controller.resume();
}

/// Android ImActivity and the iOS native controller own their single WebView.
class NativeShellWeb implements ShellWeb {
  static const channel = MethodChannel('yueh/shell');
  @override
  final String id;
  NativeShellWeb(this.id);
  @override
  Future<Object?> evaluate(String source) async {
    final raw = await channel.invokeMethod<String>('imEvaluate', {
      'source': source,
    });
    return decodeEvaluateResult(raw);
  }

  @override
  Future<Uri?> url() async {
    final raw = await channel.invokeMethod<String>('imUrl');
    return raw == null ? null : Uri.tryParse(raw);
  }

  @override
  Future<void> reload() => channel.invokeMethod('imReload');
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
}

/// `WebView.evaluateJavascript` reports its result as JSON text.
Object? decodeEvaluateResult(String? raw) {
  if (raw == null || raw == 'null' || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return raw;
  }
}
