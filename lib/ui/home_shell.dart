import 'package:flutter/material.dart';

import '../services/app_update.dart';
import '../shared/tournament_engine.dart';
import 'account_gate_screen.dart';
import 'app_scope.dart';
import 'decks_screen.dart';
import 'events_screen.dart';
import 'format.dart';
import 'host_screen.dart';
import 'profile_screen.dart';
import 'stats_screen.dart';
import 'tournament_detail_screen.dart';

/// App root: show the first-run account gate until the user signs in or chooses
/// guest, then the main tab shell. Rebuilds with the shared controller.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context);
    if (!c.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return c.needsAccountGate ? const AccountGateScreen() : const HomeShell();
  }
}

/// Root navigation, modelled on the Companion app's bottom-tab layout:
/// Home · Decks · Events · Profile.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Ask once per launch, after the first frame so a dialog has a Navigator.
    // Silent when there is nothing newer, and offline simply does nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkForUpdate(context);
    });
  }

  static const _tabs = [
    _HomeTab(),
    DecksScreen(),
    EventsScreen(),
    StatsScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Each tab is its own Scaffold whose AppBar already owns the top inset, and
      // this Scaffold insets the NavigationBar — a wrapping SafeArea here would
      // double-pad the top. Edge-to-edge bottom is handled per scroll view.
      body: _tabs[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style),
            label: 'Decks',
          ),
          NavigationDestination(
            icon: Icon(Icons.emoji_events_outlined),
            selectedIcon: Icon(Icons.emoji_events),
            label: 'Events',
          ),
          NavigationDestination(
            icon: Icon(Icons.query_stats_outlined),
            selectedIcon: Icon(Icons.query_stats),
            label: 'Stats',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    // Up to three most recent finished tournaments.
    final recent = c.server.archive.reversed.take(3).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/app_logo.png', height: 40),
            const SizedBox(width: 10),
            Text('MTG Tournament', style: theme.textTheme.titleLarge),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // --- Host ---  (FR-14, FR-06)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Host a tournament',
                    style: theme.textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 6),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HostScreen()),
                    ),
                    icon: Icon(c.hasActiveEvent ? Icons.login : Icons.add),
                    label: Text(
                      c.hasActiveEvent ? 'Open current event' : 'Create event',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Recent tournaments', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            _NoRecent(theme: theme)
          else
            for (final e in recent)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RecentTournamentTile(
                  engine: e,
                  champion: c.server.championOf(e),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          TournamentDetailScreen(tournamentId: e.id),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _NoRecent extends StatelessWidget {
  final ThemeData theme;
  const _NoRecent({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(Icons.history, color: theme.colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'No finished tournaments yet. Host one and it will appear here.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentTournamentTile extends StatelessWidget {
  final TournamentEngine engine;
  final String? champion;
  final VoidCallback onTap;
  const _RecentTournamentTile({
    required this.engine,
    required this.champion,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail =
        '${formatDate(engine.createdAt)} · ${engine.entries.length} players'
        '${champion != null ? ' · 🏆 $champion' : ''}';
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.18),
          child: Icon(Icons.emoji_events, color: theme.colorScheme.primary),
        ),
        title: Text(engine.name),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
