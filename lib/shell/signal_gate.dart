/// Readiness and visibility gate; lifecycle callbacks do not depend on login.
class ShellSignalGate {
  bool ready = false, authenticated = false, visible = false;
  bool? _deliveredVisibility;
  void resetDocument() {
    ready = false;
    authenticated = false;
  }

  void login() {
    authenticated = true;
  }

  void logout() {
    authenticated = false;
  }

  bool get canProbe => ready && visible;
  List<String> takeVisibilitySignals() {
    if (_deliveredVisibility == visible) return [];
    _deliveredVisibility = visible;
    // An early lifecycle event is skipped, not replayed as a synthetic resume
    // when webReady arrives or a document reloads (§4).
    return visible ? ['onForeground'] : ['onBackground'];
  }

  bool allows(String method) {
    if (method == 'onForeground' ||
        method == 'onNetwork' ||
        method == 'onHeartbeat') {
      return visible;
    }
    if (method == 'onBackground') return !visible;
    return true; // The JS invocation itself checks the current callback object.
  }
}
