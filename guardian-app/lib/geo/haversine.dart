import 'dart:math';

/// Same formula and Earth radius as SQL `haversine_m` (supabase/schema.sql).
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * pi / 180;
  final a = pow(sin(rad(lat2 - lat1) / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(rad(lon2 - lon1) / 2), 2);
  return 2 * 6371000 * asin(min(1.0, sqrt(a)));
}
