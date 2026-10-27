import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vibration/vibration.dart';

import '../ble/beacon_stats.dart';
import '../ble/field_test.dart';
import '../ble/scanner_service.dart';
import 'debug_common.dart';
import 'theme.dart';

enum _Phase { pick, ready, settle, record, review }

const _reasons = ['someone crossed the line', 'phone moved', 'Bluetooth or location dropped', 'other'];

/// Records labelled runs for the signal-strength tests (docs/field-test-guide.md in the repo root).
/// Debug builds only: the debug screen doesn't show it in release. Logic is in lib/ble/field_test.dart.
class FieldTestPanel extends StatefulWidget {
  const FieldTestPanel({super.key});

  @override
  State<FieldTestPanel> createState() => _FieldTestPanelState();
}

class _FieldTestPanelState extends State<FieldTestPanel> {
  final _s = ScannerService.instance;
  final _notes = TextEditingController();

  final _sheets = <String, List<RunSpec>>{};
  String _sheet = 'open';
  int _session = 1;
  String? _beaconId;
  RunSpec? _run;
  _Phase _phase = _Phase.pick;

  Directory? _root;
  FieldTestStore? _store;
  List<List<String>> _rows = [];
  String _phoneModel = '';
  String? _error;
  bool _saving = false;

  Timer? _tick;
  late DateTime _settleEnd, _recordStart, _recordEnd;
  final _captured = <AdvertEvent>[];
  final _others = <String>{};

  // review
  RunSummary? _summary;
  bool _valid = true;
  final _picked = <String>{};

  List<RunSpec> get _specs => _sheets[_sheet] ?? const [];
  List<int> get _sessions => ({for (final r in _specs) r.session}.toList()..sort());
  List<RunSpec> get _sessionRuns => _specs.where((r) => r.session == _session).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _s.advertSink = null;
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _sheets['open'] = parseSheet(await rootBundle.loadString(kOpenFieldSheet));
      _sheets['body'] = parseSheet(await rootBundle.loadString(kBodyStackingSheet));
      _root = Directory(
        '${(await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory()).path}/rssi',
      );
      try {
        final a = await DeviceInfoPlugin().androidInfo;
        _phoneModel = '${a.manufacturer} ${a.model}';
      } catch (_) {}
      _openSheet('open');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _openSheet(String key) {
    _sheet = key;
    _session = _sessions.first;
    _store = FieldTestStore(Directory('${_root!.path}/$key'), _specs.first.columns);
    _rows = _store!.readRows();
    _run = null;
    _phase = _Phase.pick;
    if (mounted) setState(() {});
  }

  BeaconStats? get _beacon => _beaconId == null ? null : _s.stats[_beaconId];

  String? _defaultBeacon() {
    if (_s.stats.isEmpty) return null;
    return (_s.stats.values.toList()..sort((a, b) => b.lastAt.compareTo(a.lastAt))).first.id;
  }

  // ── run flow ──

