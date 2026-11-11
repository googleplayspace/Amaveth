// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'package:flutter_test/flutter_test.dart';
import 'package:yueh/shell/watchdog.dart';
import 'package:yueh/shell/shell_config.dart';

void main() {
  test('entry preserves HTTPS origin and adds no default channel', () {
    expect(ShellConfig.entry.scheme, 'https');
    expect(ShellConfig.channelCode, '');
    expect(ShellConfig.entry.toString(), ShellConfig.webAddress);
    expect(ShellConfig.trusted(ShellConfig.entry), true);
    expect(
      ShellConfig.trusted(
        Uri.parse('https://web217-test-2.ssg18app.com.evil.test'),
      ),
      false,
    );
    expect(
      ShellConfig.trusted(Uri.parse('http://web217-test-2.ssg18app.com')),
      false,
    );
  });
  // Spec 2.1 (rev 5): load the configured url as is. No stripping, renaming or
  // folding of channelcode, no added default; Web reads it in any case itself.
  test('the B url is loaded verbatim; channelCode is only read back', () {
    final saved = ShellConfig.webAddress;
    addTearDown(() => ShellConfig.webAddress = saved);

    for (final (url, code) in [
      ('https://h.test/?channelcode=ch001&a=1', 'ch001'),
      ('https://h.test/?CHANNELCODE=ch001&a=1', 'ch001'),
      ('https://h.test/?a=1&ChannelCode=ch001', 'ch001'),
      ('https://h.test/?channelcode=&ChannelCode=ch002', 'ch002'),
      ('https://h.test/path', ''),
      ('https://h.test/path?a=1', ''),
      ('https://h.test/path?channelCode=&a=1', ''),
    ]) {
      ShellConfig.webAddress = url;
      // The entry keeps every key, spelling, order and empty value untouched.
      expect(ShellConfig.entry.toString(), url, reason: url);
      expect(ShellConfig.entry.query, Uri.parse(url).query, reason: url);
      expect(ShellConfig.channelCode, code, reason: url);
    }
  });
  test(
    'watchdog never fires before first alive and excludes background time',
    () {
      final w = ShellWatchdog();
      w.visibility(true, 0);
      expect(w.check(600000), Recovery.none);
      w.alive();
      w.visibility(false, 600000);
      expect(w.check(1200000), Recovery.none);
      w.visibility(true, 1200000);
      expect(w.check(1259999), Recovery.none);
      expect(w.check(1260001), Recovery.reload);
    },
  );
  test('reload without load start rebuilds once after ten active seconds', () {
    final w = ShellWatchdog();
    w.visibility(true, 0);
    w.alive();
    expect(w.check(60001), Recovery.reload);
    expect(w.check(70000), Recovery.none);
    expect(w.check(70001), Recovery.rebuild);
    expect(w.check(80001), Recovery.none);
  });
  test(
    'load start cancels rebuild; recovery honors 180 and 600 second backoff',
    () {
      final w = ShellWatchdog();
      w.visibility(true, 0);
      w.alive();
      expect(w.check(60001), Recovery.reload);
      w.loadStarted();
      expect(w.check(70001), Recovery.none);
      w.alive();
      expect(w.check(150000), Recovery.none);
      expect(w.check(240001), Recovery.reload);
      w.loadStarted();
      w.alive();
      expect(w.check(800000), Recovery.none);
      expect(w.check(840001), Recovery.reload);
    },
  );
  test('a page that recovered gets the 180 s backoff again, not 600 s', () {
    final w = ShellWatchdog();
    w.visibility(true, 0);
    w.alive();
    // First hang: reload, the page comes back and keeps reporting alive.
    expect(w.check(60001), Recovery.reload);
    w.loadStarted();
    for (var t = 75000; t <= 1000000; t += 15000) {
      w.check(t);
      w.alive();
    }
    expect(w.failures, 0);
    // Second, unrelated hang: handled after 60 s, then the short backoff again.
    expect(w.check(1060001), Recovery.reload);
    expect(w.nextRecovery, 1060001 + 180000);
  });
  test('a page that stays hung keeps the 600 s backoff', () {
    final w = ShellWatchdog();
    w.visibility(true, 0);
    w.alive();
    expect(w.check(60001), Recovery.reload);
    w.loadStarted();
    expect(w.check(240001), Recovery.reload);
    expect(w.nextRecovery, 240001 + 600000);
    w.loadStarted();
    expect(w.check(840001), Recovery.reload);
    expect(w.nextRecovery, 840001 + 600000);
  });
  test('background pauses the ten second reload deadline too', () {
    final w = ShellWatchdog();
    w.visibility(true, 0);
    w.alive();
    w.check(60001);
    w.visibility(false, 65001);
    expect(w.check(900000), Recovery.none);
    w.visibility(true, 900000);
    expect(w.check(904999), Recovery.none);
    expect(w.check(905000), Recovery.rebuild);
  });

  // The refresh button and error retry used to destroy the WebView and reload the
  // entry URL ("cold start"), and rebuild() called loadStarted(), which cancelled the
  // ten second escalation. Both are covered here.
  test('a refresh arms the ten second deadline instead of cancelling it', () {
    final w = ShellWatchdog();
    w.visibility(true, 0);
    w.alive();
    // A refresh issued now, with no onPageStarted afterwards.
    w.awaitingReload(manual: true);
    expect(w.awaitingLoad, true);
    expect(w.recovering, true);
    expect(w.check(9999), Recovery.none);
    expect(w.check(10000), Recovery.rebuild);
    // One escalation only: a rebuild that also never loads must not loop.
    expect(w.check(20000), Recovery.none);
    expect(w.check(50000), Recovery.none);
  });

  test('a refresh that starts loading cancels the escalation', () {
    final w = ShellWatchdog();
    w.visibility(true, 0);
    w.alive();
    w.awaitingReload(manual: true);
    w.loadStarted();
    expect(w.awaitingLoad, false);
    expect(w.recovering, false);
    expect(w.escalations, 0);
    // Within the ten second window nothing fires; the page is simply loading.
    expect(w.check(9999), Recovery.none);
    // The page keeps reporting alive, so no hang is inferred either.
    w.alive();
    expect(w.check(30000), Recovery.none);
  });

  test(
    'a manual refresh keeps its own budget after an internal escalation',
    () {
      final w = ShellWatchdog();
      w.visibility(true, 0);
      w.alive();
      w.awaitingReload();
      expect(w.check(10000), Recovery.rebuild);
      expect(w.check(20000), Recovery.none);
      // The user hits refresh: a new cycle, so a new ten second deadline.
      w.awaitingReload(manual: true);
      expect(w.check(29999), Recovery.none);
      expect(w.check(30000), Recovery.rebuild);
    },
  );

  test('a first run without any alive is never escalated', () {
    final w = ShellWatchdog();
    w.visibility(true, 0);
    w.awaitingReload(manual: true);
    expect(w.awaitingLoad, false);
    expect(w.check(120000), Recovery.none);
  });
}
