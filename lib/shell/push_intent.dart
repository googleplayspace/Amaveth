import 'dart:collection';

class ChatPushIntent {
  final String notificationId, chatId;
  final String? messageId, ownerUid;
  final DateTime created;
  ChatPushIntent(
    this.notificationId,
    this.chatId,
    this.messageId,
    this.ownerUid,
    this.created,
  );

  Map<String, String> get payload => {
    'chatId': chatId,
    'messageId': ?messageId,
  };

  static ChatPushIntent? parse(
    String id,
    Map<String, dynamic>? data,
    String? owner,
    DateTime now,
  ) {
    if (id.isEmpty || data == null) return null;
    String? value(Object? input) {
      if (input is! String && input is! int) return null;
      final text = '$input';
      return text.isNotEmpty && text.length <= 256 ? text : null;
    }

    final chat = value(data['chatId'] ?? data['chat_id']);
    if (chat == null) return null;
    final message = value(
      data['messageId'] ?? data['msg_id'] ?? data['message_id'],
    );
    return ChatPushIntent(
      id,
      chat,
      message != null && int.tryParse(message) != null ? message : null,
      value(data['recipient_uid']) ?? owner,
      now,
    );
  }
}

/// Bounded, once-only routing. A different account never consumes an owned click.
class PushIntentQueue {
  final _pending = Queue<ChatPushIntent>();
  final _seen = <String>{};
  bool get isNotEmpty => _pending.isNotEmpty;
  bool add(ChatPushIntent intent) {
    if (!_seen.add(intent.notificationId)) return false;
    while (_seen.length > 100) {
      _seen.remove(_seen.first);
    }
    _pending.add(intent);
    while (_pending.length > 10) {
      _pending.removeFirst();
    }
    return true;
  }

  ChatPushIntent? take(String uid, DateTime now) {
    while (_pending.isNotEmpty) {
      final next = _pending.removeFirst();
      if (now.difference(next.created) > const Duration(minutes: 10)) continue;
      if (next.ownerUid != null && next.ownerUid != uid) continue;
      return next;
    }
    return null;
  }

  void clear() => _pending.clear();
}
