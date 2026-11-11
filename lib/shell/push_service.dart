import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import 'push_intent.dart';
import 'shell_config.dart';
import 'chat_state.dart';

class ShellPush extends ChangeNotifier {
  ShellPush._();
  static final instance = ShellPush._();
  final intents = PushIntentQueue();
  final chats = ShellChatState();
  static const _native = MethodChannel('yueh/shell');
  SharedPreferences? _preferences;
  Future<void> _identity = Future.value();
  String? uid, _lastUid;
  bool initialized = false, _askingPermission = false;
  int openRequest = 0, foregroundMessage = 0;
  int _epoch = 0;
  String? _desiredUid;
  Future<void>? _initializing;
  Timer? _retryTimer;
  int _retryAttempt = 0, _badgeAttempts = 0;
  bool _bindingFailed = false, _badgePending = false;
  int _bindingInFlight = 0;
  bool _logoutPending = false;
  String? notificationFailure;

  /// Spec 5.4 (Android): the badge mirrors Web's unread total. iOS is unchanged for now.
  @visibleForTesting
  bool? countBadgeOverride;
  bool get _countBadge => countBadgeOverride ?? Platform.isAndroid;

  void _scheduleRetry() {
    if (_retryTimer != null || !chats.visible) return;
    final seconds = [5, 15, 30, 60, 300][_retryAttempt.clamp(0, 4)];
    _retryAttempt++;
    _retryTimer = Timer(Duration(seconds: seconds), () {
      _retryTimer = null;
      unawaited(retryPending());
    });
  }

  Future<void> retryPending() async {
    if (!chats.visible) return;
    if (!initialized) await initialize();
    if (initialized && _logoutPending) await _retryLogout();
    final wanted = _desiredUid;
    if (initialized &&
        _bindingFailed &&
        wanted != null &&
        _bindingInFlight == 0) {
      await login(wanted, visible: chats.visible);
    }
    if (_badgePending && _badgeAttempts < 3) await _nativeCall('clearBadge');
  }

  String status = 'Not initialized';

  Future<void> initialize() {
    if (initialized) return Future.value();
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  Future<void> _initialize() async {
    final appId = Platform.isAndroid
        ? ShellConfig.androidOneSignalId
        : ShellConfig.iosOneSignalId;
    if (appId.isEmpty) {
      status = 'App ID is not configured';
      return;
    }
    try {
      _preferences = await SharedPreferences.getInstance();
      _lastUid = _preferences!.getString('push.lastUid');
      await OneSignal.Debug.setLogLevel(OSLogLevel.none);
      await OneSignal.initialize(appId);
      await OneSignal.InAppMessages.paused(true);
      OneSignal.Notifications.addClickListener((event) {
        final intent = ChatPushIntent.parse(
          event.notification.notificationId,
          event.notification.additionalData,
          _lastUid,
          DateTime.now(),
        );
        if (intent != null && !intents.add(intent)) return;
        openRequest++;
        notifyListeners();
      });
      OneSignal.Notifications.addForegroundWillDisplayListener((event) {
        if (chats.suppress(event.notification.additionalData)) {
          event.preventDefault();
        }
        foregroundMessage++;
        notifyListeners();
      });
      OneSignal.Notifications.addPermissionObserver((granted) {
        if (granted && uid != null) {
          unawaited(
            OneSignal.User.pushSubscription.optIn().catchError((Object _) {
              status = 'Could not restore the push subscription. Retrying automatically.';
              _bindingFailed = true;
              _scheduleRetry();
              notifyListeners();
            }),
          );
        }
        _updateStatus();
      });
      OneSignal.User.pushSubscription.addObserver((_) => _updateStatus());
      initialized = true;
      _updateStatus();
    } catch (_) {
      status = 'Could not initialize notifications. Retrying automatically.';
      _scheduleRetry();
      notifyListeners();
    }
  }

  Future<bool> _nativeCall(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _native.invokeMethod(method, args);
      if (result == false) {
        throw StateError(
          'The operation failed or is unsupported by the launcher',
        );
      }
      if (method == 'clearBadge') {
        _badgePending = false;
        _badgeAttempts = 0;
        notificationFailure = null;
      }
      return true;
    } catch (_) {
      notificationFailure = 'Notification operation did not complete: $method';
      status = notificationFailure!;
      if (method == 'clearBadge') {
        _badgePending = true;
        _badgeAttempts++;
        if (_badgeAttempts < 3) _scheduleRetry();
      }
      // Keep a persistent diagnostic even when launcher capability is unsupported.
      unawaited(
        _native
            .invokeMethod('log', {'message': notificationFailure})
            .catchError((Object _) {}),
      );
      notifyListeners();
      return false;
    }
  }

