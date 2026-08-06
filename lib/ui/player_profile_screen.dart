import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'deck_profile_screen.dart';
import 'format.dart';
import 'stats_widgets.dart';
import 'tournament_detail_screen.dart';

/// Everything history knows about one durable player identity.
///
/// The identity is the stable player id, never the nickname — two people who
/// have both called themselves "Mike" stay two people here.
class PlayerProfileScreen extends StatelessWidget {
  final String playerId;
  const PlayerProfileScreen({super.key, required this.playerId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final service = c.server.statistics;
    final report = service.playerReport(playerId);
    final nickname = c.server.players[playerId]?.nickname ?? 'Unknown player';
    final aliases = c.server.playerAliases[playerId] ?? const <String>[];

    String nick(String id) => c.server.players[id]?.nickname ?? 'Unknown';
    String deckName(String id) => c.server.decks[id]?.name ?? 'Deleted deck';

    return Scaffold(
      appBar: AppBar(title: Text(nickname)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          32 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          if (aliases.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Also played as ${aliases.join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: StatValue(
                  value: '${report.tournamentsPlayed}',
                  label: 'Tournaments',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatValue(
                  value: '${report.tournamentsWon}',
                  label: 'Won',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatValue(
                  value: report.averageFinish == null
                      ? '—'
                      : report.averageFinish!.toStringAsFixed(1),
                  label: 'Avg finish',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          StatSection(
            title: 'Record',
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
              StatRow('Games', '${report.overall.game.matches}'),
              StatRow('Byes received', '${report.overall.byes}'),
              StatRow(
                'Disputed / adjudicated',
                '${report.overall.disputed} / ${report.overall.adjudicated}',
              ),
              SampleCaveat(sampleSize: report.overall.sampleSize),
            ],
          ),
          StatSection(
            title: 'Recent form',
            subtitle:
                'Newest first; byes are left out because they say nothing.',
            children: [
              FormStrip(form: report.recentForm),
              const SizedBox(height: 10),
              StatRow('Current streak', report.currentStreak.toString()),
              StatRow(
                'Longest win streak',
                '${report.longestWinStreak.length}',
              ),
            ],
          ),
          StatSection(
            title: 'Rating history (Glicko-2)',
            subtitle:
                'One rating period per tournament. "±" narrows as they play '
                'more; it never claims certainty it has not earned.',
            children: [
              if (report.ratingHistory.isEmpty)
                Text('No rated matches yet.', style: theme.textTheme.bodySmall)
              else
                for (var i = report.ratingHistory.length - 1; i >= 0; i--)
                  Builder(
                    builder: (_) {
                      final point = report.ratingHistory[i];
                      final previous = i == 0
                          ? null
                          : report.ratingHistory[i - 1];
                      final delta = point.deltaFrom(previous);
                      return StatRow(
                        '${point.tournamentName} · ${formatDate(point.date)}',
                        '${point.rating.rating.round()} '
                            '(${delta >= 0 ? '+' : ''}${delta.round()}) '
                            '± ${point.rating.confidence95.round()}',
                      );
                    },
                  ),
            ],
          ),
          StatSection(
            title: 'By deck',
            children: [
              TallyList(
                tallies: report.byDeck,
                labelOf: deckName,
                onTap: (id) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DeckProfileScreen(deckId: id),
                  ),
                ),
              ),
            ],
          ),
          StatSection(
            title: 'By archetype',
            children: [
              TallyList(tallies: report.byArchetype, labelOf: (x) => x),
            ],
          ),
          StatSection(
            title: 'By format',
            children: [TallyList(tallies: report.byFormat, labelOf: (x) => x)],
          ),
          StatSection(
            title: 'Head to head',
            subtitle: 'Their record against each opponent they have faced.',
            children: [
              TallyList(
                tallies: report.byOpponent,
                labelOf: nick,
                onTap: (id) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlayerProfileScreen(playerId: id),
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
            title: 'Over time',
            subtitle: 'Calendar months in which they played.',
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
        ],
      ),
    );
  }
}
