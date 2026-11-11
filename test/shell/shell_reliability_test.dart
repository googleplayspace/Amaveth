// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'package:flutter_test/flutter_test.dart';
import 'package:yueh/shell/chat_state.dart';
import 'package:yueh/shell/kernel_policy.dart';
import 'package:yueh/shell/watchdog.dart';
import 'package:yueh/shell/network_wake.dart';

void main() {
  test('version guidance is strictly below 92, independent of document-start support', () {
    expect(shouldPromptWebViewUpgrade('91.0.4472.0'), true);
    for (final version in [
      '92.0.0.0',
      '97.0.4692.98',
      '117.0.5938.60',
      'unknown',
      '',
      null,
    ]) {
      expect(shouldPromptWebViewUpgrade(version), false);
    }
  });
  test(
    'reload does not inherit conversation suppression, even after ready',
    () {
      final state = ShellChatState()..visible = true;
      state.event('chatOpen', {'chatId': 'old'});
      expect(state.suppress({'chat_id': 'old'}), false);
      state.event('webReady', {});
      state.event('chatOpen', {'chatId': 'old'});
      expect(state.suppress({'chat_id': 'old'}), true);
      state.resetDocument();
      expect(state.suppress({'chat_id': 'old'}), false);
      state.event('webReady', {});
      expect(state.suppress({'chat_id': 'old'}), false);
      state.event('chatOpen', {'chatId': 'new'});
      expect(state.suppress({'chat_id': 'new'}), true);
    },
  );
  test(
    'failed renderer termination retries with foreground-only 180/600 backoff',
    () {
      final w = ShellWatchdog()
        ..visibility(true, 0)
        ..alive();
      expect(w.check(60001), Recovery.reload);
      expect(w.check(70001), Recovery.rebuild);
      w.terminationFailed();
      expect(w.check(240000), Recovery.none);
      expect(w.check(240001), Recovery.rebuild);
      w.terminationFailed();
      w.visibility(false, 240001);
      expect(w.check(900000), Recovery.none);
      w.visibility(true, 900000);
      expect(w.check(1499999), Recovery.none);
      expect(w.check(1500000), Recovery.rebuild);
      w.loadStarted();
      w.alive();
      expect(w.retryTermination, false);
    },
  );
  test(
    'offline probes never repeatedly wake a page; recovery and foreground do',
    () {
      final wake = NetworkWake();
      expect(wake.shouldDeliver('none'), false);
      wake.delivered = 'none';
      for (var i = 0; i < 10; i++) {
        expect(wake.shouldDeliver('none', force: true, probeOnly: true), false);
      }
      expect(wake.shouldDeliver('none', force: true), false);
      expect(wake.shouldDeliver('wifi', force: true, probeOnly: true), true);
      wake.delivered = 'wifi';
      expect(wake.shouldDeliver('wifi'), false);
      expect(wake.shouldDeliver('wifi', force: true), true);
    },
  );
}