  void setVisible(bool value) {
    final entered = value && !chats.visible;
    chats.visible = value;
    if (!value) {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    if (entered) {
      if (!_countBadge) {
        _badgeAttempts = 0;
        unawaited(_nativeCall('clearBadge'));
      }
      unawaited(retryPending());
    }
  }

  Future<void> onWebEvent(String name, Map<String, String> params) async {
    chats.event(name, params);
    final chat = ShellChatState.chatId(params) ?? chats.currentChat;
    if ((name == 'chatOpen' || name == 'chatRead') && chat != null) {
      final group = params['thread_id'] ?? chat;
      if (initialized && Platform.isAndroid) {
        try {
          await OneSignal.Notifications.removeGroupedNotifications(group);
        } catch (_) {
          // The native path below independently removes this conversation.
          notificationFailure = 'Could not clear conversation notifications through the SDK; system cleanup was attempted';
        }
      }
      await _nativeCall('clearThread', {'chatId': chat, 'threadId': group});
    }
    if (_countBadge) {
      if (name == 'unreadCount') {
        final count = int.tryParse(params['count'] ?? '');
        if (count != null) await _nativeCall('setBadge', {'count': count});
      }
      return;
    }
    if (name == 'chatRead' ||
        (name == 'unreadCount' &&
            int.tryParse(
                  params['count'] ??
                      params['unreadCount'] ??
                      params['unread_count'] ??
                      '',
                ) ==
                0)) {
      await _nativeCall('clearBadge');
    }
  }

  void _updateStatus() {
    status =
        notificationFailure ??
        (!OneSignal.Notifications.permission
            ? 'Notifications initialized; permission has not been granted'
            : OneSignal.User.pushSubscription.id == null
            ? 'Notifications initialized; waiting for a push subscription'
            : 'Push subscription established; delivery requires provider configuration');
    notifyListeners();
  }

  Future<void> login(String nextUid, {required bool visible}) {
    if (nextUid.isEmpty) return Future.value();
    _logoutPending = false;
    _desiredUid = nextUid;
    _bindingFailed = true;
    final epoch = ++_epoch;
    _bindingInFlight++;
    // Serialize account changes so a slow login cannot overwrite a later logout.
    _identity = _identity
        .then((_) async {
          if (epoch != _epoch) return;
          if (!initialized) await initialize();
          if (!initialized || epoch != _epoch) {
            _scheduleRetry();
            return;
          }
          if (_lastUid != null && _lastUid != nextUid) {
            chats.currentChat = null;
            intents.clear();
            await OneSignal.logout();
            await OneSignal.Notifications.clearAll();
          }
          uid = null;
          await OneSignal.login(nextUid);
          if (epoch != _epoch) return;
          if (OneSignal.Notifications.permission) {
            await OneSignal.User.pushSubscription.optIn();
          }
          if (epoch != _epoch) return;
          _lastUid = uid = nextUid;
          await _preferences!.setString('push.lastUid', nextUid);
          if (epoch != _epoch) return;
          _bindingFailed = false;
          _retryAttempt = 0;
          _updateStatus();
        })
        .catchError((Object _) {
          if (epoch != _epoch) return;
          _bindingFailed = true;
          status = 'Could not link notifications to this account. Retrying automatically.';
          _scheduleRetry();
          notifyListeners();
        });
    return _identity.whenComplete(() => _bindingInFlight--).then((_) async {
      if (visible && uid == nextUid) await requestPermission();
    });
  }

  Future<void> logout() {
    chats.currentChat = null;
    _epoch++;
    _desiredUid = null;
    _logoutPending = true;
    _bindingFailed = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    uid = null;
    intents.clear();
    if (!initialized) {
      _lastUid = null;
      return SharedPreferences.getInstance().then((prefs) async {
        await prefs.remove('push.lastUid');
      });
    }
    return _retryLogout();
  }

  Future<void> _retryLogout() {
    final epoch = _epoch;
    _identity = _identity.then((_) async {
      if (epoch != _epoch || !_logoutPending) return;
      uid = null;
      _lastUid = null;
      var failed = false;
      // A failure to opt out must not prevent the independent SDK logout.
      for (final operation in <Future<void> Function()>[
        () async {
          await _preferences!.remove('push.lastUid');
        },
        OneSignal.User.pushSubscription.optOut,
        OneSignal.logout,
        OneSignal.Notifications.clearAll,
      ]) {
        if (epoch != _epoch) return;
        try {
          await operation();
        } catch (_) {
          failed = true;
        }
      }
      if (epoch != _epoch) return;
      _logoutPending = failed;
      if (failed) {
        status = 'Could not unlink notifications. Retrying automatically.';
        _scheduleRetry();
      }
      notifyListeners();
    });
    return _identity;
  }

  Future<void> requestPermission() async {
    if (!initialized ||
        uid == null ||
        _askingPermission ||
        _preferences!.getBool('push.permissionAsked') == true) {
      return;
    }
    _askingPermission = true;
    final permissionUid = uid;
    final permissionEpoch = _epoch;
    try {
      await _preferences!.setBool('push.permissionAsked', true);
      if (!OneSignal.Notifications.permission &&
          await OneSignal.Notifications.canRequest()) {
        final granted = await OneSignal.Notifications.requestPermission(false);
        if (granted && uid == permissionUid && _epoch == permissionEpoch) {
          await OneSignal.User.pushSubscription.optIn();
        }
      }
      _updateStatus();
    } catch (_) {
      _bindingFailed = _desiredUid != null;
      _scheduleRetry();
      status = 'Could not update notification permission or subscription';
    } finally {
      _askingPermission = false;
    }
  }
}
