import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ble/scanner_service.dart';
import 'data.dart';
import 'ui/home_screen.dart';
import 'ui/permission_gate.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Developer misconfiguration, not a user flow: say exactly what's wrong instead of failing
  // later inside a network call.
  if (_supabaseUrl.isEmpty || _supabaseAnonKey.isEmpty) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'SUPABASE_URL / SUPABASE_ANON_KEY were not passed to this build.\n\n'
                'Stop the app and run it from the guardian-app folder with:\n'
                'flutter run --dart-define-from-file=dart-defines.json\n\n'
                'Hot restart is not enough: these values are fixed when the app is compiled.',
                style: TextStyle(fontSize: 16, height: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }
  // The legacy anon key and the newer publishable key both work here.
  await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);

  // Signed in before (supabase_flutter restores the saved session): the always-on scanner
  // comes straight back up.
  if (Supabase.instance.client.auth.currentSession != null) ScannerService.instance.start();

  runApp(const ProviderScope(child: App()));
}

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(emailProvider) != null;
    return MaterialApp(
      title: 'MILAN',
      debugShowCheckedModeBanner: false,
      theme: milanTheme(),
      builder: (context, child) => PermissionGate(child: child!), // covers every route
      home: loggedIn ? const HomeScreen() : const LoginScreen(),
    );
  }
}
