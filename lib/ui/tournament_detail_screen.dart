import 'package:flutter/material.dart';

import '../host/host_controller.dart';
import '../server/interchange.dart';
import '../services/data_exchange.dart';
import 'app_scope.dart';
import 'format.dart';
import 'player_profile_screen.dart';
import 'stats_widgets.dart';

/// Read-only view of one (archived) tournament: final standings, the roster
/// with each player's named deck + decklist, and every round's results.
/// Reached from the Events tab (FR-45 "see statistics, players and so on").
class TournamentDetailScreen extends StatelessWidget {
  final String tournamentId;
  const TournamentDetailScreen({super.key, required this.tournamentId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final engine = c.server.tournamentById(tournamentId);

    if (engine == null) {
      // It was deleted while open — pop back to the list.
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This tournament was deleted.')),
      );
    }

    final d = c.server.historyDetail(engine);
    final standings = (d['standings'] as List).cast<Map>();
    final playersList = (d['players'] as List).cast<Map>();
    final rounds = (d['rounds'] as List).cast<Map>();

    return Scaffold(
      appBar: AppBar(
        title: Text(d['name'] as String),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Share this tournament',
            onSelected: (v) {
              if (v == 'bundle') {
                shareBundle(
                  c.server,
                  scope: BundleScope.tournament,
                  tournamentId: tournamentId,
                  filenameHint: 'tournament',
                );
              } else if (v == 'standings') {
                shareCsv(
                  standingsCsv(c.server, tournamentId),
                  'mtg-standings.csv',
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'bundle',
                child: Text('Share tournament (importable)'),
              ),
              PopupMenuItem(
                value: 'standings',
                child: Text('Share standings (CSV)'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Delete tournament',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, c, d['name'] as String),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          32 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          Text(
            '${formatDate(DateTime.parse(d['date'] as String))} · '
            '${_plural(d['playerCount'] as int, 'player')} · '
            '${_plural(d['roundCount'] as int, 'round')}'
            '${(d['format'] as String).isEmpty ? '' : ' · ${d['format']}'}'
            '${(d['series'] as String).isEmpty ? '' : ' · ${d['series']}'}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _TournamentStats(tournamentId: tournamentId),
          _section(context, 'Final standings'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [for (final r in standings) _standingRow(context, r)],
              ),
            ),
          ),
          const SizedBox(height: 20),
          _section(context, 'Players & decks'),
          for (final p in playersList) _PlayerTile(player: p),
          const SizedBox(height: 20),
          _section(context, 'Rounds'),
          for (final r in rounds) _roundCard(context, r),
        ],
      ),
    );
  }

  String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _standingRow(BuildContext context, Map r) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${r['rank']}',
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r['nickname']}'
                  '${r['disqualified'] == true ? ' · disqualified' : ''}',
                ),
                Text(
                  '${r['deckName']} · ${r['record']}',
                  style: theme.textTheme.bodySmall,
                ),
                // The MTR tiebreaker chain in the order it is applied.
                Text(
                  'OMW ${r['omw']}% · GW ${r['gw']}% · OGW ${r['ogw']}%',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Text(
            '${r['matchPoints']} pts',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _roundCard(BuildContext context, Map r) {
    final theme = Theme.of(context);
    final matches = (r['matches'] as List).cast<Map>();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Round ${r['number']}', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final m in matches)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        m['p2'] == null
                            ? '${m['p1']} — bye'
                            : '${m['p1']}  vs  ${m['p2']}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${m['result']}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    HostController c,
    String name,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "$name"?'),
        content: const Text(
          'This removes the tournament and its results from '
          'your history. This cannot be undone.',
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
      c.deleteArchived(tournamentId);
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}

/// Computed view of one event: what happened beyond the raw pairings.
class _TournamentStats extends StatelessWidget {
  final String tournamentId;
  const _TournamentStats({required this.tournamentId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final report = c.server.statistics.tournamentReport(
      tournamentId,
      roster: c.server.rosterOf(tournamentId),
      dropped: c.server.droppedIn(tournamentId),
    );
    if (report.roundCount == 0) return const SizedBox.shrink();

    String nick(String id) => c.server.players[id]?.nickname ?? 'Unknown';
    final conflicts = c.server.surveyConflicts(tournamentId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StatSection(
          title: 'Event summary',
          children: [
            StatRow('Rounds', '${report.roundCount}'),
            StatRow('Byes', '${report.byes}'),
            StatRow('Draws', '${report.draws}'),
            StatRow('Drops', '${report.drops}'),
            StatRow('Disputed matches', '${report.disputes}'),
            StatRow('Host-adjudicated results', '${report.adjudications}'),
          ],
        ),
        StatSection(
          title: 'Archetypes played',
          children: [
            if (report.archetypeCounts.isEmpty)
              Text('Not recorded', style: theme.textTheme.bodySmall)
            else
              for (final e
                  in (report.archetypeCounts.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value))))
                StatRow(e.key, '${e.value}'),
          ],
        ),
        StatSection(
          title: 'Rank progression',
          subtitle: 'Position after each round, in finishing order.',
          children: [
            for (final row in report.standings.take(12))
              StatRow(
                nick(row.playerId),
                (report.rankProgression[row.playerId] ?? const <int>[]).join(
                  ' → ',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlayerProfileScreen(playerId: row.playerId),
                  ),
                ),
              ),
          ],
        ),
        if (!report.matchups.isEmpty)
          StatSection(
            title: 'Matchups at this event',
            subtitle: 'One event is a very small sample — read it as such.',
            children: [
              MatchupTable(
                rows: report.matchups.rows,
                labels: report.matchups.labels,
              ),
            ],
          ),
        if (conflicts.isNotEmpty)
          StatSection(
            title: 'Questionnaire conflicts',
            subtitle:
                'Where the two players\' own reports disagree. Kept as-is — '
                'the confirmed result already stands and is unaffected.',
            children: [
              for (final entry in conflicts)
                for (final conflict in entry.conflicts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${entry.matchId}: ${conflict.detail}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
            ],
          ),
      ],
    );
  }
}

class _PlayerTile extends StatelessWidget {
  final Map player;
  const _PlayerTile({required this.player});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final main = (player['main'] as String).trim();
    final side = (player['side'] as String).trim();
    final hasList = main.isNotEmpty || side.isNotEmpty;
    final dropped = player['dropped'] == true;

    final header = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${player['nickname']}${dropped ? ' (dropped)' : ''}',
                style: theme.textTheme.titleSmall,
              ),
              Text(
                '${player['deckName']} · ${player['record']}'
                // Be honest about lists we reconstructed rather than froze.
                '${player['listIsReconstructed'] == true ? ' · list reconstructed' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );

    if (!hasList) {
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(padding: const EdgeInsets.all(14), child: header),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Theme(
        // Remove the divider line ExpansionTile draws by default.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          title: header,
          children: [
            if (main.isNotEmpty) _deckBlock(context, 'Maindeck', main),
            if (side.isNotEmpty) _deckBlock(context, 'Sideboard', side),
          ],
        ),
      ),
    );
  }

  Widget _deckBlock(BuildContext context, String label, String body) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(body, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
      ],
    );
  }
}
