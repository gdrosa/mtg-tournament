import 'package:flutter/material.dart';

import '../host/host_controller.dart';
import '../services/cloud_sync.dart';
import '../shared/models.dart';
import 'app_scope.dart';

/// Profile tab — the durable device-owner identity (FR-01/02, Q1) and their
/// lifetime statistics aggregated from real tournament history. Real data only;
/// empty until the owner hosts an event or registers a deck.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final owner = c.server.owner;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text('Profile', style: theme.textTheme.titleLarge),
        actions: [
          if (owner != null)
            IconButton(
              tooltip: 'Edit nickname',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _editNickname(context, c, owner.nickname),
            ),
        ],
      ),
      body: owner == null
          ? _EmptyProfile(onCreate: () => _editNickname(context, c, ''))
          : _ProfileBody(owner: owner, controller: c),
    );
  }

  Future<void> _editNickname(
    BuildContext context,
    HostController c,
    String current,
  ) async {
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(current.isEmpty ? 'Set your nickname' : 'Edit nickname'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nickname'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) c.setNickname(name);
  }
}

class _ProfileBody extends StatelessWidget {
  final Player owner;
  final HostController controller;
  const _ProfileBody({required this.owner, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = controller.server.stats;
    final life = stats.playerLifetime(owner.id);

    // Best deck = owner's deck with the most match wins in history.
    final decks = controller.server.decksOf(owner.id);
    Deck? best;
    var bestWins = -1;
    for (final d in decks) {
      final w = stats.deckRecord(d.id).wins;
      if (w > bestWins) {
        bestWins = w;
        best = d;
      }
    }
    final bestDeck = (best != null && bestWins > 0) ? best.name : '—';

    final mr = life.matchRecord;
    final matchWinPct = mr.matches == 0 ? 0 : (mr.winRate * 100).round();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
              child: Icon(
                Icons.person,
                size: 36,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(owner.nickname, style: theme.textTheme.headlineMedium),
                  Text(
                    'Durable profile · hosts this device',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Tournaments',
                value: '${life.tournamentsPlayed}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(label: 'Match win %', value: '$matchWinPct%'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(label: 'Best deck', value: bestDeck),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Lifetime', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _StatRow('Matches played', '${mr.matches}'),
                _StatRow(
                  'Match record',
                  '${mr.wins}–${mr.losses}'
                      '${mr.draws > 0 ? '–${mr.draws}' : ''}',
                ),
                _StatRow('Game win %', '${(life.gameWinPct * 100).round()}%'),
                _StatRow('Tournaments won', '${life.tournamentsWon}'),
              ],
            ),
          ),
        ),
        if (life.tournamentsPlayed == 0) ...[
          const SizedBox(height: 16),
          Text(
            'Play in a hosted event to start building your record.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        const CloudCard(),
      ],
    );
  }
}

/// Google account backup controls. Signed in → show the account + sign-out and
/// "Back up now"; signed out → offer sign-in. Reused on the empty profile too.
class CloudCard extends StatefulWidget {
  const CloudCard({super.key});
  @override
  State<CloudCard> createState() => _CloudCardState();
}

class _CloudCardState extends State<CloudCard> {
  bool _busy = false;

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
  );

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      final m = cloudErrorMessage(
        e,
      ); // honest reason, not a blanket "network error"
      if (mounted && m.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(m), duration: const Duration(seconds: 6)),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final signedIn = c.cloud.isSignedIn;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  signedIn
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    signedIn ? 'Cloud backup on' : 'Cloud backup off',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              signedIn
                  ? 'Synced to ${c.cloud.email ?? 'your Google account'}. Your decks, '
                        'profile and history are saved to your Google Drive.'
                  : 'Sign in with Google to save your data to your own Google Drive '
                        'and restore it after a reinstall.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (signedIn)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => _run(() async {
                        final ok = await c.backupNow();
                        if (mounted) {
                          _toast(
                            ok
                                ? 'Backed up to Google Drive.'
                                : 'Backup failed.',
                          );
                        }
                      }),
                      icon: const Icon(Icons.backup_outlined),
                      label: const Text('Back up now'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () => _run(c.signOutCloud),
                    child: const Text('Sign out'),
                  ),
                ],
              )
            else
              FilledButton.icon(
                onPressed: () => _run(() async {
                  final ok = await c.signInToCloud();
                  if (mounted && ok) _toast('Signed in — data synced.');
                }),
                icon: const Icon(Icons.login),
                label: const Text('Sign in with Google'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyProfile extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyProfile({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      children: [
        Icon(Icons.person_outline, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'No profile yet',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Set a nickname to start a durable profile. Hosting an event or '
          'registering a deck also creates one automatically.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.badge_outlined),
          label: const Text('Set nickname'),
        ),
        const SizedBox(height: 28),
        const CloudCard(),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        child: Column(
          children: [
            Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  const _StatRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
