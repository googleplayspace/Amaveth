import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Amaveth/shell/ab_host.dart';
import 'package:Amaveth/shell/im_screen.dart';
import 'package:Amaveth/shell/remote_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, dynamic>? state;
  Future<Map<String, dynamic>?> Function()? snapshot;
  Future<void> decision(WidgetTester t, Map<String, dynamic> next) async {
    state = next;
    final done = Completer<void>();
    // Test a real incoming native MethodChannel event, not an alternate widget-only path.
    // ignore: deprecated_member_use
    messenger.handlePlatformMessage(
      'yueh/startup',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('decision', next),
      ),
      (_) {
        done.complete();
      },
    );
    await done.future;
    await t.pump();
    await t.pump(const Duration(milliseconds: 20));
  }

  Widget host() =>
      MaterialApp(home: AbHost(toolBuilder: (_) => const Text('Ledger')));
  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 100));
  }

  setUp(() {
    state = {'face': 'pending', 'revision': 0};
    snapshot = null;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(RemoteConfig.startup, (call) async {
      if (call.method == 'snapshot') {
        return snapshot == null ? state : snapshot!();
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('yueh/shell'), (
      call,
    ) async {
      if (call.method == 'metadata') {
        throw PlatformException(code: 'native_fixture');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('app/webview_info'),
      (_) async => {
        'versionName': '156.0.0',
        'packageName': 'com.google.android.webview',
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['none'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
  });
  tearDown(() {
    RemoteConfig.fetchOverride = null;
  });

  testWidgets(
    'pending does not expose A or any Flutter loading screen after three seconds',
    (t) async {
      await t.pumpWidget(host());
      await t.pump(const Duration(seconds: 4));
      expect(find.text('Ledger'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await decision(t, {
        'face': 'a',
        'revision': 1,
        'reason': 'unavailableWithoutCache',
      });
      expect(find.text('Ledger'), findsOneWidget);
      await close(t);
    },
  );
  testWidgets(
    'foreground enables B immediately and changed URL updates existing bridge state',
    (t) async {
      state = {'face': 'a', 'revision': 1};
      await t.pumpWidget(host());
      await t.pump();
      expect(find.text('Ledger'), findsOneWidget);
      const first = 'https://example.test/?ChannelCode=a%2Bb';
      await decision(t, {'face': 'b', 'url': first, 'revision': 2});
      expect(find.text('Ledger'), findsNothing);
      final element = t.element(find.byType(ImScreen));
      expect(t.widget<ImScreen>(find.byType(ImScreen)).entryUrl, first);
      await decision(t, {'face': 'b', 'url': first, 'revision': 3});
      expect(t.element(find.byType(ImScreen)), same(element));
      const next = 'https://second.example.test/?channelcode=b%2Fc';
      await decision(t, {'face': 'b', 'url': next, 'revision': 4});
      expect(t.widget<ImScreen>(find.byType(ImScreen)).entryUrl, next);
      expect(t.element(find.byType(ImScreen)), same(element));
      await close(t);
    },
  );
  testWidgets(
    '404 removes active B immediately; later foreground can enable it again',
    (t) async {
      state = {'face': 'b', 'url': 'https://example.test/', 'revision': 1};
      await t.pumpWidget(host());
      await t.pump();
      expect(find.byType(ImScreen), findsOneWidget);
      await decision(t, {'face': 'a', 'revision': 2, 'reason': 'http404'});
      expect(find.byType(ImScreen), findsNothing);
      expect(find.text('Ledger'), findsOneWidget);
      await decision(t, {
        'face': 'b',
        'url': 'https://example.test/new',
        'revision': 3,
      });
      expect(find.byType(ImScreen), findsOneWidget);
      await close(t);
    },
  );
  testWidgets('late startup snapshot cannot undo a newer native 404 decision', (
    t,
  ) async {
    final pending = Completer<Map<String, dynamic>?>();
    snapshot = () => pending.future;
    await t.pumpWidget(host());
    await decision(t, {'face': 'a', 'revision': 7, 'reason': 'http404'});
    pending.complete({
      'face': 'b',
      'url': 'https://old.example.test/',
      'revision': 6,
    });
    await t.pump();
    expect(find.text('Ledger'), findsOneWidget);
    expect(find.byType(ImScreen), findsNothing);
    await close(t);
  });
}
