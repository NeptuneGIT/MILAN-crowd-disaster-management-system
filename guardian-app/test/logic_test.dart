import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lostfound/ble/advert_parser.dart';
import 'package:lostfound/ble/beacon_stats.dart';
import 'package:lostfound/ble/field_test.dart';
import 'package:lostfound/ble/throttle.dart';
import 'package:lostfound/geo/format.dart';
import 'package:lostfound/geo/haversine.dart';

void main() {
  group('advert_parser', () {
    const eid = [0x00, 0x01, 0xAB, 0xFF, 0x10, 0x20, 0x30, 0x40];
    test('valid v2', () => expect(parseEid([0x52, 0x55, 0x02, ...eid]), '0001abff10203040'));
    test('wrong magic', () => expect(parseEid([0x52, 0x56, 0x02, ...eid]), isNull));
    test('static v1 is refused', () => expect(parseEid([0x52, 0x55, 0x01, 0x7B, 0, 0, 0, 0, 0, 0, 0]), isNull));
    test('short', () => expect(parseEid([0x52, 0x55, 0x02, 0x7B]), isNull));
    test('trailing bytes ignored', () => expect(parseEid([0x52, 0x55, 0x02, ...eid, 9]), '0001abff10203040'));
  });

  test('haversine known pair', () {
    expect(haversineM(25.4358, 81.8463, 25.4388, 81.8468), closeTo(337.3, 1));
  });

  test('maps link', () {
    expect(
      directionsUri(25.4388, 81.8468).toString(),
      'https://www.google.com/maps/dir/?api=1&destination=25.4388,81.8468&travelmode=walking',
    );
  });

  test('beacon label and live ago text', () {
    expect(beaconLabel(1), 'KM-000001');
    expect(beaconLabel(2147483647), 'KM-2147483647');
    expect(agoShort(const Duration(milliseconds: 800)), '0.8 s ago');
    expect(agoShort(const Duration(seconds: 48)), '48 s ago');
    expect(agoShort(const Duration(minutes: 3, seconds: 5)), '3 min ago');
  });

  group('beacon_stats', () {
    final t0 = DateTime(2026, 1, 1, 12);
    BeaconStats three() => BeaconStats('a', t0)
      ..record(-60, t0, 'AA')
      ..record(-80, t0.add(const Duration(seconds: 1)), 'AA')
      ..record(-70, t0.add(const Duration(seconds: 5)), 'AA');

    test('average, best, worst, last', () {
      final s = three();
      expect([s.average, s.best, s.worst, s.rssi, s.adverts], [-70, -60, -80, -70, 3]);
    });
    test('longest gap and rate', () {
      final s = three();
      expect(s.longestGap, const Duration(seconds: 4));
      expect(s.perSecond, closeTo(0.4, 0.001)); // 2 intervals over 5 s
    });
    test('lost after 10 s of silence', () {
      final s = three(); // last heard at t0+5 s
      expect(s.isLost(t0.add(const Duration(seconds: 14))), isFalse);
      expect(s.isLost(t0.add(const Duration(seconds: 16))), isTrue);
    });
    test('keeps only the last 60 readings; flags a second address', () {
      final s = BeaconStats('a', t0);
      for (var i = 0; i < 70; i++) {
        s.record(-50 - i, t0.add(Duration(milliseconds: i * 100)), i == 69 ? 'BB' : 'AA');
      }
      expect(s.recent.length, 60);
      expect(s.recent.first, -60); // readings 0..9 dropped
      expect(s.addresses, {'AA', 'BB'});
    });
    test('signal bars and label', () {
      expect([signalBars(-55), signalBars(-62), signalBars(-75), signalBars(-88)], [4, 3, 2, 1]);
      expect([signalLabel(-62), signalLabel(-75), signalLabel(-88)], ['Strong', 'OK', 'Weak']);
    });
    test('csv', () {
      final csv = advertsCsv([AdvertEvent(t0, 'a', -62, 'AA:BB')]);
      expect(csv, 'time,beacon_id,rssi_dbm,address\n2026-01-01T12:00:00.000,a,-62,AA:BB\n');
    });
    test('window stats: median, count, and IQR', () {
      final s = BeaconStats('a', t0);
      for (var i = 0; i < 5; i++) {
        s.record(-70 + i * 5, t0.add(Duration(seconds: i * 2)), 'AA');
      }
      final tNow = t0.add(const Duration(seconds: 8));
      final w10 = s.windowStats(const Duration(seconds: 10), tNow);
      expect(w10.n, 5);
      expect(w10.median, -60.0);
      expect(w10.iqr, closeTo(10.0, 0.001));

      final w3 = s.windowStats(const Duration(seconds: 3), tNow);
      expect(w3.n, 2);
      expect(w3.median, -52.5);
      expect(w3.iqr, closeTo(2.5, 0.001));
    });

    test('window stats edge cases', () {
      const win = Duration(seconds: 10);
      final s = BeaconStats('a', t0);
      expect(s.windowStats(win, t0), (median: 0.0, n: 0, iqr: 0.0));
      s.record(-50, t0, 'AA');
      expect(s.windowStats(win, t0), (median: -50.0, n: 1, iqr: 0.0));
      // Nothing inside the window: the latest reading stands in.
      expect(s.windowStats(win, t0.add(const Duration(minutes: 1))), (median: -50.0, n: 1, iqr: 0.0));
      final two = BeaconStats('a', t0)
        ..record(-70, t0, 'AA')
        ..record(-60, t0, 'AA');
      final w = two.windowStats(win, t0);
      expect([w.median, w.iqr], [-65.0, 5.0]);
    });
  });

  test('ago text', () {
    expect(agoText(const Duration(seconds: 20)), 'just now');
    expect(agoText(const Duration(minutes: 3, seconds: 40)), '3 min ago');
    expect(agoText(const Duration(minutes: 125)), '2 h ago');
  });

  test('distance formatting', () {
    expect(formatDistance(340), '340 m');
    expect(formatDistance(999), '999 m');
    expect(formatDistance(1000), '1.0 km');
    expect(formatDistance(1234), '1.2 km');
  });

  group('throttle', () {
    late DateTime t;
    late UploadThrottle th;
    setUp(() {
      t = DateTime(2026);
      th = UploadThrottle(now: () => t);
    });

    test('5 s apart -> one upload', () {
      expect(th.tryAcquire('a'), isTrue);
      t = t.add(const Duration(seconds: 5));
      expect(th.tryAcquire('a'), isFalse);
    });

    test('11 s apart -> two uploads', () {
      expect(th.tryAcquire('a'), isTrue);
      t = t.add(const Duration(seconds: 11));
      expect(th.tryAcquire('a'), isTrue);
    });

    test('per beacon', () {
      expect(th.tryAcquire('a'), isTrue);
      expect(th.tryAcquire('b'), isTrue);
    });
  });

  group('field test', () {
    final open = parseSheet(File(kOpenFieldSheet).readAsStringSync());
    final body = parseSheet(File(kBodyStackingSheet).readAsStringSync());
    final t0 = DateTime(2026, 1, 1, 12);

    RunRecord record(RunSpec spec, int attempt, {bool valid = true, String notes = ''}) => RunRecord(
      spec: spec,
      attempt: attempt,
      startTime: t0,
      stopTime: t0.add(const Duration(seconds: 60)),
      valid: valid,
      notes: notes,
      beaconId: 'b',
      summary: summarize([AdvertEvent(t0, 'b', -61, 'AA')], const Duration(seconds: 60)),
    );

    test('open-field sheet parses in order', () {
      expect(open.length, 36);
      expect(open.first.run, 'O01');
      expect(open.last.run, 'O36');
      expect(open.every((r) => r.durationS == 60), isTrue);
      expect(open.where((r) => r.role == 'holdout').length, 12);
      expect(open.where((r) => r.phonePosition == 'pocket').length, 18);
      expect(open.every((r) => r.bodiesK == null), isTrue);
    });

    test('body sheet parses; spots match the count', () {
      expect(body.length, 28);
      for (final r in body) {
        expect(r.bodiesK, isNotNull);
        expect(r.bodySpots.length, r.bodiesK, reason: r.run);
        expect(r.distanceM, 10);
      }
      expect(body[2].bodySpots, [5.0, 3.5]);
      expect(body.first.role, '');
    });

    test('csv parse and write round-trip with quotes and commas', () {
      final rows = parseCsv('a,b\r\n1,"x, ""y"""\n\n,\n');
      expect(rows, [
        ['a', 'b'],
        ['1', 'x, "y"'],
        ['', ''],
      ]);
      expect(csvRow(['1', 'x, "y"', 'z']), '1,"x, ""y""",z\n');
    });

    test('run descriptions', () {
      expect(open.firstWhere((r) => r.run == 'O04').summary, '2 m · pocket');
      expect(body[0].summary, '10 m · no bodies');
      expect(body[1].summary, '10 m · 1 body');
      expect(body[2].setup, contains('2 bodies standing on the line at 5.0 and 3.5 m'));
      expect(open[3].setup, contains('front trouser pocket'));
    });

    test('summary stats', () {
      final ev = [
        for (var i = 0; i < 5; i++)
          AdvertEvent(t0.add(Duration(milliseconds: i == 4 ? 1500 : i * 100)), 'a', -60 - 10 * i, 'AA'),
      ];
      final s = summarize(ev, const Duration(seconds: 1));
      expect(s.count, 5);
      expect(s.perSecond, 5);
      expect(s.median, -80);
      expect(s.q1, -90);
      expect(s.q3, -70);
      expect(s.iqr, 20);
      expect([s.min, s.max], [-100, -60]);
      expect(s.longestGap, const Duration(milliseconds: 1200));
    });

    test('summary of nothing is defined', () {
      final s = summarize([], const Duration(seconds: 60));
      expect(s.count, 0);
      expect(s.median, isNull);
      expect(s.iqr, isNull);
    });

    test('attempt file names', () {
      expect(attemptName('O07', 1), 'O07');
      expect(attemptName('O07', 2), 'O07_2');
      expect(attemptName('O07', 3), 'O07_3');
    });

    test('runs.csv row keeps the sheet columns and adds ours', () {
      final spec = open.first;
      final rec = record(spec, 2, valid: false, notes: 'phone moved, re-done');
      final lines = (csvRow([...spec.columns, ...kExtraColumns]) + csvRow(rec.row)).trim().split('\n');
      expect(
        lines[0],
        'run,session,replicate,distance_m,phone_position,role,duration_s,start_time,stop_time,valid,notes,'
        'attempt,beacon_id,n_adverts,median_rssi,phone_model',
      );
      expect(
        lines[1],
        'O01,1,1,1,held,fit,60,2026-01-01T12:00:00.000,2026-01-01T12:01:00.000,n,"phone moved, re-done",2,b,1,-61.0,',
      );
      expect(rec.fileName, 'O01_2.csv');
    });

    test('store: save, re-record, state, restart', () async {
      final dir = Directory.systemTemp.createTempSync('fieldtest');
      addTearDown(() => dir.deleteSync(recursive: true));
      final spec = open.first;
      final store = FieldTestStore(dir, spec.columns);
      expect(store.stateOf('O01'), RunState.notDone);

      await store.save(record(spec, 1, valid: false, notes: 'moved'), [AdvertEvent(t0, 'b', -61, 'AA')]);
      expect(store.stateOf('O01'), RunState.invalid);
      expect(store.attemptsOf('O01'), 1);

      await store.save(record(spec, 2), [AdvertEvent(t0, 'b', -60, 'AA')]);
      expect(store.stateOf('O01'), RunState.done);
      expect(store.attemptsOf('O01'), 2);
      expect(store.stateOf('O02'), RunState.notDone);

      // The first attempt's file is still there, and the CSV matches the debug export.
      expect(File('${dir.path}/O01.csv').readAsStringSync(), startsWith('time,beacon_id,rssi_dbm,address\n'));
      expect(File('${dir.path}/O01_2.csv').existsSync(), isTrue);
      expect(FieldTestStore.filesIn(dir).map((f) => f.uri.pathSegments.last), ['O01.csv', 'O01_2.csv', 'runs.csv']);

      // A new store over the same folder (app restart) sees the same rows.
      expect(FieldTestStore(dir, spec.columns).readRows().length, 2);
      // A different sheet layout is set aside, not mixed in.
      expect(FieldTestStore(dir, body.first.columns).readRows(), isEmpty);
    });
  });
}
