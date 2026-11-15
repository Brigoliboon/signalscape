/// Android lets an app start about 4 Wi-Fi scans every 2 minutes in the
/// foreground. This tracks scans we started so the app never asks for more,
/// and says when the next one is allowed.
class ScanThrottle {
  ScanThrottle({
    this.maxScans = 4,
    this.window = const Duration(minutes: 2),
    this.refusalCooldown = const Duration(seconds: 30),
  });

  final int maxScans;
  final Duration window;

  /// How long to wait after the system refuses a scan we thought was allowed.
  final Duration refusalCooldown;

  final List<DateTime> _starts = [];
  DateTime? _blockedUntil;

  void _prune(DateTime now) {
    _starts.removeWhere((t) => now.difference(t) >= window);
  }

  /// Scans started within the last window.
  int usedIn(DateTime now) {
    _prune(now);
    return _starts.length;
  }

  /// Time until a scan may start, or [Duration.zero] if one may start now.
  Duration waitFor(DateTime now) {
    _prune(now);
    var wait = Duration.zero;
    if (_starts.length >= maxScans) {
      wait = _starts.first.add(window).difference(now);
    }
    final blocked = _blockedUntil;
    if (blocked != null) {
      final left = blocked.difference(now);
      if (left > wait) wait = left;
    }
    return wait.isNegative ? Duration.zero : wait;
  }

  bool canScan(DateTime now) => waitFor(now) == Duration.zero;

  /// Call when a scan was started.
  void recordStart(DateTime now) {
    _prune(now);
    _starts.add(now);
  }

  /// Call when the system said no. Backs off for [refusalCooldown].
  void recordRefusal(DateTime now) {
    _blockedUntil = now.add(refusalCooldown);
  }
}
