import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class Dependent {
  Dependent(Map<String, dynamic> r)
    : id = r['child_id'] as String,
      name = r['child_name'] as String,
      beaconId = r['beacon_id'] as int,
      label = r['beacon_label'] as String,
      isMissing = r['is_missing'] as bool,
      found = r['found_camp_name'] == null
          ? null
          : FoundAt(
              Camp({'name': r['found_camp_name'], 'lat': r['found_camp_lat'], 'lon': r['found_camp_lon']}),
              DateTime.parse(r['found_at'] as String),
            ); // server sends found_* until it is acknowledged
  final String id, name, label;
  final int beaconId;
  final bool isMissing;
  final FoundAt? found;
}

/// Where staff said a dependent was found, and when.
class FoundAt {
  FoundAt(this.camp, this.at);
  final Camp camp;
  final DateTime at;
}

class Camp {
  Camp(Map<String, dynamic> r)
    : name = r['name'] as String,
      lat = (r['lat'] as num).toDouble(),
      lon = (r['lon'] as num).toDouble();
  final String name;
  final double lat, lon;
}

SupabaseClient get _db => Supabase.instance.client;

/// The signed-in parent's dependents. The server derives "who" from the login token
/// (supabase/auth.sql get_my_children), so there is no email argument to spoof.
Future<List<Dependent>> fetchDependents() async {
  final rows = await _db.rpc('get_my_children') as List;
  return rows.map((r) => Dependent(r as Map<String, dynamic>)).toList();
}

/// Guardian confirms they are with the dependent. Clears the Found notice here and on the camp board.
/// False when there was nothing to clear (already cleared) or it isn't this guardian's dependent.
Future<bool> acknowledgeFound(String dependentId) async {
  final ok = await _db.rpc('acknowledge_found', params: {'p_child_id': dependentId});
  return ok == true;
}

/// Email of the signed-in parent, or null when signed out. supabase_flutter stores and
/// refreshes the session itself, so nothing is saved here.
class EmailNotifier extends Notifier<String?> {
  @override
  String? build() => _db.auth.currentUser?.email;

  /// Call after a successful sign-in to move the app to Home.
  void sync() => state = _db.auth.currentUser?.email;

  /// Ends the session only. The scanner keeps running (README §4.4): it uses the anon
  /// role, which can still call get_missing_eids and report_sighting.
  Future<void> logout() async {
    await _db.auth.signOut();
    state = null;
  }
}

final emailProvider = NotifierProvider<EmailNotifier, String?>(EmailNotifier.new);

final dependentsProvider = FutureProvider<List<Dependent>>((ref) {
  ref.watch(emailProvider); // refetch when the signed-in user changes
  return fetchDependents();
});

final campsProvider = FutureProvider<List<Camp>>((ref) async {
  final rows = await _db.from('camps').select('name, lat, lon');
  return rows.map(Camp.new).toList();
});
