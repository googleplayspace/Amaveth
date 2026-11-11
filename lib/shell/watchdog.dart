enum Recovery { none, reload, rebuild }

/// Monotonic milliseconds, counted only while the IM surface is visible.
class ShellWatchdog {
  bool active = false, armed = false, recovering = false, seenAlive = false;
  int lastAlive = 0,
      activeTime = 0,
      lastTick = 0,
      reloadAt = 0,
      nextRecovery = 0,
      failures = 0;
  bool awaitingLoad = false, retryTermination = false;

  /// Load attempts in the current recovery cycle that never reported
  /// onPageStarted. A cycle gets one reload and at most one escalation to a
  /// rebuild; afterwards the ten second deadline stops firing and the 60 s alive
  /// timeout (with its 180/600 s backoff) takes over, so a page that cannot load
  /// at all does not rebuild every ten seconds.
  int escalations = 0;

  void terminationFailed() {
    retryTermination = true;
    recovering = false;
    awaitingLoad = false;
    // Manual recovery can occur before the first watchdog timeout.
    if (nextRecovery <= activeTime) {
      nextRecovery = activeTime + (failures++ == 0 ? 180000 : 600000);
    }
  }

  void visibility(bool value, int now) {
    tick(now);
    active = value;
    lastTick = now;
  }

  void tick(int now) {
    if (active) activeTime += (now - lastTick).clamp(0, 1 << 40);
    lastTick = now;
  }

  void alive() {
    seenAlive = true;
    armed = true;
    lastAlive = activeTime;
    recovering = false;
    awaitingLoad = false;
    escalations = 0;
  }

  /// The page really started loading. Clears the ten second deadline and the
  /// escalation counter; this is the only evidence that a refresh worked.
  void loadStarted() {
    retryTermination = false;
    armed = seenAlive;
    lastAlive = activeTime;
    recovering = false;
    awaitingLoad = false;
    escalations = 0;
  }

  /// A refresh was issued and the page has not reported onPageStarted yet.
  /// Unlike [loadStarted] this ARMS the ten second escalation instead of
  /// cancelling it, so a page that never even begins loading is escalated
  /// promptly rather than waiting out the 60 s alive timeout.
  ///
  /// [manual] marks a user-initiated refresh (button, retry), which starts a new
  /// recovery cycle and therefore gets a fresh escalation budget. Internal
  /// rebuilds keep counting so a page that cannot load stops escalating.
  ///
  /// Only armed once the page has been alive at least once: on a first run there
  /// is no evidence a refresh should have loaded, and arming would turn a slow
  /// cold start into a rebuild loop.
  void awaitingReload({bool manual = false}) {
    retryTermination = false;
    armed = seenAlive;
    lastAlive = activeTime;
    if (manual) escalations = 0;
    if (!seenAlive) {
      recovering = false;
      awaitingLoad = false;
      return;
    }
    recovering = true;
    awaitingLoad = true;
    reloadAt = activeTime;
  }

  Recovery check(int now) {
    tick(now);
    if (!active) return Recovery.none;
    if (retryTermination && activeTime >= nextRecovery) {
      retryTermination = false;
      recovering = true;
      nextRecovery = activeTime + 600000;
      return Recovery.rebuild;
    }
    if (awaitingLoad && activeTime - reloadAt >= 10000) {
      awaitingLoad = false;
      // One rebuild per failed load attempt. A second silent failure means a
      // reload cannot help; release the gate so the alive timeout and its
      // 180/600 s backoff decide what happens next.
      if (++escalations > 1) {
        recovering = false;
        return Recovery.none;
      }
      return Recovery.rebuild;
    }
    // Spec 11.2 (5): the 180/600 s backoff is for consecutive failures. A page that
    // stayed alive through the whole window recovered, so the next hang is a new one
    // and starts again at 180 s. Never resetting held every later hang for 600 s.
    if (failures > 0 &&
        armed &&
        !recovering &&
        activeTime >= nextRecovery &&
        activeTime - lastAlive <= 60000) {
      failures = 0;
    }
    if (!armed ||
        recovering ||
        activeTime < nextRecovery ||
        activeTime - lastAlive <= 60000) {
      return Recovery.none;
    }
    recovering = true;
    awaitingLoad = true;
    reloadAt = activeTime;
    nextRecovery = activeTime + (failures++ == 0 ? 180000 : 600000);
    return Recovery.reload;
  }
}
