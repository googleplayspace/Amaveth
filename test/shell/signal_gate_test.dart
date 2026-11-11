// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'package:flutter_test/flutter_test.dart';
import 'package:yueh/shell/signal_gate.dart';

void main() {
  test('ready foreground is delivered before login', () {
    final g = ShellSignalGate()
      ..visible = true
      ..ready = true;
    expect(g.authenticated, false);
    expect(g.takeVisibilitySignals(), ['onForeground']);
    expect(g.canProbe, true);
    expect(g.allows('onHeartbeat'), true);
    expect(g.allows('onNetwork'), true);
    expect(g.takeVisibilitySignals(), isEmpty);
  });
  test('early lifecycle is consumed once; JS guards object availability', () {
    final g = ShellSignalGate()..visible = true;
    expect(g.takeVisibilitySignals(), ['onForeground']);
    expect(g.canProbe, false);
    expect(g.allows('onHeartbeat'), true);
    g.ready = true;
    expect(g.takeVisibilitySignals(), isEmpty);
  });
  test('background and foreground signals survive logout', () {
    final g = ShellSignalGate()
      ..ready = true
      ..visible = true;
    g.login();
    g.takeVisibilitySignals();
    g.logout();
    g.visible = false;
    expect(g.takeVisibilitySignals(), ['onBackground']);
    expect(g.allows('onHeartbeat'), false);
    g.visible = true;
    expect(g.takeVisibilitySignals(), ['onForeground']);
    expect(g.allows('onHeartbeat'), true);
  });
  test('new document resets readiness and previous identity', () {
    final g = ShellSignalGate()
      ..ready = true
      ..visible = true;
    g.login();
    g.takeVisibilitySignals();
    g.resetDocument();
    expect(g.authenticated, false);
    expect(g.canProbe, false);
    g.ready = true;
    expect(g.takeVisibilitySignals(), isEmpty);
    expect(g.allows('onHeartbeat'), true);
  });
}
