import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ble/scanner_service.dart';
import '../data.dart';
import '../geo/format.dart';
import '../geo/haversine.dart';
import 'debug_screen.dart';
import 'logo.dart';
import 'theme.dart';

final _scanner = ScannerService.instance;

/// Ask for location permission, or send the user to the right settings page.
Future<void> fixLocation() async {
  final p = await Geolocator.checkPermission();
  if (p == LocationPermission.deniedForever) {
    await Geolocator.openAppSettings();
  } else if (p == LocationPermission.denied) {
    await Geolocator.requestPermission();
  } else {
    await Geolocator.openLocationSettings();
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        backgroundColor: kHeader,
        foregroundColor: kInk,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 20,
        title: GestureDetector(
          // Hidden debug screen (README §4.3). kDebugMode is a compile-time constant, so release and
          // profile builds have no long-press handler and the screen is dropped from the app entirely.
          onLongPress: kDebugMode
              ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DebugScreen()))
              : null,
          child: const MilanLogo(),
        ),
        actions: [
          const Flexible(child: _StatusChip()),
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(emailProvider.notifier).logout(),
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: const [_DependentsTab(), _CampsTab()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.people_outline), label: 'Dependents'),
          NavigationDestination(icon: Icon(Icons.location_on_outlined), label: 'Camps'),
        ],
      ),
    );
  }
}

/// Status only, never a switch: the scanner cannot be turned off.
class _StatusChip extends StatelessWidget {
  const _StatusChip();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _scanner,
      builder: (context, _) {
        // Never shows how many dependents are missing.
        final warn = _scanner.health == ScannerHealth.bluetoothOff;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: warn ? kDangerTint : kO1, borderRadius: BorderRadius.circular(999)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 8, color: warn ? kDanger : kInk),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _scanner.health.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: warn ? kDangerInk : kInk),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

const _headingStyle = TextStyle(fontSize: 20, height: 1.2, fontWeight: FontWeight.bold, color: kText);
const _labelStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: kMuted);

class _DependentsTab extends ConsumerStatefulWidget {
  const _DependentsTab();

  @override
  ConsumerState<_DependentsTab> createState() => _DependentsTabState();
}

class _DependentsTabState extends ConsumerState<_DependentsTab> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => ref.invalidate(dependentsProvider));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dependents = ref.watch(dependentsProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(dependentsProvider.future),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Your dependents', style: _headingStyle),
          const SizedBox(height: 16),
          ...switch (dependents) {
            AsyncData(:final value) => value.map(_dependentCard),
            AsyncError() => [const Text("Couldn't load")],
            _ => [const Center(child: CircularProgressIndicator())],
          },
        ],
      ),
    );
  }

  Widget _dependentCard(Dependent c) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(20),
    decoration: cardDecoration(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          c.name,
          style: const TextStyle(
            fontSize: 30,
            height: 1.15,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            color: kInk,
          ),
        ),
        const SizedBox(height: 8),
        Text('${c.label} · Beacon ${c.beaconId}', style: _labelStyle.copyWith(fontSize: 14, letterSpacing: 0.6)),
        // Read-only. No "report missing" button, on purpose (README §4.3).
        if (c.isMissing) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: kDangerTint, borderRadius: BorderRadius.circular(10)),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 22, color: kDangerInk),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Missing',
                    style: TextStyle(fontSize: 15, height: 1.3, fontWeight: FontWeight.bold, color: kDangerInk),
                  ),
                ),
              ],
            ),
          ),
        ] else if (c.found == null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: kChipGrey, borderRadius: BorderRadius.circular(999)),
              child: const Text(
                'Not missing',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: kMuted),
              ),
            ),
          ),
        ],
        if (c.found != null) ...[const SizedBox(height: 14), _FoundPanel(c)],
      ],
    ),
  );
}

