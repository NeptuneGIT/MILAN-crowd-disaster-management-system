import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/beacon_stats.dart';
import '../ble/scanner_service.dart';
import '../geo/format.dart';
import 'debug_common.dart';
import 'field_test_panel.dart';
import 'theme.dart';

const _label = TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: kMuted);
String _clock(DateTime t, {bool millis = false}) => t.toIso8601String().substring(11, millis ? 23 : 19);

/// Read-only scanner stats for range / hit-rate tests. No stop control, on purpose.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  late final Timer _tick; // keeps the "heard 0.8 s ago" counters moving between adverts

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ScannerService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner debug')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final now = DateTime.now();
          final beacons = s.stats.values.toList()
            ..sort((a, b) => a.id.compareTo(b.id)); // stable order: cards must not jump around as signals change
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _status(s, now),
              const SizedBox(height: 20),
              // Debug builds only: labelled recordings for the signal-strength field tests.
              if (kDebugMode) ...[const FieldTestPanel(), const SizedBox(height: 20)],
              Text('BEACONS HEARD · ${beacons.length}', style: kSection),
              const SizedBox(height: 12),
              if (beacons.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Nothing heard yet. Bring a band within a metre of the phone.',
                    style: TextStyle(color: kMuted),
                  ),
                ),
              for (final b in beacons) _BeaconCard(b, missing: s.missing.contains(b.id), now: now),
              const SizedBox(height: 8),
              _recent(context, s),
              const SizedBox(height: 20),
              _totals(s),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: s.clearReadings, child: const Text('Clear readings')),
            ],
          );
        },
      ),
    );
  }

  Widget _status(ScannerService s, DateTime now) {
    final fix = s.lastFix;
    final scanning = s.health == ScannerHealth.scanning;
    Widget tile(String label, String value, {bool good = false, bool mono = false}) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: good ? kO1 : kPaper,
          border: good ? null : Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: _label.copyWith(color: good ? kInk : kMuted)),
            const SizedBox(height: 2),
            Text(
              value,
              style: (mono ? kMono : const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)).copyWith(
                color: good ? kInk : null,
              ),
            ),
          ],
        ),
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            tile('SCANNER', s.health.label, good: scanning),
            const SizedBox(width: 8),
            tile('BLUETOOTH', s.adapter == BluetoothAdapterState.on ? 'On' : s.adapter.name),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            tile(
              'GPS FIX',
              fix == null ? '—' : '±${fix.accuracy.round()} m · ${now.difference(fix.timestamp).inSeconds} s old',
              mono: true,
            ),
            const SizedBox(width: 8),
            tile(
              'MISSING LIST',
              '${s.missing.length} · ${s.missingSyncedAt == null ? 'not synced' : 'synced ${agoShort(now.difference(s.missingSyncedAt!))}'}',
              mono: true,
            ),
          ],
        ),
      ],
    );
  }

  Widget _recent(BuildContext context, ScannerService s) {
    final rows = s.log.reversed.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('RECENT ADVERTS', style: kSection)),
            OutlinedButton(
              onPressed: s.log.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: s.logCsv()));
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('Copied ${s.log.length} rows as CSV')));
                    },
              child: const Text('Copy as CSV'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: cardDecoration(radius: 12),
          child: Column(
            children: [
              _row3('TIME', 'ID', 'dBm', header: true),
              for (final e in rows) _row3(_clock(e.at, millis: true), e.beaconId, '${e.rssi}'),
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('—')),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Last ${s.log.length} of ${ScannerService.logMax} kept in memory',
                    style: const TextStyle(fontSize: 12, color: kMuted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row3(String a, String b, String c, {bool header = false}) {
    final st = header
        ? kMono.copyWith(color: kMuted, fontSize: 13)
        : kMono.copyWith(fontWeight: FontWeight.normal, fontSize: 13);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: header
          ? null
          : const BoxDecoration(
              border: Border(top: BorderSide(color: kBorder)),
            ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(a, style: st),
          Text(b, style: st),
          Text(c, style: st),
        ],
      ),
    );
  }

  Widget _totals(ScannerService s) {
    final up = s.lastUploadAt == null ? '—' : 'band ${s.lastUploadBeacon} · ${_clock(s.lastUploadAt!)}';
    final id = s.reporterId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('SCANNER AND UPLOADS', style: kSection),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: cardDecoration(radius: 12),
          child: Column(
            children: [
              kvRow('Adverts seen / matching', '${s.advertsSeen} / ${s.advertsMatched}'),
              kvRow('Skipped (no fresh fix)', '${s.skippedNoFix}'),
              kvRow('Last upload', up),
              kvRow('Scan restarts', '${s.scanRestarts}'),
              kvRow(
                'Reporter ID',
                id.length < 9 ? (id.isEmpty ? '—' : id) : '${id.substring(0, 4)}…${id.substring(id.length - 4)}',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Last RPC error', style: TextStyle(fontSize: 14, color: kMuted)),
                    Text(s.lastError ?? '—', style: kMono.copyWith(fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BeaconCard extends StatelessWidget {
  const _BeaconCard(this.b, {required this.missing, required this.now});
  final BeaconStats b;
  final bool missing;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final lost = b.isLost(now);
    final bars = signalBars(b.rssi);
    final tint = lost ? kDanger : kO4;
    final span = b.perSecond;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kPaper,
        border: Border.all(color: lost ? kBorder : kO4, width: lost ? 1 : 2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                b.id,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              Text(
                'ID ${b.id}',
                style: kMono.copyWith(fontWeight: FontWeight.normal, color: kMuted, fontSize: 13),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: missing ? kDangerTint : kChipGrey,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  missing ? 'MISSING' : 'NOT MISSING',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: missing ? kDangerInk : kMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.circle, size: 8, color: tint),
              const SizedBox(width: 8),
              Text(
                lost ? 'Lost contact · last heard ${agoShort(b.since(now))}' : 'Live · heard ${agoShort(b.since(now))}',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: lost ? kDangerInk : kInk),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SIGNAL (LAST)', style: _label),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '${b.rssi} '),
                        const TextSpan(
                          text: 'dBm',
                          style: TextStyle(fontSize: 16, color: kMuted, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 34,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 1; i <= 4; i++)
                      Container(
                        width: 8,
                        height: 2.0 + i * 6,
                        margin: const EdgeInsets.only(right: 3),
                        decoration: BoxDecoration(
                          color: i <= bars ? tint : kBorder,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 11),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(signalLabel(b.rssi), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Last ${b.recent.length} readings', style: const TextStyle(fontSize: 12, color: kMuted)),
              Text(
                '${b.recent.reduce((a, c) => a < c ? a : c)} … ${b.recent.reduce((a, c) => a > c ? a : c)}',
                style: kMono.copyWith(fontSize: 12, fontWeight: FontWeight.normal, color: kMuted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 56,
              color: kGround,
              child: CustomPaint(size: Size.infinite, painter: _Spark(b.recent, tint)),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _stat('AVG', '${b.average}'),
              const SizedBox(width: 8),
              _stat('BEST', '${b.best}'),
              const SizedBox(width: 8),
              _stat('WORST', '${b.worst}'),
            ],
          ),
          const SizedBox(height: 10),
          kvRow('Last heard at', _clock(b.lastAt)),
          kvRow('First heard at', _clock(b.firstAt)),
          kvRow('Adverts', '${b.adverts}${span == null ? '' : ' · ${span.toStringAsFixed(1)} /s'}'),
          kvRow('Longest gap', '${(b.longestGap.inMilliseconds / 1000).toStringAsFixed(1)} s'),
          kvRow(b.addresses.length > 1 ? 'Device addresses (!)' : 'Device address', b.addresses.join('\n')),
          if (missing || b.uploads > 0)
            kvRow('Uploads', '${b.uploads}${b.lastUploadAt == null ? '' : ' · last ${_clock(b.lastUploadAt!)}'}'),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: kGround, borderRadius: BorderRadius.circular(8)),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: kMuted),
          ),
          Text(value, style: kMono.copyWith(fontSize: 15)),
        ],
      ),
    ),
  );
}

/// Signal strength over the last readings, scaled to their own range (at least 10 dB tall).
class _Spark extends CustomPainter {
  _Spark(this.data, this.color);
  final List<int> data;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final lo = data.reduce((a, c) => a < c ? a : c), hi = data.reduce((a, c) => a > c ? a : c);
    final range = (hi - lo) < 10 ? 10 : (hi - lo);
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final y = size.height - 6 - (size.height - 12) * (data[i] - lo) / range;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_Spark old) => true; // the list is mutated in place
}
