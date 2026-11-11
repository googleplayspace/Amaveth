import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'shell/push_service.dart';
import 'shell/remote_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Neither call may block runApp: when B is cached, Android starts Dart from
  // ShellApplication with no Flutter Activity, so plugins that need one (the
  // platform channel behind SystemChrome) would never answer.
  unawaited(ShellPush.instance.initialize());
  unawaited(
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
  );
  // Read before the first frame so a cached B starts without any waiting screen.
  final cachedUrl = await RemoteConfig.cachedUrl();
  runApp(AmavethApp(enableIm: true, cachedUrl: cachedUrl));
}
