import 'package:flutter/material.dart';

import '../server/controller.dart';
import '../shared/hosting.dart';
import '../shared/models.dart';
import '../shared/tournament_engine.dart';
import 'app_scope.dart';
import 'format.dart';
import 'host_screen.dart';
import 'tournament_detail_screen.dart';

/// Events tab — the tournament history (FR-43/44/45): every past event with its
/// date, size and champion, plus the active event. Tap to open standings,
/// players and decklists; swipe/menu to delete. Backed by the durable archive
/// in the shared controller — no sample data.
class EventsScreen extends StatelessWidget {
  const EventsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final active = c.server.engine; // live or lobby event (if any)
    // Newest archived first.
    final past = c.server.archive.reversed.toList();

    final children = <Widget>[];

    if (active != null) {
      children.add(
        _ActiveEventCard(
          engine: active,
          joinCode: c.server.joinCode,
          connectionLabel: '${c.hostingMode.label} · ${c.hostingStatusLabel}',
          onOpen: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const HostScreen())),
        ),
      );
    }

    if (past.isEmpty && active == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text('Tournaments', style: theme.textTheme.titleLarge),
        ),
        body: const _EmptyEvents(),
      );
    }

    if (past.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Text('History', style: theme.textTheme.titleMedium),
        ),
      );
      for (final e in past) {
        children.add(
          _PastEventCard(
            engine: e,
            subtitle: _pastSubtitle(c.server, e),
            onOpen: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TournamentDetailScreen(tournamentId: e.id),
              ),
            ),
            onDelete: () => _confirmDelete(context, e),
          ),
        );
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text('Tournaments', style: theme.textTheme.titleLarge),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: children,
      ),
    );
  }

  String _pastSubtitle(ServerController server, TournamentEngine e) {
    final champ = server.championOf(e);
    final players = e.entries.length;
    final when = formatDate(e.createdAt);
    return champ == null
        ? '$when · $players players'
        : '$when · $players players · 🏆 $champ';
  }

  Future<void> _confirmDelete(BuildContext context, TournamentEngine e) async {
    final c = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${e.name}"?'),
        content: const Text(
          'This removes the tournament and its results from '
          'your history. Deck win-rates that included it will update. This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      c.deleteArchived(e.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted "${e.name}"'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    }
  }
}

class _ActiveEventCard extends StatelessWidget {
  final TournamentEngine engine;
  final String? joinCode;
  final String connectionLabel;
  final VoidCallback onOpen;
  const _ActiveEventCard({
    required this.engine,
    required this.joinCode,
    required this.connectionLabel,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = engine.status == TournamentStatus.running;
    final label = switch (engine.status) {
      TournamentStatus.lobby => 'Lobby',
      TournamentStatus.running => 'Live',
      TournamentStatus.finished => 'Finished',
    };
    return Card(
      color: theme.colorScheme.primary.withValues(alpha: 0.12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary,
          child: Icon(
            running ? Icons.play_arrow : Icons.meeting_room,
            color: theme.colorScheme.onPrimary,
          ),
        ),
        title: Text(
          engine.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          running
              ? '$connectionLabel · Round ${engine.rounds.length} of ${engine.plannedRounds} · ${engine.entries.length} players'
              : '$connectionLabel · Players joining${joinCode != null ? ' · code $joinCode' : ''}',
        ),
        trailing: Chip(
          label: Text(label),
          visualDensity: VisualDensity.compact,
        ),
        onTap: onOpen,
      ),
    );
  }
}

class _PastEventCard extends StatelessWidget {
  final TournamentEngine engine;
  final String subtitle;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  const _PastEventCard({
    required this.engine,
    required this.subtitle,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.18),
          child: Icon(Icons.emoji_events, color: theme.colorScheme.primary),
        ),
        title: Text(engine.name),
        subtitle: Text(subtitle),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'open') onOpen();
            if (v == 'delete') onDelete();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'open', child: Text('Open')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
        onTap: onOpen,
      ),
    );
  }
}

class _EmptyEvents extends StatelessWidget {
  const _EmptyEvents();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.emoji_events_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('No tournaments yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Host an event from the Home tab. When it finishes it lands here '
              'with full standings, decklists and statistics.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
