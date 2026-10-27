import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'advert_parser.dart';
import 'beacon_stats.dart';
import 'throttle.dart';

enum ScannerHealth {
  starting('Starting…'),
  scanning('Scanning'),
  bluetoothOff('Bluetooth off'),
  noLocation('Locating…'); // no GPS stream yet (PermissionGate already blocks when location is off)

  const ScannerHealth(this.label);
  final String label;
}

/// Always-on BLE scanner (README §4.4). Runs in the main isolate; the foreground
/// service only keeps the process alive. There is deliberately NO stop():
/// the user cannot turn scanning off, and logout does not touch it.
/// Per-install random id, used only to de-duplicate reports server-side.
String _randomId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class ScannerService extends ChangeNotifier {
  ScannerService._();
  static final instance = ScannerService._();

  static const _syncEvery = Duration(seconds: 20);
  static const _maxFixAge = Duration(seconds: 20);

  // ── debug stats (read by the status chip and the debug screen) ──
  Set<String> missing = {}; // rotating IDs (EIDs) that currently mean a missing dependent
  final Map<String, BeaconStats> stats = {}; // every valid rotating ID heard, missing or not
  final List<AdvertEvent> log = []; // newest last, capped at [logMax]
  static const logMax = 2000; // about 4 min of one band's adverts
  /// Debug builds only: the field-test panel listens here to record a run. Null otherwise.
  void Function(AdvertEvent event)? advertSink;
  int scanRestarts = 0;
  DateTime? missingSyncedAt;
  int advertsSeen = 0, advertsMatched = 0, skippedNoFix = 0;
  String? lastUploadBeacon;
  DateTime? lastUploadAt;
  Position? lastFix;
  String? lastError;
  BluetoothAdapterState adapter = BluetoothAdapterState.unknown;

  bool _started = false;
  String _reporter = '';
  String get reporterId => _reporter;
  final _throttle = UploadThrottle();
  StreamSubscription<Position>? _posSub;
  int _restartAttempt = 0;
  Timer? _restartTimer;

  bool get locationOk => _posSub != null;

  ScannerHealth get health {
    if (adapter != BluetoothAdapterState.on) {
      return adapter == BluetoothAdapterState.unknown ? ScannerHealth.starting : ScannerHealth.bluetoothOff;
    }
    if (!locationOk) return ScannerHealth.noLocation;
    return FlutterBluePlus.isScanningNow ? ScannerHealth.scanning : ScannerHealth.starting;
  }

  /// Bluetooth -> fine location -> notifications (README §4.2). Denials are fine:
  /// the scanner still runs, it just can't upload without location.
  static Future<void> requestPermissions() async {
    await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    await Permission.locationWhenInUse.request();
    await Permission.notification.request();
  }

  /// Idempotent. Call after login + permissions, and on every app launch with a saved email.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final prefs = await SharedPreferences.getInstance();
    _reporter = prefs.getString('reporter_id') ?? _randomId();
    await prefs.setString('reporter_id', _reporter);

    await _startForeground();

    FlutterBluePlus.onScanResults.listen(_onResults, onError: (Object e) => _fail('scan: $e'));
    FlutterBluePlus.isScanning.listen((on) {
      if (!on) _scheduleRestart();
      notifyListeners();
    });
    FlutterBluePlus.adapterState.listen((s) {
      adapter = s;
      if (s == BluetoothAdapterState.on) _scheduleRestart(immediate: true);
      notifyListeners();
    });

    Timer.periodic(_syncEvery, (_) => _tick());
    AppLifecycleListener(onResume: _tick);
    _tick();
  }

  // Missing-list sync, plus retry anything that isn't running yet (permission granted later, etc.).
  void _tick() {
    syncMissing();
    if (_posSub == null) _startLocation();
    if (!FlutterBluePlus.isScanningNow) _scheduleRestart(immediate: true);
  }

  Future<void> syncMissing() async {
    try {
      final res = await Supabase.instance.client.rpc('get_missing_eids');
      missing = (res as List).cast<String>().toSet();
      missingSyncedAt = DateTime.now();
      notifyListeners();
    } catch (e) {
      _fail('sync: $e'); // keep last known set
    }
  }

  Future<void> _startForeground() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'scanner',
        channelName: 'MILAN',
        channelDescription: 'Shown while MILAN is in use',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing()),
    );
    if (await FlutterForegroundTask.isRunningService) return;
    // Android 14 refuses an FGS type whose permission isn't granted, so only claim what we have.
    final types = <ForegroundServiceTypes>[
      if (await Permission.bluetoothScan.isGranted) ForegroundServiceTypes.connectedDevice,
      if (await Permission.locationWhenInUse.isGranted) ForegroundServiceTypes.location,
    ];
    final r = await FlutterForegroundTask.startService(
      serviceTypes: types.isEmpty ? null : types,
      notificationTitle: 'MILAN in use',
      notificationText: '',
      notificationIcon: const NotificationIcon(
        metaDataName: 'in.hackforsocial.lostfound.NOTIFICATION_ICON',
        backgroundColor: Color(0xFFEC9533),
      ),
    );
    if (r is ServiceRequestFailure) _fail('foreground: ${r.error}');
  }

  void _scheduleRestart({bool immediate = false}) {
    if (FlutterBluePlus.isScanningNow || _restartTimer?.isActive == true) return;
    if (adapter != BluetoothAdapterState.on) return; // adapterState listener restarts us
    // Android throttles scan starts (~5 per 30 s), so back off: 2, 4, 8, 16, 30 s.
    final delay = immediate ? Duration.zero : Duration(seconds: min(30, 2 << _restartAttempt++));
    _restartTimer = Timer(delay, _startScan);
  }

  Future<void> _startScan() async {
    scanRestarts++;
    try {
      await FlutterBluePlus.startScan(
        withMsd: [
          MsdFilter(kCompanyId, data: kMagic, mask: [0xFF, 0xFF]),
        ], // hardware-filtered
        androidScanMode: AndroidScanMode.lowLatency,
        continuousUpdates: true, // deliver repeated adverts from the same device
        oneByOne: true,
        androidCheckLocationServices: false, // keep scanning with location off (no uploads then)
      );
    } catch (e) {
      _fail('startScan: $e');
      _scheduleRestart();
    }
  }

  void _startLocation() {
    _posSub =
        Geolocator.getPositionStream(
          locationSettings: AndroidSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
        ).listen(
          (p) {
            lastFix = p;
            notifyListeners();
          },
          onError: (Object e) {
            _posSub?.cancel();
            _posSub = null; // retried on next tick
            _fail('location: $e');
          },
        );
  }

  void _onResults(List<ScanResult> results) {
    for (final r in results) {
      advertsSeen++;
      _restartAttempt = 0;
      final msd = r.advertisementData.manufacturerData[kCompanyId];
      final id = msd == null ? null : parseEid(msd);
      if (id == null) continue;
      advertsMatched++;
      _record(id, r);
      if (!missing.contains(id)) continue; // nothing leaves the phone

      final fix = lastFix;
      if (fix == null || DateTime.now().difference(fix.timestamp) > _maxFixAge) {
        skippedNoFix++;
        continue;
      }
      if (_throttle.tryAcquire(id)) _upload(id, fix);
    }
    notifyListeners();
  }

  void _record(String id, ScanResult r) {
    final now = DateTime.now();
    final address = r.device.remoteId.str;
    stats.putIfAbsent(id, () => BeaconStats(id, now)).record(r.rssi, now, address);
    final event = AdvertEvent(now, id, r.rssi, address);
    log.add(event);
    if (log.length > logMax) log.removeAt(0);
    advertSink?.call(event);
  }

  String logCsv() => advertsCsv(log);

  /// Debug screen's "Clear readings": reset the per-beacon stats and counters between tests.
  void clearReadings() {
    stats.clear();
    log.clear();
    advertsSeen = advertsMatched = skippedNoFix = scanRestarts = 0;
    notifyListeners();
  }

  Future<void> _upload(String eid, Position fix) async {
    final now = DateTime.now();
    final w = stats[eid]?.windowStats(const Duration(seconds: 10), now);

    try {
      await Supabase.instance.client.rpc(
        'report_sighting',
        params: {
          'p_eid': eid,
          'p_lat': fix.latitude,
          'p_lon': fix.longitude,
          'p_accuracy_m': fix.accuracy,
          'p_reporter': _reporter,
          if (w != null) ...{'p_rssi': w.median, 'p_n_heard': w.n, 'p_iqr': w.iqr},
        },
      );
      lastUploadBeacon = eid;
      lastUploadAt = now;
      stats[eid]
        ?..uploads += 1
        ..lastUploadAt = lastUploadAt;
      notifyListeners();
    } catch (e) {
      _fail('upload: $e'); // dropped, no offline queue (demo)
    }
  }

  void _fail(String msg) {
    lastError = '${DateTime.now().toIso8601String().substring(11, 19)} $msg';
    debugPrint('[scanner] $msg');
    notifyListeners();
  }
}
