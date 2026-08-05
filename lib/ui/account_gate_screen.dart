import 'package:flutter/material.dart';

import '../services/cloud_sync.dart';
import 'app_scope.dart';

/// First-run gate (FR: durable identity). Shown when there's no profile yet and
/// the user hasn't chosen: sign in with Google to back up / restore data across
/// reinstalls, or continue as a guest (everything stays on-device).
class AccountGateScreen extends StatefulWidget {
  const AccountGateScreen({super.key});

  @override
  State<AccountGateScreen> createState() => _AccountGateScreenState();
}

class _AccountGateScreenState extends State<AccountGateScreen> {
  bool _busy = false;

  Future<void> _google() async {
    final c = AppScope.of(context);
    setState(() => _busy = true);
    bool ok = false;
    String? msg;
    try {
      ok = await c.signInToCloud();
    } catch (e) {
      msg = cloudErrorMessage(
        e,
      ); // honest reason (often: OAuth not set up, NOT network)
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // On success the gate disappears (needsAccountGate flips). On a plain cancel
    // (ok == false, empty msg) stay put silently.
    if (!ok && msg != null && msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 6)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            28,
            28,
            28,
            28 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/app_logo.png', height: 96),
              const SizedBox(height: 20),
              Text(
                'MTG Tournament',
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in with Google to save your decks, profile and history to your '
                'own Google Drive — so you keep them if you reinstall. Or play as a '
                'guest with everything stored only on this phone.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 28),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: CircularProgressIndicator(),
                )
              else ...[
                FilledButton.icon(
                  onPressed: _google,
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in with Google'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => AppScope.of(context).continueAsGuest(),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: const Text('Continue as guest'),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'You can sign in later from the Profile tab.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
