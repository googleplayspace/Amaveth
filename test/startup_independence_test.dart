import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:Amaveth/app.dart';
import 'package:Amaveth/core/document_store.dart';
import 'package:Amaveth/core/money_book.dart';
import 'package:Amaveth/shell/ab_host.dart';
import 'package:Amaveth/shell/im_screen.dart';
import 'package:Amaveth/shell/remote_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RemoteConfig.startup, (_) async => null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('yueh/shell'), (
      call,
    ) async {
      // No native WebView is created in a widget test. Fail metadata explicitly
      // while still proving that the B route is constructed independently of A.
      if (call.method == 'metadata') {
        throw PlatformException(code: 'test_native_unavailable');
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

  testWidgets('native decision lookup starts before the A database finishes', (
    t,
  ) async {
    final book = Completer<MoneyBook>();
    var fetched = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(RemoteConfig.startup, (call) async {
          if (call.method == 'snapshot') {
            fetched = true;
            return {'face': 'a', 'revision': 1};
          }
          return null;
        });
    await t.pumpWidget(
      AmavethApp(enableIm: true, bookLoader: () => book.future),
    );
    await t.pump(const Duration(milliseconds: 100));
    expect(fetched, isTrue);
    expect(find.byType(AbHost), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    book.complete(MoneyBook(MemoryDocumentStore()));
    await t.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('cached B remains selected while the A database fails', (
    t,
  ) async {
    final book = Completer<MoneyBook>();
    SharedPreferences.setMockInitialValues({
      RemoteConfig.cacheKey: 'https://example.test/?channelCode=fixture',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          RemoteConfig.startup,
          (_) async => {
            'face': 'b',
            'url': 'https://example.test/?channelCode=fixture',
            'revision': 1,
          },
        );
    RemoteConfig.fetchOverride = () async => FaceConfig.unknown;
    await t.pumpWidget(
      AmavethApp(
        enableIm: true,
        cachedUrl: 'https://example.test/?channelCode=fixture',
        bookLoader: () => book.future,
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(ImScreen), findsOneWidget);
    book.completeError(StateError('simulated encrypted storage failure'));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(AbHost), findsOneWidget);
    expect(find.byType(ImScreen), findsOneWidget);
    expect(
      find.text(
        'Could not open the private ledger. Your data has not been reset.',
      ),
      findsNothing,
    );
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 100));
  });
}
