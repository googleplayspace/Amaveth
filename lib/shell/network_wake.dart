/// Track callbacks that actually reached the page, not just link/probe state.
/// Spec 4 / 10.4: being offline is never signalled; it only arms the next recovery.
class NetworkWake {
  String? delivered;
  void resetDocument() => delivered = null;
  bool shouldDeliver(
    String network, {
    bool force = false,
    bool probeOnly = false,
  }) => network != 'none' && (network != delivered || (force && !probeOnly));
}
