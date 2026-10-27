import 'dart:io';

import 'beacon_stats.dart';

// Pure logic behind the debug screen's field-test panel (docs/field-test-guide.md in the repo root):
// the run sheets, the per-run summary, and the files written for each run.

/// Lead-in before each recording, so everyone is in place and still.
const kSettleSeconds = 10;

/// Listed as assets in pubspec.yaml; the files in docs/ stay the single source of truth.
const kOpenFieldSheet = 'assets/field-test/rssi-open-field-sheet.csv';
const kBodyStackingSheet = 'assets/field-test/rssi-body-stacking-sheet.csv';

// ── CSV ──

/// Minimal CSV (RFC 4180): quoted fields, doubled quotes, CRLF or LF, blank lines skipped.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var any = false; // something was seen on this line, so a line of empty cells still counts

  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    if (any) {
      endField();
      rows.add(row);
    }
    row = <String>[];
    any = false;
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      quoted = true;
      any = true;
    } else if (c == ',') {
      endField();
      any = true;
    } else if (c == '\n') {
      endRow();
    } else if (c != '\r') {
      field.write(c);
      any = true;
    }
  }
  endRow();
  return rows;
}

/// Quotes a field only when it needs it.
String csvField(String v) => v.contains(RegExp(r'[",\r\n]')) ? '"${v.replaceAll('"', '""')}"' : v;

String csvRow(Iterable<String> fields) => '${fields.map(csvField).join(',')}\n';

// ── Run sheets ──

/// One row of a run sheet. All columns are kept so they can be written back to runs.csv.
class RunSpec {
  RunSpec(this.columns, this.fields);

  final List<String> columns;
  final Map<String, String> fields;

  String get run => fields['run'] ?? '';
  int get session => int.tryParse(fields['session'] ?? '') ?? 0;
  double get distanceM => double.tryParse(fields['distance_m'] ?? '') ?? 0;
  int get durationS => int.tryParse(fields['duration_s'] ?? '') ?? 60;

  /// Open field only: `held` or `pocket`. Body stacking is always held.
  String get phonePosition => fields['phone_position'] ?? 'held';

  /// Open field only: `fit` or `holdout`. Empty for body stacking.
  String get role => fields['role'] ?? '';

  /// Body stacking only: null for the open-field sheet.
  int? get bodiesK => int.tryParse(fields['bodies_k'] ?? '');

  /// Metres from the band, in the order the bodies are placed.
  List<double> get bodySpots =>
      (fields['body_positions_m'] ?? '').split(RegExp(r'\s+')).map(double.tryParse).whereType<double>().toList();

  /// Short line for the run list: `10 m · pocket`, `10 m · 3 bodies`.
  String get summary {
    final k = bodiesK;
    final what = k != null ? (k == 0 ? 'no bodies' : '$k ${k == 1 ? 'body' : 'bodies'}') : phonePosition;
    return '${_m(distanceM)} m · $what';
  }

  /// Plain-language set-up shown before the run.
  String get setup {
    final phone = phonePosition == 'pocket'
        ? 'Phone in the front trouser pocket (about 0.9 m high), screen towards your body'
        : 'Phone held at chest height (about 1.2 m), screen up, in front of your body';
    final b = StringBuffer('$phone, you facing the band, ${_m(distanceM)} m from the band.');
    final k = bodiesK;
    if (k != null) {
      b.write(
        k == 0
            ? ' No bodies on the line.'
            : ' $k ${k == 1 ? 'body' : 'bodies'} standing on the line at ${_list(bodySpots)} m from the band.',
      );
    }
    return b.toString();
  }
}