/// Shown from when staff mark a dependent found until the guardian confirms (or staff dismiss it).
class _FoundPanel extends ConsumerWidget {
  const _FoundPanel(this.dependent);
  final Dependent dependent;

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Confirm',
              style: TextStyle(fontSize: 24, height: 1.2, fontWeight: FontWeight.bold, color: kInk),
            ),
            const SizedBox(height: 8),
            Text('${dependent.name} is with you', style: const TextStyle(fontSize: 17, color: kMuted)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: kBigButton,
              child: const Text('Confirm', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: kBigButton,
              child: const Text('Cancel', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final cleared = await acknowledgeFound(dependent.id);
      ref.invalidate(dependentsProvider); // an already-cleared notice just disappears on refresh
      messenger.showSnackBar(SnackBar(content: Text(cleared ? 'Confirmed' : 'Already cleared')));
    } catch (e) {
      debugPrint('[found] $e');
      // Debug builds show the real reason (for example a missing database function).
      messenger.showSnackBar(SnackBar(content: Text(kDebugMode ? "Couldn't confirm: $e" : "Couldn't confirm")));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = dependent.found!;
    final camp = found.camp;
    return ListenableBuilder(
      listenable: _scanner,
      builder: (context, _) {
        final fix = _scanner.locationOk ? _scanner.lastFix : null;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kO1,
            border: Border.all(color: kO2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check, size: 20, color: kInk),
                  const SizedBox(width: 8),
                  Text(
                    'Found · ${agoText(DateTime.now().difference(found.at))}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: kInk),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                camp.name,
                style: const TextStyle(fontSize: 20, height: 1.2, fontWeight: FontWeight.bold, color: kText),
              ),
              if (fix != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${formatDistance(haversineM(fix.latitude, fix.longitude, camp.lat, camp.lon))} away',
                  style: const TextStyle(fontSize: 16, color: kMuted),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => launchUrl(directionsUri(camp.lat, camp.lon), mode: LaunchMode.externalApplication),
                  style: kBigButton,
                  icon: const Icon(Icons.near_me_outlined),
                  label: const Text('Directions', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _confirm(context, ref),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: kPaper,
                    side: const BorderSide(color: kInk, width: 2),
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Found', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CampsTab extends ConsumerWidget {
  const _CampsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final camps = ref.watch(campsProvider);
    return ListenableBuilder(
      listenable: _scanner,
      builder: (context, _) {
        // Reuse the scanner's GPS stream: no separate location request here.
        final fix = _scanner.locationOk ? _scanner.lastFix : null;
        return RefreshIndicator(
          onRefresh: () => ref.refresh(campsProvider.future),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: switch (camps) {
              AsyncData(:final value) => _body(context, value, fix),
              AsyncError() => [const Text("Couldn't load")],
              _ => [const Center(child: CircularProgressIndicator())],
            },
          ),
        );
      },
    );
  }

  List<Widget> _body(BuildContext context, List<Camp> camps, Position? fix) {
    if (fix == null) {
      final sorted = [...camps]..sort((a, b) => a.name.compareTo(b.name));
      return [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          decoration: cardDecoration(),
          child: const Row(
            children: [
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
              SizedBox(width: 14),
              Expanded(
                child: Text('Finding your location…', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text('All camps', style: _headingStyle),
        const SizedBox(height: 12),
        _list(sorted.map((c) => (c, null))),
      ];
    }

    final withDist = camps.map((c) => (c, haversineM(fix.latitude, fix.longitude, c.lat, c.lon))).toList()
      ..sort((a, b) => a.$2.compareTo(b.$2));
    final (nearest, d) = withDist.first;
    return [
      const Text('Camps', style: _headingStyle),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              nearest.name,
              style: const TextStyle(fontSize: 30, height: 1.1, fontWeight: FontWeight.w800, color: kInk),
            ),
            const SizedBox(height: 8),
            const Text(
              'Nearest camp',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.6, color: kMuted),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kO1,
                border: Border.all(color: kO2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${formatDistance(d)} away',
                    style: const TextStyle(fontSize: 20, height: 1.2, fontWeight: FontWeight.bold, color: kText),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _directions(nearest),
                      style: kBigButton,
                      icon: const Icon(Icons.near_me_outlined),
                      label: const Text('Directions', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const Text('All camps', style: _headingStyle),
      const SizedBox(height: 12),
      _list(withDist),
    ];
  }

  Widget _list(Iterable<(Camp, double?)> rows) => Container(
    decoration: cardDecoration(),
    child: Column(
      children: [
        for (final (c, d) in rows)
          ListTile(
            title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: d == null ? null : Text(formatDistance(d)),
            trailing: OutlinedButton.icon(
              onPressed: () => _directions(c),
              icon: const Icon(Icons.near_me_outlined, size: 18),
              label: const Text('Directions'),
            ),
          ),
      ],
    ),
  );

  void _directions(Camp c) => launchUrl(directionsUri(c.lat, c.lon), mode: LaunchMode.externalApplication);
}
