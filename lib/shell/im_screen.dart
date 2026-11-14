import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'shell_config.dart';
import 'bridge_script.dart';
import 'watchdog.dart';
import 'signal_gate.dart';
import 'diagnostic_text.dart';
import 'network_probe.dart';
import 'network_wake.dart';

import 'push_service.dart';
import 'shell_web.dart';

class ImScreen extends StatefulWidget {
  final bool active;
  final VoidCallback onExit;
  final String? entryUrl;
  const ImScreen({
    super.key,
    required this.active,
    required this.onExit,
    this.entryUrl,
  });
  @override
  State<ImScreen> createState() => _ImScreenState();
}

class _ImScreenState extends State<ImScreen> with WidgetsBindingObserver {
  static const native = MethodChannel('yueh/shell');
  ShellWeb? web;
  Map<String, dynamic>? metadata;
  final clock = Stopwatch()..start();
  final watchdog = ShellWatchdog();
  final signals = ShellSignalGate();
  final push = ShellPush.instance;
  bool deliveringPush = false;
  int foregroundPush = 0;
  bool? surfaceVisible;
  final logs = Queue<String>();
  bool initialized = false, initDone = false;
  Timer? loadingCap;
  bool? sentLoading;
  String? sentError;
  // The IM surface is native on both platforms, independent of the Flutter window.
  bool foreground = false, ready = false, loading = true, disposed = false;
  int generation = 0;
  int initializationEpoch = 0;

