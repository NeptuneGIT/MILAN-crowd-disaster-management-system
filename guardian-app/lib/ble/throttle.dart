/// At most one upload per band per [window] on this phone.
class UploadThrottle {
  UploadThrottle({this.window = const Duration(seconds: 10), DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;
  final _last = <String, DateTime>{};

  bool tryAcquire(String eid) {
    final now = _now();
    final last = _last[eid];
    if (last != null && now.difference(last) < window) return false;
    _last[eid] = now;
    return true;
  }
}