  void _start() {
    setState(() {
      _phase = _Phase.settle;
      _settleEnd = DateTime.now().add(const Duration(seconds: kSettleSeconds));
    });
    _buzz(150);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) => _onTick());
  }

  void _onTick() {
    final now = DateTime.now();
    if (_phase == _Phase.settle && !now.isBefore(_settleEnd)) {
      _recordStart = now;
      _recordEnd = now.add(Duration(seconds: _run!.durationS));
      _captured.clear();
      _others.clear();
      final id = _beaconId;
      _s.advertSink = (e) {
        if (e.at.isBefore(_recordStart) || !e.at.isBefore(_recordEnd)) return;
        e.beaconId == id ? _captured.add(e) : _others.add(e.beaconId);
      };
      _phase = _Phase.record;
      _buzz(700);
    } else if (_phase == _Phase.record && !now.isBefore(_recordEnd)) {
      _tick?.cancel();
      _s.advertSink = null;
      _summary = summarize(_captured, Duration(seconds: _run!.durationS));
      _valid = true;
      _picked.clear();
      _notes.clear();
      _phase = _Phase.review;
      _buzz(0, pattern: [0, 200, 150, 200, 150, 200]);
    }
    if (mounted) setState(() {});
  }

  void _cancel() {
    _tick?.cancel();
    _s.advertSink = null;
    setState(() => _phase = _Phase.ready);
  }

  Future<void> _buzz(int ms, {List<int> pattern = const []}) async {
    try {
      await (pattern.isEmpty ? Vibration.vibrate(duration: ms) : Vibration.vibrate(pattern: pattern));
    } catch (_) {}
  }

  Future<void> _save() async {
    final spec = _run!, store = _store!;
    setState(() => _saving = true);
    try {
      final note = [..._reasons.where(_picked.contains), if (_notes.text.trim().isNotEmpty) _notes.text.trim()];
      final rec = RunRecord(
        spec: spec,
        attempt: store.attemptsOf(spec.run, _rows) + 1,
        startTime: _recordStart,
        stopTime: _recordEnd,
        valid: _valid,
        notes: note.join('; '),
        beaconId: _beaconId!,
        summary: _summary!,
        phoneModel: _phoneModel,
      );
      await store.save(rec, _captured);
      _rows = store.readRows();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved ${rec.fileName} · ${_summary!.count} adverts')));
        setState(() {
          _phase = _Phase.pick;
          _run = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _export() async {
    final files = [
      for (final k in ['open', 'body']) ...FieldTestStore.filesIn(Directory('${_root!.path}/$k')),
    ];
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing saved yet')));
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [for (final f in files) XFile(f.path, mimeType: 'text/csv')],
        subject: 'RSSI field test',
      ),
    );
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('FIELD TEST', style: kSection),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: cardDecoration(radius: 12),
          child: _error != null
              ? Text(_error!, style: const TextStyle(color: kDangerInk))
              : _store == null
              ? const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
              : switch (_phase) {
                  _Phase.pick => _pick(),
                  _Phase.ready => _ready(),
                  _Phase.settle || _Phase.record => _running(),
                  _Phase.review => _review(),
                },
        ),
      ],
    );
  }

  Widget _bandRow() {
    _beaconId ??= _defaultBeacon();
    final ids = _s.stats.keys.toList()..sort();
    final b = _beacon;
    final heard = b == null ? null : DateTime.now().difference(b.lastAt);
    final live = heard != null && heard < const Duration(seconds: 3);
    return Row(
      children: [
        const Text('Band', style: TextStyle(color: kMuted)),
        const SizedBox(width: 10),
        if (ids.isEmpty)
          const Text('none heard yet', style: TextStyle(color: kDangerInk))
        else
          DropdownButton<String>(
            value: ids.contains(_beaconId) ? _beaconId : null,
            items: [
              for (final id in ids)
                DropdownMenuItem(
                  value: id,
                  child: Text(id, style: kMono),
                ),
            ],
            onChanged: _phase == _Phase.pick || _phase == _Phase.ready ? (v) => setState(() => _beaconId = v) : null,
          ),
        const Spacer(),
        Flexible(
          child: Text(
            b == null
                ? ''
                : live
                ? 'Live · ${b.rssi} dBm'
                : 'Not heard for ${heard!.inSeconds} s',
            textAlign: TextAlign.right,
            style: TextStyle(fontWeight: FontWeight.bold, color: live ? kInk : kDangerInk),
          ),
        ),
      ],
    );
  }

  Widget _chip(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: fg),
    ),
  );

  Widget _stateChip(RunState st) => switch (st) {
    RunState.done => _chip('Done', kO1, kInk),
    RunState.invalid => _chip('Invalid', kDangerTint, kDangerInk),
    RunState.notDone => _chip('Not done', kChipGrey, kMuted),
  };

  Widget _pick() {
    final runs = _sessionRuns;
    final next = runs.where((r) => _store!.stateOf(r.run, _rows) == RunState.notDone).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'open', label: Text('Open field')),
            ButtonSegment(value: 'body', label: Text('Body stacking')),
          ],
          selected: {_sheet},
          onSelectionChanged: (v) => _openSheet(v.first),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            for (final n in _sessions)
              ChoiceChip(
                label: Text('Session $n'),
                selected: n == _session,
                onSelected: (_) => setState(() => _session = n),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _bandRow(),
        const Divider(height: 20),
        for (final r in runs)
          InkWell(
            onTap: () => setState(() {
              _run = r;
              _phase = _Phase.ready;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              color: r == next ? kO1.withValues(alpha: 0.5) : null,
              child: Row(
                children: [
                  SizedBox(width: 48, child: Text(r.run, style: kMono)),
                  Expanded(child: Text(r.summary)),
                  if (r.role.isNotEmpty) ...[_chip(r.role, kChipGrey, kMuted), const SizedBox(width: 8)],
                  _stateChip(_store!.stateOf(r.run, _rows)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            OutlinedButton(onPressed: _export, child: const Text('Export all')),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_root?.path ?? '', style: const TextStyle(fontSize: 11, color: kMuted)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _ready() {
    final r = _run!;
    final tried = _store!.attemptsOf(r.run, _rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton(onPressed: () => setState(() => _phase = _Phase.pick), child: const Text('← Runs')),
        Row(
          children: [
            Text(r.run, style: kMono.copyWith(fontSize: 28)),
            const SizedBox(width: 12),
            Text(r.summary, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (r.role.isNotEmpty) ...[const SizedBox(width: 8), _chip(r.role, kChipGrey, kMuted)],
          ],
        ),
        const SizedBox(height: 10),
        Text(r.setup, style: const TextStyle(fontSize: 15, height: 1.4)),
        if (tried > 0) ...[
          const SizedBox(height: 8),
          Text(
            'Already saved $tried time${tried == 1 ? '' : 's'}. Recording again keeps the old attempt and saves ${attemptName(r.run, tried + 1)}.csv.',
            style: const TextStyle(color: kDangerInk, fontSize: 13),
          ),
        ],
        const SizedBox(height: 10),
        _bandRow(),
        const SizedBox(height: 10),
        Text(
          'Start gives a $kSettleSeconds s lead-in, then buzzes once and records for ${r.durationS} s. Three buzzes mean it is done. '
          'For a pocket run, put the phone away during the lead-in; the screen can turn off.',
          style: const TextStyle(fontSize: 12, color: kMuted),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _beaconId == null ? null : _start,
            style: FilledButton.styleFrom(backgroundColor: kO4, minimumSize: const Size.fromHeight(52)),
            child: const Text('Start', style: TextStyle(fontSize: 17)),
          ),
        ),
      ],
    );
  }

  Widget _running() {
    final now = DateTime.now();
    final settle = _phase == _Phase.settle;
    final left = (settle ? _settleEnd : _recordEnd).difference(now).inMilliseconds;
    final secs = (left / 1000).ceil().clamp(0, 9999);
    return Column(
      children: [
        Text(
          settle ? 'Get ready · ${_run!.run}' : 'Recording ${_run!.run}',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: settle ? kMuted : kInk),
        ),
        Text('$secs', style: kMono.copyWith(fontSize: 64)),
        Text(settle ? 'seconds until recording starts' : 'seconds left', style: const TextStyle(color: kMuted)),
        if (!settle) ...[
          const SizedBox(height: 8),
          Text('${_captured.length} adverts · ${_beacon?.rssi ?? '—'} dBm', style: kMono),
        ],
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _cancel, child: const Text('Cancel (nothing is saved)')),
      ],
    );
  }

  Widget _review() {
    final sum = _summary!;
    final r = _run!;
    String d(double? v) => v == null ? '—' : v.toStringAsFixed(1);
    final low = r.distanceM < 20 && sum.count < 20;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${r.run} · ${r.summary}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        kvRow('Adverts', '${sum.count} · ${sum.perSecond.toStringAsFixed(1)} /s'),
        kvRow('Median', '${d(sum.median)} dBm'),
        kvRow('Quartiles (IQR)', '${d(sum.q1)} … ${d(sum.q3)} (${d(sum.iqr)})'),
        kvRow('Min / max', '${sum.min ?? '—'} / ${sum.max ?? '—'}'),
        kvRow('Longest gap', '${(sum.longestGap.inMilliseconds / 1000).toStringAsFixed(1)} s'),
        kvRow('Other bands heard', _others.isEmpty ? 'none' : _others.join(', ')),
        if (low)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Very few adverts for this distance. Check the band is on and the phone was not blocked, and mark the run invalid if so.',
              style: TextStyle(color: kDangerInk, fontSize: 13),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Valid run'),
          value: _valid,
          onChanged: (v) => setState(() => _valid = v),
        ),
        if (!_valid)
          Wrap(
            spacing: 8,
            children: [
              for (final reason in _reasons)
                FilterChip(
                  label: Text(reason),
                  selected: _picked.contains(reason),
                  onSelected: (on) => setState(() => on ? _picked.add(reason) : _picked.remove(reason)),
                ),
            ],
          ),
        TextField(
          controller: _notes,
          decoration: const InputDecoration(labelText: 'Notes (optional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: kO4, minimumSize: const Size.fromHeight(48)),
                child: const Text('Save'),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: _saving ? null : () => setState(() => _phase = _Phase.ready),
              child: const Text('Discard'),
            ),
          ],
        ),
      ],
    );
  }
}
