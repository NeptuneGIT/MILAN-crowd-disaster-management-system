/// `340 m` below 1 km, else `1.2 km`.
String formatDistance(double meters) {
  final m = meters.round();
  return m < 1000 ? '$m m' : '${(meters / 1000).toStringAsFixed(1)} km';
}

/// Same as SQL `beacon_label`: KM-000123.
String beaconLabel(int beaconId) => 'KM-${beaconId.toString().padLeft(6, '0')}';

/// `0.8 s ago`, `48 s ago`, `3 min ago` (for the debug screen's live counters).
String agoShort(Duration d) {
  if (d.inMilliseconds < 10000) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s ago';
  return d.inSeconds < 60 ? '${d.inSeconds} s ago' : '${d.inMinutes} min ago';
}

/// `just now`, `3 min ago`, `2 h ago`.
String agoText(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  return d.inMinutes < 60 ? '${d.inMinutes} min ago' : '${d.inHours} h ago';
}

Uri directionsUri(double lat, double lon) =>
    Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lon&travelmode=walking');
