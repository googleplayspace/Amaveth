// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'package:yueh/shell/push_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('initialization/binding recover without another Web login; false badge result is retained', () async {
    SharedPreferences.setMockInitialValues({'push.permissionAsked': true});
    var initFailures = 1, loginFailures = 1, logins = 0, badgeCalls = 0;
    var badgeOK = false;
    final calls = <String>[];
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
            case 'OneSignal#initialize':
              if (initFailures-- > 0) throw PlatformException(code: 'offline');
            case 'OneSignal#login':
              logins++;
              if (loginFailures-- > 0) throw PlatformException(code: 'offline');
            case 'OneSignal#permission':
              return false;
            case 'OneSignal#pushSubscriptionOptedIn':
              return false;
            case 'clearBadge':
              badgeCalls++;
              return badgeOK;
          }
          return null;
        },
      );
    }
    final push = ShellPush.instance;
    try {
      await push.initialize();
      expect(push.initialized, false);
      // Desired UID survives a failed initialization, then a failed binding.
      await push.login('retry-account', visible: false);
      expect(push.initialized, true);
      expect(push.uid, isNull);
      push.chats.visible = true;
      await push.retryPending();
      expect(push.uid, 'retry-account');
      expect(logins, 2);
      expect(calls, isNot(contains('OneSignal#requestPermission')));
      push.setVisible(false);
      push.setVisible(true);
      await Future<void>.delayed(Duration.zero);
      expect(push.notificationFailure, contains('clearBadge'));
      for (var i = 0; i < 5; i++) {
        await push.retryPending();
      }
      expect(badgeCalls, 3);
      expect(push.notificationFailure, isNotNull);
      badgeOK = true;
      await push.onWebEvent('unreadCount', {'count': '0'});
      expect(push.notificationFailure, isNull);
      await push.logout();
      final before = logins;
      await push.retryPending();
      expect(logins, before);
      expect(push.uid, isNull);
    } finally {
      push.setVisible(false);
    }
  });
}
