// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yueh/shell/chat_state.dart';
import 'package:yueh/shell/diagnostic_text.dart';
import 'package:yueh/shell/network_probe.dart';

void main() {
  test(
    'suppress only the visible current conversation; close and logout reset it',
    () {
      final state = ShellChatState()..visible = true;
      state.event('webReady', {});
      state.event('chatOpen', {'chatId': 'alice'});
      expect(state.suppress({'chat_id': 'alice'}), true);
      expect(state.suppress({'chat_id': 'bob'}), false);
      expect(state.suppress(null), false);
      state.visible = false;
      expect(state.suppress({'chat_id': 'alice'}), false);
      state.visible = true;
      state.event('chatClose', {'chatId': 'bob'});
      expect(state.suppress({'chat_id': 'alice'}), true);
      state.event('chatClose', {'chatId': 'alice'});
      expect(state.suppress({'chat_id': 'alice'}), false);
      state.event('chatOpen', {'chat_id': 'bob'});
      state.event('logout', {});
      expect(state.suppress({'chat_id': 'bob'}), false);
    },
  );

  test(
    'diagnostics preserve error meaning and channel but redact credentials',
    () {
      final text = diagnosticText(
        'ChunkLoadError timeout token=abc password="xyz with spaces"',
      );
      expect(text, contains('ChunkLoadError timeout'));
      expect(text, isNot(contains('abc')));
      expect(text, isNot(contains('xyz')));
      expect(text, isNot(contains('with spaces')));
      final url = diagnosticUrl(
        Uri.parse(
          'https://example.test/?channelCode=google&access_token=private',
        ),
      );
      expect(url, contains('channelCode=google'));
      expect(url, isNot(contains('private')));
    },
  );

  test(
    'network link is not treated as reachable until a request succeeds',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final requests = <String>[];
      server.listen((request) {
        requests.add(request.method);
        request.response.statusCode = 405;
        request.response.close();
      });
      expect(
        await shellNetworkReachable(Uri.parse('http://127.0.0.1:$port/')),
        true,
      );
      expect(requests, ['HEAD']);
      await server.close(force: true);
      expect(
        await shellNetworkReachable(Uri.parse('http://127.0.0.1:$port/')),
        false,
      );
    },
  );
}
