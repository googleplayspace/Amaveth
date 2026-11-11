// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'dart:async';

import 'package:yueh/shell/push_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('SDK defers permission until visible login, routes clicks once and serializes logout', () async {
    SharedPreferences.setMockInitialValues({});
    final calls = <String>[];
    Completer<void>? blockedLogin;
    final loginStarted = Completer<void>();
    for (final name in [
      'OneSignal',
      'OneSignal#debug',
      'OneSignal#notifications',
      'OneSignal#user',
      'OneSignal#pushsubscription',
      'OneSignal#inappmessages',
      'yueh/shell',
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'OneSignal#permission':
              return false;
            case 'OneSignal#canRequest':
              return true;
            case 'OneSignal#requestPermission':
              return false;
            case 'OneSignal#pushSubscriptionOptedIn':
              return false;
            case 'OneSignal#login':
              if (blockedLogin != null) {
                if (!loginStarted.isCompleted) loginStarted.complete();
                await blockedLogin.future;
              }
          }
          return null;
        },
      );
    }
    final push = ShellPush.instance;
    await push.initialize();
    expect(push.initialized, true);
    expect(calls, isNot(contains('OneSignal#requestPermission')));
    await push.login('alice', visible: false);
    expect(push.uid, 'alice');
    expect(calls, isNot(contains('OneSignal#requestPermission')));
    await push.requestPermission();
    await push.login('alice', visible: true);
    expect(calls.where((m) => m == 'OneSignal#requestPermission').length, 1);

    push.setVisible(true);
    await push.onWebEvent('webReady', {});
    await push.onWebEvent('chatOpen', {'chatId': 'chat', 'timestamp': '1'});
    expect(calls, contains('clearBadge'));
    expect(calls, contains('clearThread'));
    Future<void> foreground(String chat) async {
      final completed = Completer<void>();
      binding.defaultBinaryMessenger.handlePlatformMessage(
        'OneSignal#notifications',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('OneSignal#onWillDisplayNotification', {
            'notification': {
              'notificationId': 'foreground-$chat',
              'additionalData': {'chat_id': chat},
            },
          }),
        ),
        (_) => completed.complete(),
      );
      await completed.future;
    }

    await foreground('chat');
    expect(calls.where((m) => m == 'OneSignal#preventDefault').length, 1);
    await foreground('other');
    expect(calls.where((m) => m == 'OneSignal#preventDefault').length, 1);
    await push.onWebEvent('chatClose', {'chatId': 'chat'});
    await foreground('chat');
    expect(calls.where((m) => m == 'OneSignal#preventDefault').length, 1);

    Future<void> click() async {
      final completed = Completer<void>();
      binding.defaultBinaryMessenger.handlePlatformMessage(
        'OneSignal#notifications',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('OneSignal#onClickNotification', {
            'notification': {
              'notificationId': 'click-id',
              'additionalData': {'chat_id': 'chat', 'msg_id': '42'},
            },
            'result': {},
          }),
        ),
        (_) => completed.complete(),
      );
      await completed.future;
    }

    await click();
    await click();
    expect(push.openRequest, 1);
    expect(push.intents.take('alice', DateTime.now())!.payload, {
      'chatId': 'chat',
      'messageId': '42',
    });

    blockedLogin = Completer<void>();
    final login = push.login('bob', visible: false);
    await loginStarted.future;
    final logout = push.logout();
    blockedLogin.complete();
    await Future.wait([login, logout]);
    expect(push.uid, isNull);
    expect(
      (await SharedPreferences.getInstance()).containsKey('push.lastUid'),
      false,
    );
    expect(
      calls.lastIndexOf('OneSignal#logout'),
      greaterThan(calls.lastIndexOf('OneSignal#login')),
    );
    expect(calls, contains('OneSignal#optOut'));
    expect(calls, contains('OneSignal#clearAll'));
    push.setVisible(false);
  });
}
