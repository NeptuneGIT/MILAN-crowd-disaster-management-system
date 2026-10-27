import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'home_screen.dart' show fixLocation;
import 'logo.dart';
import 'theme.dart';

/// Opens the right prompt or settings page for Bluetooth: permission first, then the adapter switch.
Future<void> fixBluetooth() async {
  final p = await Permission.bluetoothScan.status;
  if (p.isPermanentlyDenied) {
    await openAppSettings();
  } else if (!p.isGranted) {
    await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
  } else {
    try {
      await FlutterBluePlus.turnOn(); // Android shows the system "turn on Bluetooth?" dialog
    } catch (_) {} // declined
  }
}

/// Blocks the whole app until device location and Bluetooth are on and allowed.
/// The child stays mounted underneath, so navigation state survives a toggle.
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key, required this.child});
  final Widget child;

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> with WidgetsBindingObserver {
  bool? _locationOk, _bluetoothOk; // null until the first check
  final _subs = <StreamSubscription<Object?>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subs
      ..add(Geolocator.getServiceStatusStream().listen((_) => _check()))
      ..add(FlutterBluePlus.adapterState.listen((_) => _check()));
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check(); // back from the settings page
  }

  Future<void> _check() async {
    final on = await Geolocator.isLocationServiceEnabled();
    final p = await Geolocator.checkPermission();
    final location = on && (p == LocationPermission.whileInUse || p == LocationPermission.always);
    final bluetooth =
        FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on && await Permission.bluetoothScan.isGranted;
    if (mounted && (location != _locationOk || bluetooth != _bluetoothOk)) {
      setState(() {
        _locationOk = location;
        _bluetoothOk = bluetooth;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = _locationOk, bluetooth = _bluetoothOk;
    final ready = location == true && bluetooth == true;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: !ready, child: widget.child),
        if (location == null || bluetooth == null) const ColoredBox(color: kGround),
        if (location == false)
          _block(
            icon: Icons.location_off_outlined,
            title: 'Location is off',
            button: 'Turn on',
            onPressed: () => fixLocation().then((_) => _check()),
          )
        else if (bluetooth == false)
          _block(
            icon: Icons.bluetooth_disabled,
            title: 'Bluetooth is off',
            button: 'Turn on',
            onPressed: () => fixBluetooth().then((_) => _check()),
          ),
      ],
    );
  }

  Widget _row(String name, bool ok) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ),
        Icon(ok ? Icons.check : Icons.close, size: 20, color: ok ? kInk : kDangerInk),
        const SizedBox(width: 6),
        Text(
          ok ? 'On' : 'Off',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ok ? kInk : kDangerInk),
        ),
      ],
    ),
  );

  Widget _block({
    required IconData icon,
    required String title,
    required String button,
    required VoidCallback onPressed,
  }) => Scaffold(
    body: Column(
      children: [
        Container(
          width: double.infinity,
          color: kHeader,
          padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 16, 20, 16),
          child: const Align(alignment: Alignment.centerLeft, child: MilanLogo(size: 36)),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height * 0.6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: const BoxDecoration(color: kDangerTint, shape: BoxShape.circle),
                    child: Icon(icon, size: 44, color: kDangerInk),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    title,
                    style: const TextStyle(fontSize: 28, height: 1.15, fontWeight: FontWeight.bold, color: kInk),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    decoration: cardDecoration(),
                    child: Column(
                      children: [
                        _row('Location', _locationOk == true),
                        const Divider(height: 1, color: kBorder),
                        _row('Bluetooth', _bluetoothOk == true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onPressed,
                      style: kBigButton,
                      child: Text(button, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
