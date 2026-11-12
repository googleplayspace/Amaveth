// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'package:flutter_test/flutter_test.dart';
import 'package:Amaveth/shell/push_intent.dart';

void main() {
  final now = DateTime(2026, 11, 6);
  ChatPushIntent intent(String id, {String? owner = 'alice'}) =>
      ChatPushIntent.parse(
        id,
        {'chat_id': 'chat', 'msg_id': '42'},
        owner,
        now,
      )!;
  test('server payload uses contract names and preserves string uid', () {
    final value = ChatPushIntent.parse(
      'id',
      {'chat_id': '00123', 'msg_id': 8842},
      'alice',
      now,
    )!;
    expect(value.payload, {'chatId': '00123', 'messageId': '8842'});
  });
  test('invalid payloads cannot become arbitrary navigation', () {
    expect(
      ChatPushIntent.parse('id', {'url': 'https://other.test'}, null, now),
      isNull,
    );
    expect(ChatPushIntent.parse('id', {'chat_id': {}}, null, now), isNull);
    expect(
      ChatPushIntent.parse(
        'id',
        {'chat_id': 'chat', 'msg_id': 'bad'},
        null,
        now,
      )!.payload,
      {'chatId': 'chat'},
    );
  });
  test('notification id is delivered once even after removal', () {
    final queue = PushIntentQueue();
    expect(queue.add(intent('id')), true);
    expect(queue.add(intent('id')), false);
    expect(queue.take('alice', now), isNotNull);
    expect(queue.add(intent('id')), false);
    expect(queue.take('alice', now), isNull);
  });
  test('old account intent is discarded when another account logs in', () {
    final queue = PushIntentQueue()..add(intent('id'));
    expect(queue.take('bob', now), isNull);
    expect(queue.isNotEmpty, false);
  });
  test('explicit recipient overrides local account snapshot', () {
    final value = ChatPushIntent.parse(
      'id',
      {'chat_id': 'chat', 'recipient_uid': 'bob'},
      'alice',
      now,
    )!;
    final queue = PushIntentQueue()..add(value);
    expect(queue.take('bob', now), value);
  });
  test('cold start queue waits for caller to supply authenticated uid', () {
    final queue = PushIntentQueue()..add(intent('cold', owner: null));
    expect(queue.isNotEmpty, true);
    expect(queue.take('alice', now)!.notificationId, 'cold');
  });
  test('logout clears pending clicks and expired clicks are not replayed', () {
    final queue = PushIntentQueue()..add(intent('old'));
    expect(queue.take('alice', now.add(const Duration(minutes: 11))), isNull);
    queue.add(intent('pending'));
    queue.clear();
    expect(queue.take('alice', now), isNull);
  });
  test('pending queue is bounded to ten recent notifications', () {
    final queue = PushIntentQueue();
    for (var i = 0; i < 20; i++) {
      queue.add(intent('$i'));
    }
    expect(queue.take('alice', now)!.notificationId, '10');
  });
}
