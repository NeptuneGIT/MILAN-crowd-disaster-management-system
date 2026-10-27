import 'dart:math';

/// No advert for this long and the debug screen calls the beacon "lost contact".
const kLostContact = Duration(seconds: 10);

/// One heard advert, kept (newest [ScannerService.logMax]) for the debug screen's CSV export.
class AdvertEvent {
  AdvertEvent(this.at, this.beaconId, this.rssi, this.address);
  final DateTime at;
  final int rssi;
  final String beaconId, address; // beaconId = the rotating ID heard (16 hex characters)
}

/// Everything heard from one rotating beacon ID since the app started (or since "Clear readings").
class BeaconStats {
  BeaconStats(this.id, DateTime at) : firstAt = at, lastAt = at;

  static const recentMax = 60;

  final String id;
  final DateTime firstAt;
  DateTime lastAt;
  int rssi = 0, best = 0, worst = 0, adverts = 0, uploads = 0;
  DateTime? lastUploadAt;
  Duration longestGap = Duration.zero;
  final List<int> recent = []; // last [recentMax] readings, oldest first
  final List<DateTime> recentTimes = []; // timestamps corresponding to [recent]
  final Set<String> addresses = {}; // more than one for a single ID = a second device claiming it
  int _sum = 0;

  void record(int rssi, DateTime at, String address) {
    if (adverts > 0) {
      final gap = at.difference(lastAt);
      if (gap > longestGap) longestGap = gap;
    }
    best = adverts == 0 ? rssi : max(best, rssi);
    worst = adverts == 0 ? rssi : min(worst, rssi);
    adverts++;
    lastAt = at;
    this.rssi = rssi;
    _sum += rssi;
    recent.add(rssi);
    recentTimes.add(at);
    if (recent.length > recentMax) {
      recent.removeAt(0);
      recentTimes.removeAt(0);
    }
    addresses.add(address);
  }

  int get average => (_sum / adverts).round();

  Duration since(DateTime now) => now.difference(lastAt);

  bool isLost(DateTime now) => since(now) > kLostContact;

  /// Adverts per second over the time heard; null until there is a second to measure over.
  double? get perSecond {
    final s = lastAt.difference(firstAt).inMilliseconds / 1000;
    return s < 1 ? null : (adverts - 1) / s;
  }

  /// Median RSSI, number of adverts and RSSI interquartile range over the last [window] before
  /// [now]: the features uploaded with a sighting. Falls back to the latest reading when none is
  /// that recent; all zeros before the first advert.
  ({double median, int n, double iqr}) windowStats(Duration window, DateTime now) {
    final readings = <int>[
      for (var i = 0; i < recent.length; i++)
        if (now.difference(recentTimes[i]) <= window) recent[i],
    ];
    if (readings.isEmpty && adverts > 0) readings.add(rssi);
    if (readings.isEmpty) return (median: 0.0, n: 0, iqr: 0.0);
    readings.sort();
    return (
      median: quantile(readings, 0.5),
      n: readings.length,
      iqr: quantile(readings, 0.75) - quantile(readings, 0.25),
    );
  }
}

/// Quantile with linear interpolation between ranks (numpy's default). [sorted] is ascending and
/// not empty.
double quantile(List<int> sorted, double q) {
  final pos = (sorted.length - 1) * q;
  final lo = pos.floor(), hi = pos.ceil();
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

/// 1 to 4 bars. Thresholds are rough: a phone hears a band in a pocket about 10 dB weaker.
int signalBars(int rssi) => rssi >= -60
    ? 4
    : rssi >= -70
    ? 3
    : rssi >= -80
    ? 2
    : 1;

String signalLabel(int rssi) => switch (signalBars(rssi)) {
  >= 3 => 'Strong',
  2 => 'OK',
  _ => 'Weak',
};

String advertsCsv(Iterable<AdvertEvent> events) {
  final b = StringBuffer('time,beacon_id,rssi_dbm,address\n');
  for (final e in events) {
    b.writeln('${e.at.toIso8601String()},${e.beaconId},${e.rssi},${e.address}');
  }
  return b.toString();
}