  /// Page URL to restore when the WebView instance is rebuilt. A rebuild is a last
  /// resort, so the user keeps their place instead of being dropped at the entry
  /// route. Only a trusted same-origin URL is restored; null means the entry URL.
  String? resumeUrl;
  String? error;
  String network = 'none', networkCandidate = 'other', ua = '';
  int networkEpoch = 0, diagnosticTaps = 0, permissionEpoch = 0;
  DateTime? lastReloadAt, lastReloadCompletedAt;
  Timer? diagnosticTapTimer;
  Timer? debounce;
  StreamSubscription<List<ConnectivityResult>>? networkSubscription;
  bool get visible => widget.active && foreground;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    foregroundPush = push.foregroundMessage;
    push.addListener(onPushChanged);
    native.setMethodCallHandler((call) async {
      if (disposed) return;
      if (call.method == 'imEvent') {
        await onNativeEvent(Map<String, dynamic>.from(call.arguments as Map));
        return;
      }
      if (call.method == 'webEvent') {
        final data = Map<String, dynamic>.from(call.arguments as Map);
        if (web == null || '${data['viewId']}' != web!.id) return;
        try {
          await event([data['name'], jsonDecode(data['json'] as String)]);
        } catch (e) {
          log('native event rejected: ${e.runtimeType}');
        }
      }
      if (call.method == 'memory') await invoke('onMemoryWarning');
      if (call.method == 'tick') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (error != null && !rendererMustExit) {
          watchdog.tick(clock.elapsedMilliseconds);
          return;
        }
        if (!rendererMustExit && visible && args['heartbeat'] == true) {
          log('native heartbeat');
          unawaited(invoke('onHeartbeat'));
        }
        if (!rendererMustExit && args['network'] is String) {
          networkChanged(args['network']);
        }
        switch (watchdog.check(clock.elapsedMilliseconds)) {
          case Recovery.reload:
            log('watchdog reload');
            ready = false;
            push.chats.resetDocument();
            lastReloadAt = DateTime.now();
            unawaited(
              web?.reload().timeout(const Duration(seconds: 3)).catchError((
                    Object e,
                  ) {
                    log('reload pending: $e');
                  }) ??
                  Future<void>.value(),
            );
          case Recovery.rebuild:
            unawaited(recoverHungRenderer('reload did not start'));
          case Recovery.none:
            break;
        }
      }
    });
    initialize();
    networkSubscription = Connectivity().onConnectivityChanged.listen((types) {
      // Android uses the native VALIDATED network snapshot instead.
      if (Platform.isAndroid) return;
      networkChanged(
        types.contains(ConnectivityResult.wifi)
            ? 'wifi'
            : types.contains(ConnectivityResult.mobile)
            ? 'cellular'
            : types.contains(ConnectivityResult.ethernet)
            ? 'ethernet'
            : types.contains(ConnectivityResult.none)
            ? 'none'
            : 'other',
      );
    });
  }

  void log(String message) {
    final safe = diagnosticText(message);
    logs.add('${DateTime.now().toIso8601String()} $safe');
    unawaited(
      native.invokeMethod('log', {'message': safe}).catchError((Object _) {}),
    );
    if (kDebugMode) debugPrint('SSG $safe');
    while (logs.length > 150) {
      logs.removeFirst();
    }
  }

  Future<void> initialize() async {
    final epoch = ++initializationEpoch;
    final entryUrl = widget.entryUrl ?? ShellConfig.webAddress;
    try {
      metadata = Map<String, dynamic>.from(
        await native.invokeMethod('metadata') as Map,
      );
      if (disposed || epoch != initializationEpoch) return;
      networkCandidate = Platform.isAndroid
          ? (metadata!['networkType'] as String? ?? 'other')
          : connectionType(await Connectivity().checkConnectivity());
      final uaSuffix =
          ' SSGShell/${metadata!['shellVersion']} ${Platform.isAndroid ? 'Android' : 'iOS'}';
      if (disposed || epoch != initializationEpoch) return;
      final origin = Uri.parse(entryUrl).origin;
      final prepared = (Platform.isAndroid || Platform.isIOS)
          ? Map<String, dynamic>.from(
              await native.invokeMethod('imPrepare', {
                // Spec 2.1: the configured url verbatim, never re-serialised.
                'url': entryUrl,
                'origin': origin,
                // Spec 6 / 7: no download script; the page only gets the shell metadata.
                'script': shellScript(metadata!, origin),
                'uaSuffix': uaSuffix,
              }) as Map,
            )
          : null;
      if (disposed || epoch != initializationEpoch) return;
      if (prepared != null && prepared['documentStart'] != true) {
        throw UnsupportedError(
          'This WebView does not support the required startup injection. Update Android System WebView or Chrome and try again.',
        );
      }
      log('injection mode: document-start');
      if (Platform.isAndroid) log('Android composition: native Activity');
      ua = prepared?['ua'] as String? ?? '';
      if (disposed) return;
      initialized = true;
      await visibility();
    } catch (e) {
      if (disposed || epoch != initializationEpoch) return;
      error = e is UnsupportedError
          ? 'The web component on this device needs an update. Update it and try again. The local tools remain available.'
          : 'Could not open the online service: $e';
    }
    initDone = true;
    if (mounted) setState(() {});
    if ((Platform.isAndroid || Platform.isIOS) && widget.active && !disposed) {
      await openNativeIm();
    }
  }

  /// Brings up ImActivity; it shows the page, or Dart's error state when there is none.
  Future<void> openNativeIm() async {
    final id = await native.invokeMethod<int>('imOpen');
    if (id != null) web = NativeShellWeb('$id');
    pushNativeUi();
    armLoadingCap();
  }

  void pushNativeUi() {
    if ((!Platform.isAndroid && !Platform.isIOS) || disposed) return;
    if (sentLoading == loading && sentError == error) return;
    sentLoading = loading;
    sentError = error;
    unawaited(
      native
          .invokeMethod('imState', {'loading': loading, 'error': error})
          .catchError((Object _) {}),
    );
  }

  /// Flutter does not build while ImActivity covers it, so state is mirrored here.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    pushNativeUi();
  }

  /// Spec 9.6: webReady may never come; never leave the cover up indefinitely.
  void armLoadingCap() {
    loadingCap?.cancel();
    loadingCap = Timer(const Duration(seconds: 30), () {
      if (disposed || !mounted || !loading) return;
      log('webReady not received in 30s; removing cover');
      setState(() => loading = false);
    });
  }

  Future<void> onNativeEvent(Map<String, dynamic> event) async {
    switch (event['type']) {
      case 'userAgent':
        ua = event['value'] as String? ?? ua;
      case 'visible':
        foreground = event['value'] == true;
        await visibility();
      case 'exit':
        widget.onExit();
      case 'refresh':
        unawaited(softReload('user retry'));
      case 'retry':
        if (!initialized) {
          setState(() => error = null);
          await initialize();
        } else {
          unawaited(softReload('error retry'));
        }
      case 'titleTap':
        diagnosticTap();
      case 'diagnostics':
        await diagnostics();
      case 'loadStart':
        if (rendererMustExit || web == null) return;
        pageStarted();
      case 'loadStop':
        if (rendererMustExit || web == null) return;
        await pageFinished(web!);
      case 'loadError':
        setState(() {
          error =
              'Could not load the page. Check your connection and try again.';
          loading = false;
        });
      case 'httpError':
        setState(() {
          error = 'The server returned ${event['status']}. Please try again.';
          loading = false;
        });
      case 'tls':
        log('TLS rejected: ${event['host']}');
        if (event['host'] == ShellConfig.entry.host) {
          setState(() {
            error = 'The security certificate could not be verified. Check your connection or try again later.';
            loading = false;
          });
        }
      case 'console':
        log('console ${event['level']}: ${event['message']}');
      case 'gone':
        rendererMustExit = false;
        log('renderer gone');
        if (rendererGone != null) {
          if (!rendererGone!.isCompleted) {
            rendererGone!.complete();
          }
        } else {
          rebuild('render process gone');
        }
      case 'window':
        await nativeWindow(event['url'] as String);
    }
  }

  Future<void> nativeWindow(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    // Spec 6 / 7: blob:/data: windows were file downloads, which are not offered.
    if (['blob', 'data'].contains(uri.scheme)) return;
    if (ShellConfig.trusted(uri)) {
      await native.invokeMethod('imLoad', {'url': url});
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void pageStarted() {
    signals.resetDocument();
    push.chats.resetDocument();
    networkWake.resetDocument();
    ready = false;
    watchdog.loadStarted();
    log('load start');
    armLoadingCap();
    if (mounted) {
      setState(() {
        loading = true;
      });
    }
  }

  Future<void> pageFinished(ShellWeb page) async {
    log('load complete; waiting webReady');
    final check = await page.evaluate(
      '''JSON.stringify({injected:!!window.__SSG_SHELL__,browser:document.documentElement.classList.contains('is-web-browser'),secure:isSecureContext,ua:navigator.userAgent.includes('SSGShell/'),bridge:!!window.jsBridge,callback:!!window.__ssgShell,sw:!!(navigator.serviceWorker&&navigator.serviceWorker.controller)})''',
    );
    log('selfcheck $check');
  }

  Future<void> openWebViewUpdate() async {
    try {
      await native.invokeMethod('openWebViewUpdate');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open the update page. Update Android System WebView in Google Play.',
            ),
          ),
        );
      }
    }
  }

  void diagnosticTap() {
    diagnosticTapTimer?.cancel();
    diagnosticTapTimer = Timer(
      const Duration(seconds: 4),
      () => diagnosticTaps = 0,
    );
    if (++diagnosticTaps >= 7) {
      diagnosticTaps = 0;
      unawaited(diagnostics());
    }
  }

  String connectionType(List<ConnectivityResult> types) =>
      types.contains(ConnectivityResult.wifi)
      ? 'wifi'
      : types.contains(ConnectivityResult.mobile)
      ? 'cellular'
      : types.contains(ConnectivityResult.ethernet)
      ? 'ethernet'
      : types.contains(ConnectivityResult.none)
      ? 'none'
      : 'other';

  @override
  void didUpdateWidget(ImScreen old) {
    super.didUpdateWidget(old);
    if (old.entryUrl != widget.entryUrl && widget.entryUrl != null) {
      signals.resetDocument();
      push.chats.resetDocument();
      networkWake.resetDocument();
      ready = false;
      unawaited(initialize());
    }
    if (old.active == widget.active) return;
    if ((Platform.isAndroid || Platform.isIOS) && widget.active && initDone) {
      unawaited(openNativeIm());
    }
    visibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isAndroid || Platform.isIOS) {
      return; // Native host reports visibility.
    }
    foreground = state == AppLifecycleState.resumed;
    visibility();
  }

  Future<void> visibility() async {
    if (disposed) return;
    signals.visible = visible;
    push.setVisible(visible);
    watchdog.visibility(visible, clock.elapsedMilliseconds);
    if (surfaceVisible != visible) {
      surfaceVisible = visible;
      await native.invokeMethod('active', {'value': visible});
      if (Platform.isAndroid) {
        if (visible) {
          await web?.resume();
        } else {
          await web?.pause();
        }
      }
    }
    await syncSignals();
    if (visible && signals.authenticated) unawaited(push.requestPermission());
    await flushPush();
  }

  void onPushChanged() {
    if (disposed) return;
    if (foregroundPush != push.foregroundMessage) {
      foregroundPush = push.foregroundMessage;
      if (signals.canProbe) networkChanged(networkCandidate, force: true);
    }
    unawaited(flushPush());
  }

  Future<void> flushPush() async {
    if (disposed ||
        deliveringPush ||
        !signals.canProbe ||
        !signals.authenticated ||
        push.uid == null ||
        web == null) {
      return;
    }
    deliveringPush = true;
    final controller = web!;
    final document = generation;
    try {
      if (!ShellConfig.trusted(await controller.url())) return;
      final available = await controller.evaluate(
        '!!(window.__ssgShell && typeof window.__ssgShell.openChat === "function")',
      );
      if (available != true ||
          disposed ||
          web != controller ||
          generation != document ||
          !signals.canProbe ||
          !signals.authenticated ||
          push.uid == null) {
        return;
      }
      while (push.intents.isNotEmpty &&
          signals.canProbe &&
          signals.authenticated &&
          push.uid != null) {
        final intent = push.intents.take(push.uid!, DateTime.now());
        if (intent == null) break;
        // Consume before invoking: never replay a notification after reload/error.
        await controller.evaluate(
          'window.__ssgShell.openChat(${jsonEncode(intent.payload)})',
        );
        log('push chat routed');
      }
    } catch (_) {
      log('push chat routing unavailable');
    } finally {
      deliveringPush = false;
    }
  }

  Future<void> syncSignals() async {
    signals.visible = visible;
    for (final method in signals.takeVisibilitySignals()) {
      final delivered = await invoke(method);
      if (method == 'onForeground' && delivered) {
        networkChanged(networkCandidate, force: true);
      }
    }
  }

  final networkWake = NetworkWake();
  int failedNetworkProbes = 0;
  void networkChanged(
    String next, {
    bool force = false,
    bool probeOnly = false,
  }) {
    if (!force && networkCandidate == next) return;
    networkCandidate = next;
    final epoch = ++networkEpoch;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 1500), () async {
      if (!visible || disposed) return;
      final reachable =
          next != 'none' && await shellNetworkReachable(ShellConfig.entry);
      if (disposed || !visible || epoch != networkEpoch) return;
      network = reachable ? next : 'none';
      if (network == 'none') networkWake.delivered = 'none';
      // A foreground wake may repeat an available network, never an unavailable one.
      if (networkWake.shouldDeliver(
        network,
        force: force,
        probeOnly: probeOnly,
      )) {
        if (await invoke('onNetwork', network)) networkWake.delivered = network;
      }
      if (reachable) {
        failedNetworkProbes = 0;
        unawaited(push.retryPending());
      }
      if (!reachable && next != 'none' && visible && !disposed) {
        debounce = Timer(
          Duration(
            seconds: [2, 5, 15, 30][(failedNetworkProbes++).clamp(0, 3)],
          ),
          () => networkChanged(next, force: true, probeOnly: true),
        );
      }
    });
  }

  Future<bool> invoke(String method, [Object? arg]) async {
    if (!signals.allows(method)) return false;
    if (web == null || disposed) return false;
    try {
      final delivered = await web!.evaluate(
        '(() => { const shell = window.__ssgShell; if (!shell || typeof shell.$method !== "function") return false; shell.$method(${arg == null ? '' : jsonEncode(arg)}); return true; })()',
      );
      if (delivered == true) log('native signal: $method');
      return delivered == true;
    } catch (_) {
      log('callback unavailable: $method');
      return false;
    }
  }

  bool recoveringRenderer = false, rendererMustExit = false;
  Completer<void>? rendererGone;
  Future<void> recoverHungRenderer(String reason) async {
    if (recoveringRenderer || disposed) return;
    final current = web;
    if (!Platform.isAndroid || current == null) {
      rebuild(reason);
      return;
    }
    recoveringRenderer = true;
    rendererMustExit = true;
    push.chats.resetDocument();
    ready = false;
    final gone = Completer<void>();
    rendererGone = gone;
    try {
      log('renderer terminate requested: $reason');
      final terminated = await native
          .invokeMethod<bool>('imTerminate')
          .timeout(const Duration(seconds: 3));
      if (terminated != true) {
        throw StateError('This web component cannot terminate the renderer');
      }
      // Never attach a replacement to the old, CPU-bound renderer.
      rendererMustExit =
          false; // Native result is completed only by onRenderProcessGone.
      log('renderer exit confirmed; rebuilding');
      if (!disposed && mounted) rebuild(reason);
    } catch (e) {
      log('renderer recovery failed: $e');
      watchdog.terminationFailed();
      if (!disposed && mounted) {
        setState(() {
          loading = false;
          error = 'The renderer has not stopped. Recovery will retry automatically. You can also update Android System WebView.';
        });
      }
    } finally {
      rendererGone = null;
      recoveringRenderer = false;
    }
  }

  /// Where a rebuilt WebView should start. The page the user was on wins when it is
  /// still a trusted same-origin URL; otherwise, and after the URL has been consumed,
  /// the configured entry route.
  String resumeTarget() {
    final raw = resumeUrl;
    resumeUrl = null;
    final resume = raw == null ? null : Uri.tryParse(raw);
    // Spec 2.1: the entry is the configured url verbatim, never re-serialised.
    return ShellConfig.trusted(resume) ? raw! : ShellConfig.webAddress;
  }

  /// User-visible refresh: reload the page in place and arm the ten second
  /// escalation. The WebView instance, its cookies, disk cache, DOM storage,
  /// IndexedDB and Service Worker all survive, and the page keeps its route, so
  /// this is never a cold start. Only escalate to [rebuild] when even the reload
  /// fails to begin loading.
  Future<void> softReload(String reason) async {
    if (!initialized) {
      if (mounted) setState(() => error = null);
      initialize();
      return;
    }
    if (rendererMustExit) {
      unawaited(recoverHungRenderer(reason));
      return;
    }
    final page = web;
    if (page == null) {
      // No live page to reload (never created, or already torn down).
      rebuild(reason);
      return;
    }
    lastReloadAt = DateTime.now();
    log('soft reload: $reason');
    signals.resetDocument();
    push.chats.resetDocument();
    networkWake.resetDocument();
    ready = false;
    loading = true;
    // Arms the ten second "did the page actually start loading" deadline; the
    // old code cleared it here, which disabled the escalation entirely. A user
    // refresh starts a new cycle, so it gets a fresh escalation budget.
    watchdog.awaitingReload(manual: true);
    if (mounted) setState(() => error = null);
    try {
      await page.reload().timeout(const Duration(seconds: 3));
    } catch (e) {
      log('reload pending: $e');
    }
    armLoadingCap();
  }

  void rebuild(String reason) async {
    if (rendererMustExit) {
      unawaited(recoverHungRenderer(reason));
      return;
    }
    if (!initialized) {
      if (mounted) setState(() => error = null);
      initialize();
      return;
    }
    lastReloadAt = DateTime.now();
    log('rebuild begin: $reason');
    // Native holders own route restoration; retain the last trusted URL for diagnostics.
    final current = web;
    if (current != null) {
      try {
        final url = await current.url();
        if (ShellConfig.trusted(url)) resumeUrl = url.toString();
      } catch (_) {}
    }
    web = null;
    signals.resetDocument();
    push.chats.resetDocument();
    networkWake.resetDocument();
    ready = false;
    loading = true;
    // Arm, do not clear, the ten second deadline: if the replacement page never
    // starts loading, only this deadline notices. The old loadStarted() call here
    // disabled it and left recovery to the 60 s alive timeout.
    watchdog.awaitingReload();
    if (mounted) {
      setState(() {
        generation++;
        error = null;
      });
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final id = await native.invokeMethod<int>('imRebuild');
      if (id != null) web = NativeShellWeb('$id');
      armLoadingCap();
    }
  }

  Future<dynamic> event(List<dynamic> args) async {
    if (disposed ||
        rendererMustExit ||
        !ShellConfig.trusted(await web?.url()) ||
        args.length != 2) {
      return null;
    }
    const names = {
      'eventWebReady': 'webReady',
      'eventRegister': 'register',
      'eventLogin': 'login',
      'eventLogout': 'logout',
      'eventMessageSent': 'messageSent',
      'eventWebAlive': 'webAlive',
      'eventChatOpen': 'chatOpen',
      'eventChatClose': 'chatClose',
      'eventChatRead': 'chatRead',
      'eventUnreadCount': 'unreadCount',
    };
    final payload = args[1];
    if (payload is! Map || names[args[0]] != payload['eventName']) return null;
    final params = payload['params'];
    if (params is! Map || params.values.any((v) => v is! String)) return null;
    log('event ${payload['eventName']} ${jsonEncode(params)}');
    await push.onWebEvent(
      payload['eventName'] as String,
      Map<String, String>.from(params),
    );
    if (payload['eventName'] == 'webAlive') watchdog.alive();
    if (payload['eventName'] == 'login' &&
        params['uid'] is String &&
        (params['uid'] as String).isNotEmpty) {
      signals.login();
      log('auth gate: opened by login');
      await syncSignals();
      await push.login(params['uid'] as String, visible: visible);
      await flushPush();
    }
    if (payload['eventName'] == 'logout') {
      signals.logout();
      log('auth gate: closed by logout');
      await push.logout();
    }
    if (payload['eventName'] == 'webReady') {
      if (lastReloadAt != null) {
        lastReloadCompletedAt = DateTime.now();
        log('reload/rebuild completed: webReady');
      }
      signals.ready = true;
      loadingCap?.cancel();
      if (mounted) {
        setState(() {
          ready = true;
          loading = false;
          error = null;
        });
      }
      await syncSignals();
      await flushPush();
    }
    return {'accepted': true, 'pushConfigured': push.initialized};
  }

  Future<void> diagnostics() async {
    final uri = await web?.url();
    final data = jsonEncode({
      'url': uri == null ? null : diagnosticUrl(uri),
      'lastReloadAt': lastReloadAt?.toIso8601String(),
      'lastReloadCompletedAt': lastReloadCompletedAt?.toIso8601String(),
      'ua': ua,
      'shell': metadata,
      'ready': ready,
      'active': visible,
      'channel': ShellConfig.channelCode,
      'push': push.status,
      'injectionMode': 'document-start',
      'log': logs.toList(),
    });
    if (Platform.isAndroid || Platform.isIOS) {
      await native.invokeMethod('imDiagnostics', {'text': data});
      return;
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Diagnostics'),
        content: SingleChildScrollView(child: SelectableText(data)),
        actions: [
          TextButton(
            onPressed: openAppSettings,
            child: const Text('Notification settings'),
          ),
          if (Platform.isAndroid)
            TextButton(
              onPressed: () => native.invokeMethod('openBatterySettings'),
              child: const Text('Battery settings'),
            ),
          if (Platform.isAndroid)
            TextButton(
              onPressed: openWebViewUpdate,
              child: const Text('Update WebView'),
            ),
          TextButton(
            onPressed: () async {
              final dir = await getTemporaryDirectory();
              final file = File('${dir.path}/im-diagnostics.json');
              await file.writeAsString(data);
              await SharePlus.instance.share(
                ShareParams(
                  files: [XFile(file.path)],
                  sharePositionOrigin: const Rect.fromLTWH(20, 100, 100, 40),
                ),
              );
            },
            child: const Text('Export'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    disposed = true;
    initializationEpoch++;
    loadingCap?.cancel();
    permissionEpoch++;
    networkEpoch++;
    diagnosticTapTimer?.cancel();
    push.setVisible(false);
    push.removeListener(onPushChanged);
    native.invokeMethod('active', {'value': false});
    native.setMethodCallHandler(null);
    debounce?.cancel();
    networkSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.white);
}
