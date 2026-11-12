// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'package:Amaveth/shell/push_service.dart';
import 'package:Amaveth/shell/shell_web.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yueh/shell');
  final calls = <MethodCall>[];
  final push = ShellPush.instance;

  setUp(() {
    calls.clear();
    push.countBadgeOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(() {
    push.setVisible(false);
    push.countBadgeOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('badge follows the unread total (spec 5.4)', () {
    test('applies the count from unreadCount', () async {
      await push.onWebEvent('unreadCount', {'count': '7', 'timestamp': '1'});
      expect(calls.single.method, 'setBadge');
      expect(calls.single.arguments, {'count': 7});
    });

    test('zero is forwarded so the badge clears', () async {
      await push.onWebEvent('unreadCount', {'count': '0', 'timestamp': '1'});
      expect(calls.single.arguments, {'count': 0});
    });

    test('reading one chat keeps the total of the others', () async {
      await push.onWebEvent('chatRead', {'chatId': '42', 'timestamp': '1'});
      expect(calls.where((c) => c.method.contains('Badge')), isEmpty);
    });

    test('entering IM does not clear the badge', () async {
      push.setVisible(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method.contains('Badge')), isEmpty);
    });
  });

  group('native evaluateJavascript results', () {
    test('decode JSON and keep null as null', () {
      expect(decodeEvaluateResult('true'), true);
      expect(decodeEvaluateResult('"a"'), 'a');
      expect(decodeEvaluateResult('null'), isNull);
      expect(decodeEvaluateResult(null), isNull);
    });
  });
}
