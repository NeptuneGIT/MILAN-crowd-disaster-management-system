import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ble/scanner_service.dart';
import '../data.dart';
import 'logo.dart';
import 'theme.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _hidePassword = true;

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (email.isEmpty || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      await auth.signInWithPassword(email: email, password: _password.text);
      final dependents = await fetchDependents();
      if (dependents.isEmpty) {
        await auth.signOut();
        setState(() => _error = 'No dependents found');
        return;
      }
      await ScannerService.requestPermissions();
      ScannerService.instance.start();
      ref.read(emailProvider.notifier).sync();
    } catch (e) {
      debugPrint('[login] $e');
      // Don't leave a half-signed-in session behind if a later step failed.
      if (auth.currentSession != null) await auth.signOut();
      setState(() => _error = _explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A readable reason for the person, not a stack trace.
  String _explain(Object e) {
    if (e is AuthException) {
      return e.message == 'Invalid login credentials' ? 'Wrong email or password' : e.message;
    }
    if (e is PostgrestException) return 'Server error: ${e.message}';
    return 'No connection';
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = const TextStyle(color: kMuted, height: 1.45);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.center,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(color: kHeader, borderRadius: BorderRadius.circular(18)),
                    child: const Center(child: MilanMark(size: 44)),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'MILAN',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, letterSpacing: 4, color: kInk),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.username],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  obscureText: _hidePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    suffixIcon: IconButton(
                      tooltip: _hidePassword ? 'Show password' : 'Hide password',
                      icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _hidePassword = !_hidePassword),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline, size: 18, color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: kBigButton,
                  child: _busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Text('Sign in', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 28),
                Text(
                  'Location is shared only when a missing dependent is heard nearby.',
                  style: muted.copyWith(fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