String _m(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString();

String _list(List<double> v) {
  final s = v.map((e) => e.toStringAsFixed(1)).toList();
  return s.length < 2 ? s.join() : '${s.sublist(0, s.length - 1).join(', ')} and ${s.last}';
}

/// Parses a run sheet. Row order is the run order. Rows without a `run` are dropped.
List<RunSpec> parseSheet(String csv) {
  final rows = parseCsv(csv);
  if (rows.isEmpty) return [];
  final columns = rows.first.map((c) => c.trim()).toList();
  return [
    for (final r in rows.skip(1))
      if (r.isNotEmpty && r.first.trim().isNotEmpty)
        RunSpec(columns, {for (var i = 0; i < columns.length; i++) columns[i]: i < r.length ? r[i] : ''}),
  ];
}

// ── Summary ──

class RunSummary {
  const RunSummary({
    required this.count,
    required this.perSecond,
    this.median,
    this.q1,
    this.q3,
    this.min,
    this.max,
    this.longestGap = Duration.zero,
  });

  final int count;
  final double perSecond;
  final double? median, q1, q3;
  final int? min, max;
  final Duration longestGap;

  double? get iqr => q1 == null || q3 == null ? null : q3! - q1!;
}

RunSummary summarize(List<AdvertEvent> events, Duration length) {
  final perSecond = length.inMilliseconds == 0 ? 0.0 : events.length * 1000 / length.inMilliseconds;
  if (events.isEmpty) return RunSummary(count: 0, perSecond: perSecond);
  final rssi = events.map((e) => e.rssi).toList()..sort();
  var gap = Duration.zero;
  for (var i = 1; i < events.length; i++) {
    final g = events[i].at.difference(events[i - 1].at);
    if (g > gap) gap = g;
  }
  return RunSummary(
    count: events.length,
    perSecond: perSecond,
    median: quantile(rssi, 0.5),
    q1: quantile(rssi, 0.25),
    q3: quantile(rssi, 0.75),
    min: rssi.first,
    max: rssi.last,
    longestGap: gap,
  );
}

// ── Files ──

/// File stem for one attempt: `O07`, then `O07_2`, `O07_3` for re-records (never overwritten).
String attemptName(String run, int attempt) => attempt <= 1 ? run : '${run}_$attempt';

/// Columns added after the sheet's own, in this order.
const kExtraColumns = ['attempt', 'beacon_id', 'n_adverts', 'median_rssi', 'phone_model'];

/// One saved attempt. The sheet's `start_time`, `stop_time`, `valid` and `notes` are filled in.
class RunRecord {
  RunRecord({
    required this.spec,
    required this.attempt,
    required this.startTime,
    required this.stopTime,
    required this.valid,
    required this.notes,
    required this.beaconId,
    required this.summary,
    this.phoneModel = '',
  });

  final RunSpec spec;
  final int attempt;
  final DateTime startTime, stopTime;
  final bool valid;
  final String notes;
  final String beaconId;
  final RunSummary summary;
  final String phoneModel;

  String get fileName => '${attemptName(spec.run, attempt)}.csv';

  List<String> get row {
    final filled = {
      ...spec.fields,
      'start_time': startTime.toIso8601String(),
      'stop_time': stopTime.toIso8601String(),
      'valid': valid ? 'y' : 'n',
      // Keep the sheet's own note (such as "repeat of O07") and add the operator's.
      'notes': [spec.fields['notes'] ?? '', notes].where((s) => s.isNotEmpty).join('; '),
      'attempt': '$attempt',
      'beacon_id': beaconId,
      'n_adverts': '${summary.count}',
      'median_rssi': summary.median?.toStringAsFixed(1) ?? '',
      'phone_model': phoneModel,
    };
    return [
      for (final c in [...spec.columns, ...kExtraColumns]) filled[c] ?? '',
    ];
  }
}

enum RunState { notDone, done, invalid }

/// Reads and writes `runs.csv` and the per-attempt CSVs for one sheet, in [dir].
class FieldTestStore {
  FieldTestStore(this.dir, this.sheetColumns);

  final Directory dir;
  final List<String> sheetColumns;

  List<String> get header => [...sheetColumns, ...kExtraColumns];
  File get runsFile => File('${dir.path}/runs.csv');

  /// Saved rows, header excluded. A runs.csv from a different sheet layout is set aside, not mixed in.
  List<List<String>> readRows() {
    if (!runsFile.existsSync()) return [];
    final rows = parseCsv(runsFile.readAsStringSync());
    if (rows.isEmpty) return [];
    if (rows.first.join(',') != header.join(',')) {
      runsFile.renameSync('${dir.path}/runs_old_${DateTime.now().millisecondsSinceEpoch}.csv');
      return [];
    }
    return rows.skip(1).toList();
  }

  /// Attempts already saved for [run], valid or not. Pass [rows] (from [readRows]) to skip the disk read.
  int attemptsOf(String run, [List<List<String>>? rows]) =>
      (rows ?? readRows()).where((r) => r[header.indexOf('run')] == run).length;

  RunState stateOf(String run, [List<List<String>>? rows]) {
    final mine = (rows ?? readRows()).where((r) => r[header.indexOf('run')] == run);
    if (mine.isEmpty) return RunState.notDone;
    return mine.any((r) => r[header.indexOf('valid')] == 'y') ? RunState.done : RunState.invalid;
  }

  /// Writes the attempt's adverts, then rewrites runs.csv through a temp file so a kill mid-save
  /// can't leave it half-written.
  Future<void> save(RunRecord rec, List<AdvertEvent> adverts) async {
    final rows = readRows();
    await dir.create(recursive: true);
    await File('${dir.path}/${rec.fileName}').writeAsString(advertsCsv(adverts));
    final b = StringBuffer(csvRow(header));
    for (final r in [...rows, rec.row]) {
      b.write(csvRow(r));
    }
    final tmp = File('${runsFile.path}.tmp');
    await tmp.writeAsString(b.toString());
    await tmp.rename(runsFile.path);
  }

  /// runs.csv and every attempt CSV in [dir], for the share sheet.
  static List<File> filesIn(Directory dir) => dir.existsSync()
      ? (dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.csv') && !f.path.contains('runs_old_'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : [];
}
