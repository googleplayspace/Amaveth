import 'dart:async';

import 'package:flutter/material.dart';

import 'im_screen.dart';
import 'remote_config.dart';
import 'shell_config.dart';
import 'push_service.dart';
import 'webview_version_checker.dart';

/// The native launch cover owns waiting; Flutter never supplies a B loading page.
class AbHost extends StatefulWidget {
  final String? cachedUrl;
  final WidgetBuilder toolBuilder;
  const AbHost({super.key, this.cachedUrl, required this.toolBuilder});
  @override
  State<AbHost> createState() => _AbHostState();
}

class _AbHostState extends State<AbHost> with WidgetsBindingObserver {
  AppFace? face;
  String? entry;
  bool nativeOwned = false, fetching = false;
  int revision = -1;
  int pushRequest = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pushRequest = ShellPush.instance.openRequest;
    ShellPush.instance.addListener(onPush);
    final cached = widget.cachedUrl;
    if (cached != null && cached.isNotEmpty) {
      entry = cached;
      ShellConfig.webAddress = cached;
      face = AppFace.im;
    }
    RemoteConfig.startup.setMethodCallHandler((call) async {
      if (call.method == 'decision' && mounted) {
        nativeOwned = true;
        applyNative(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    unawaited(start());
  }

  Future<void> start() async {
    final state = await RemoteConfig.nativeSnapshot();
    if (!mounted) return;
    if (state != null) {
      nativeOwned = true;
      applyNative(state);
    } else {
      await refresh();
    }
  }

  void applyNative(Map<String, dynamic> state) {
    final nextRevision = state['revision'] as int? ?? 0;
    if (nextRevision < revision) return;
    revision = nextRevision;
    final status = state['face'];
    if (status == 'b' && state['url'] is String) {
      apply(FaceConfig(ConfigVerdict.b, url: state['url'] as String));
    } else if (status == 'a') {
      apply(FaceConfig.a);
      // Release the native cover only after the A tree has actually painted.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && face == AppFace.tool && revision == nextRevision) {
          unawaited(
            RemoteConfig.startup.invokeMethod<void>('ackA', {
              'revision': revision,
            }),
          );
        }
      });
    }
  }

  void apply(FaceConfig config) {
    if (!mounted || config.verdict == ConfigVerdict.unknown) return;
    final next = config.verdict == ConfigVerdict.b ? AppFace.im : AppFace.tool;
    final nextEntry = next == AppFace.im ? config.url : null;
    if (next == face && nextEntry == entry) return;
    if (next == AppFace.im) ShellConfig.webAddress = config.url;
    setState(() {
      face = next;
      entry = nextEntry;
    });
    if (next == AppFace.im) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) WebViewVersionChecker.checkAndPrompt(context);
      });
    }
  }

  Future<void> refresh() async {
    if (fetching) return;
    fetching = true;
    try {
      if (nativeOwned) {
        await RemoteConfig.startup.invokeMethod<void>('refresh');
      } else {
        final decision = await RemoteConfig.resolve();
        if (decision.verdict == ConfigVerdict.a) {
          await RemoteConfig.forgetNative();
        }
        apply(decision);
      }
    } finally {
      fetching = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Native observes true process foreground even while Flutter is behind ImActivity.
    if (!nativeOwned && state == AppLifecycleState.resumed) {
      unawaited(refresh());
    }
  }

  void onPush() {
    if (!mounted || pushRequest == ShellPush.instance.openRequest) return;
    pushRequest = ShellPush.instance.openRequest;
    // No push may override a 404 or an undecided mock result.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ShellPush.instance.removeListener(onPush);
    RemoteConfig.startup.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (face == null) return const SizedBox.shrink();
    if (face == AppFace.tool) return Builder(builder: widget.toolBuilder);
    return Theme(
      data: ThemeData.light(useMaterial3: true),
      child: ImScreen(active: true, entryUrl: entry, onExit: () {}),
    );
  }
}
