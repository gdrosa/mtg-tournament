import 'package:flutter/material.dart';

import '../shared/deck_revision.dart';
import '../shared/stats_service.dart';
import 'app_scope.dart';
import 'format.dart';
import 'stats_widgets.dart';
import 'tournament_detail_screen.dart';

/// One deck's whole record — the logical deck, and each exact list it has been
/// through.
///
/// The revision list is the point of this screen: "Domain Zoo went 12-4" is far
/// less useful than "the version with two Fetches instead of Ephemerate went
/// 8-1, over nine matches".
class DeckProfileScreen extends StatelessWidget {
  final String deckId;
  const DeckProfileScreen({super.key, required this.deckId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final report = c.server.statistics.deckReport(deckId);
    final deck = c.server.decks[deckId];
    final name = deck?.name ?? 'Deleted deck';

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          32 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          if (deck != null && deck.archetype.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Archetype: ${deck.archetype}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          StatSection(
            title: 'Lifetime',
            children: [
              RecordBar(record: report.overall.match),
              const SizedBox(height: 8),
              RateLine(
                label: 'Match win rate',
                interval: report.overall.matchWin,
              ),
              RateLine(
                label: 'Game win rate',
                interval: report.overall.gameWin,
              ),
              SampleCaveat(sampleSize: report.overall.sampleSize),
            ],
          ),
          StatSection(
            title: 'Revisions',
            subtitle:
                'Each frozen list, oldest first, with what changed to reach it.',
            children: [
              if (report.revisions.isEmpty)
                Text(
                  'No registered lists yet. A revision is frozen the moment the '
                  'deck is entered into a tournament.',
                  style: theme.textTheme.bodySmall,
                )
              else
                for (final r in report.revisions) _RevisionTile(standing: r),
              if (report.hasMigratedHistory)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Some revisions were reconstructed when this data was '
                    'upgraded: they are the deck as it stands now, not a list '
                    'proven to be the one played.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ),
            ],
          ),
          StatSection(
            title: 'Against archetype',
            children: [
              TallyList(tallies: report.byOpponentArchetype, labelOf: (x) => x),
            ],
          ),
          StatSection(
            title: 'By format',
            children: [TallyList(tallies: report.byFormat, labelOf: (x) => x)],
          ),
          StatSection(
            title: 'Over time',
            children: [
              if (report.byMonth.isEmpty)
                Text('No matches yet', style: theme.textTheme.bodySmall)
              else
                for (final period in report.byMonth.reversed)
                  StatRow(
                    period.label,
                    '${recordLabel(period.tally.match)}  '
                    '(${rateWithSample(period.tally.matchWin)})',
                  ),
            ],
          ),
          StatSection(
            title: 'Tournament results',
            children: [
              if (report.placements.isEmpty)
                Text('No finished events yet', style: theme.textTheme.bodySmall)
              else
                for (final p in report.placements)
                  StatRow(
                    '${p.tournamentName} · ${formatDate(p.date)}',
                    '#${p.rank} of ${p.playerCount} · '
                        '${recordLabel(p.tally.match)}',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => TournamentDetailScreen(
                          tournamentId: p.tournamentId,
                        ),
                      ),
                    ),
                  ),
            ],
          ),
          StatSection(
            title: 'Matchups',
            subtitle: 'Row versus column, from the row deck\'s point of view.',
            children: [
              MatchupTable(
                rows: report.matchups.rows,
                labels: report.matchups.labels,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RevisionTile extends StatelessWidget {
  final RevisionStanding standing;
  const _RevisionTile({required this.standing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = standing.revision;
    final diff = standing.changesFromPrevious;

    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(
          'v${r.revision} · ${formatDate(r.createdAt)}'
          '${r.migrated ? ' · reconstructed' : ''}',
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          '${recordLabel(standing.tally.match)}  '
          '(${rateWithSample(standing.tally.matchWin)}) · '
          '${r.mainCount}+${r.sideCount} cards',
          style: theme.textTheme.bodySmall,
        ),
        children: [
          if (diff == null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'First registered list.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else if (diff.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Name or archetype changed; the 75 stayed the same.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else ...[
            _diffBlock(context, 'Maindeck', diff.main),
            _diffBlock(context, 'Sideboard', diff.side),
          ],
        ],
      ),
    );
  }

  Widget _diffBlock(BuildContext context, String label, BoardDiff diff) {
    final theme = Theme.of(context);
    if (diff.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          for (final e in diff.added.entries)
            Text('+ ${e.value} ${e.key}', style: theme.textTheme.bodySmall),
          for (final e in diff.removed.entries)
            Text('− ${e.value} ${e.key}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}
