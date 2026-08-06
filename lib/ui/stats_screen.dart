import 'package:flutter/material.dart';

import '../shared/stats_facts.dart';
import '../shared/stats_service.dart';
import 'app_scope.dart';
import 'deck_profile_screen.dart';
import 'format.dart';
import 'player_profile_screen.dart';
import 'stats_widgets.dart';
import 'tournament_detail_screen.dart';

/// Statistics tab: one filter applied across players, decks, archetypes and
/// events.
///
/// Everything shown here comes out of [StatsService] as plain data — this file
/// only lays it out. ponytail: the service is rebuilt on each frame rather than
/// cached; a club's whole history is a few thousand matches and folding it is
/// microseconds. Cache it behind the controller if a device ever says otherwise.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  StatFilter _filter = const StatFilter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final service = c.server.statistics;
    final facts = service.where(_filter);
    final owner = c.server.ownerPlayerId;

    String nick(String id) => c.server.players[id]?.nickname ?? 'Unknown';
    String deckName(String id) => c.server.decks[id]?.name ?? 'Deleted deck';

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text('Statistics', style: theme.textTheme.titleLarge),
        actions: [
          if (!_filter.isEmpty)
            TextButton(
              onPressed: () => setState(() => _filter = const StatFilter()),
              child: const Text('Clear'),
            ),
        ],
      ),
      body: service.facts.isEmpty
          ? const _NoData()
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                24 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                _FilterBar(
                  filter: _filter,
                  service: service,
                  nicknameOf: nick,
                  deckNameOf: deckName,
                  onChanged: (f) => setState(() => _filter = f),
                ),
                const SizedBox(height: 12),
                _Overview(facts: facts),
                if (facts.isEmpty)
                  StatSection(
                    title: 'Nothing matches this filter',
                    children: [
                      Text(
                        'Widen the date range or clear a filter to see results.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  )
                else ...[
                  _RatingsSection(service: service, nicknameOf: nick),
                  _PlayersSection(
                    facts: facts,
                    nicknameOf: nick,
                    highlight: owner,
                  ),
                  _DecksSection(facts: facts, deckNameOf: deckName),
                  StatSection(
                    title: 'Archetype matchups',
                    subtitle:
                        'Row versus column, from the row deck\'s point of view. '
                        'A cell with a tiny n says almost nothing.',
                    children: [
                      Builder(
                        builder: (_) {
                          final m = MatchupMatrix.from(facts);
                          return MatchupTable(rows: m.rows, labels: m.labels);
                        },
                      ),
                    ],
                  ),
                  _TournamentsSection(facts: facts),
                ],
              ],
            ),
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        Icon(Icons.query_stats, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'No results yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Host or import a tournament and every statistic here fills in from '
          'the real matches played.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _Overview extends StatelessWidget {
  final List<MatchFact> facts;
  const _Overview({required this.facts});

  @override
  Widget build(BuildContext context) {
    final tournaments = facts.map((f) => f.tournamentId).toSet().length;
    final players = <String>{};
    for (final f in facts) {
      players.add(f.p1.playerId);
      if (f.p2 != null) players.add(f.p2!.playerId);
    }
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatValue(value: '$tournaments', label: 'Tournaments'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatValue(value: '${facts.length}', label: 'Matches'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatValue(value: '${players.length}', label: 'Players'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SampleCaveat(sampleSize: facts.length),
        const SizedBox(height: 10),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  final StatFilter filter;
  final StatsService service;
  final String Function(String) nicknameOf;
  final String Function(String) deckNameOf;
  final ValueChanged<StatFilter> onChanged;

  const _FilterBar({
    required this.filter,
    required this.service,
    required this.nicknameOf,
    required this.deckNameOf,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final deckIds = <String>{};
    for (final f in service.facts) {
      if (f.p1.deckId.isNotEmpty) deckIds.add(f.p1.deckId);
      if (f.p2?.deckId.isNotEmpty ?? false) deckIds.add(f.p2!.deckId);
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip(
          context,
          label: 'Date',
          value: filter.from == null && filter.to == null
              ? null
              : '${filter.from == null ? '…' : formatDate(filter.from!)} – '
                    '${filter.to == null ? '…' : formatDate(filter.to!)}',
          onTap: () async {
            final range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2000),
              lastDate: DateTime.now().add(const Duration(days: 1)),
            );
            if (range != null) {
              onChanged(
                filter.copyWith(
                  from: range.start,
                  // Include the whole end day, not midnight on it.
                  to: DateTime(
                    range.end.year,
                    range.end.month,
                    range.end.day,
                    23,
                    59,
                    59,
                  ),
                ),
              );
            }
          },
          onClear: filter.from == null && filter.to == null
              ? null
              : () => onChanged(filter.copyWith(from: null, to: null)),
        ),
        _pickerChip(
          context,
          label: 'Format',
          value: filter.format,
          options: service.formats,
          display: (x) => x,
          onPick: (v) => onChanged(filter.copyWith(format: v)),
        ),
        _pickerChip(
          context,
          label: 'Series',
          value: filter.series,
          options: service.seriesNames,
          display: (x) => x,
          onPick: (v) => onChanged(filter.copyWith(series: v)),
        ),
        _pickerChip(
          context,
          label: 'Tournament',
          value: filter.tournamentId,
          options: [for (final t in service.tournaments) t.id],
          display: (id) =>
              service.tournaments.firstWhere((t) => t.id == id).name,
          onPick: (v) => onChanged(filter.copyWith(tournamentId: v)),
        ),
        _pickerChip(
          context,
          label: 'Player',
          value: filter.playerId,
          options: service.playerIds,
          display: nicknameOf,
          onPick: (v) => onChanged(filter.copyWith(playerId: v)),
        ),
        _pickerChip(
          context,
          label: 'Opponent',
          value: filter.opponentId,
          options: service.playerIds,
          display: nicknameOf,
          onPick: (v) => onChanged(filter.copyWith(opponentId: v)),
        ),
        _pickerChip(
          context,
          label: 'Deck',
          value: filter.deckId,
          options: deckIds.toList()..sort(),
          display: deckNameOf,
          onPick: (v) => onChanged(filter.copyWith(deckId: v)),
        ),
        _pickerChip(
          context,
          label: 'Archetype',
          value: filter.archetype,
          options: service.archetypes,
          display: (x) => x,
          onPick: (v) => onChanged(filter.copyWith(archetype: v)),
        ),
        FilterChip(
          label: const Text('Include byes'),
          selected: filter.includeByes,
          onSelected: (v) => onChanged(filter.copyWith(includeByes: v)),
        ),
      ],
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required String? value,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) => InputChip(
    label: Text(value == null ? label : '$label: $value'),
    selected: value != null,
    onPressed: onTap,
    onDeleted: onClear,
  );

  Widget _pickerChip(
    BuildContext context, {
    required String label,
    required String? value,
    required List<String> options,
    required String Function(String) display,
    required ValueChanged<String?> onPick,
  }) => _chip(
    context,
    label: label,
    value: value == null ? null : display(value),
    onTap: () async {
      final picked = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final o in options)
                ListTile(
                  title: Text(display(o)),
                  selected: o == value,
                  onTap: () => Navigator.pop(ctx, o),
                ),
              if (options.isEmpty)
                const ListTile(title: Text('Nothing to choose from yet')),
            ],
          ),
        ),
      );
      if (picked != null) onPick(picked);
    },
    onClear: value == null ? null : () => onPick(null),
  );
}

class _RatingsSection extends StatelessWidget {
  final StatsService service;
  final String Function(String) nicknameOf;
  const _RatingsSection({required this.service, required this.nicknameOf});

  @override
  Widget build(BuildContext context) {
    final board = service.leaderboard();
    if (board.isEmpty) return const SizedBox.shrink();
    return StatSection(
      title: 'Ratings (Glicko-2)',
      subtitle:
          'Ranked conservatively, so a player with two matches does not outrank '
          'one with forty. "±" is how uncertain the rating still is.',
      children: [
        for (final row in board.take(10))
          StatRow(
            nicknameOf(row.playerId),
            '${row.rating.rating.round()} ± ${row.rating.confidence95.round()}'
            '${row.rating.established ? '' : ' (provisional)'}',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlayerProfileScreen(playerId: row.playerId),
              ),
            ),
          ),
      ],
    );
  }
}

class _PlayersSection extends StatelessWidget {
  final List<MatchFact> facts;
  final String Function(String) nicknameOf;
  final String? highlight;
  const _PlayersSection({
    required this.facts,
    required this.nicknameOf,
    this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    final tallies = <String, Tally>{};
    for (final f in facts) {
      for (final side in [f.p1, if (f.p2 != null) f.p2!]) {
        tallies.putIfAbsent(side.playerId, Tally.new).add(f, side.playerId);
      }
    }
    return StatSection(
      title: 'Players',
      subtitle: 'Match record and win rate under the current filter.',
      children: [
        TallyList(
          tallies: tallies,
          labelOf: nicknameOf,
          onTap: (id) => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlayerProfileScreen(playerId: id),
            ),
          ),
        ),
      ],
    );
  }
}

class _DecksSection extends StatelessWidget {
  final List<MatchFact> facts;
  final String Function(String) deckNameOf;
  const _DecksSection({required this.facts, required this.deckNameOf});

  @override
  Widget build(BuildContext context) {
    final tallies = <String, Tally>{};
    for (final f in facts) {
      for (final side in [f.p1, if (f.p2 != null) f.p2!]) {
        if (side.deckId.isEmpty) continue;
        tallies.putIfAbsent(side.deckId, Tally.new).add(f, side.playerId);
      }
    }
    return StatSection(
      title: 'Decks',
      children: [
        TallyList(
          tallies: tallies,
          labelOf: deckNameOf,
          onTap: (id) => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DeckProfileScreen(deckId: id)),
          ),
        ),
      ],
    );
  }
}

class _TournamentsSection extends StatelessWidget {
  final List<MatchFact> facts;
  const _TournamentsSection({required this.facts});

  @override
  Widget build(BuildContext context) {
    final seen = <String, MatchFact>{};
    for (final f in facts) {
      seen[f.tournamentId] ??= f;
    }
    final rows = seen.values.toList()..sort((a, b) => b.date.compareTo(a.date));
    return StatSection(
      title: 'Tournaments',
      children: [
        for (final f in rows.take(20))
          StatRow(
            f.tournamentName,
            '${formatDate(f.date)}'
            '${f.format.isEmpty ? '' : ' · ${f.format}'}',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    TournamentDetailScreen(tournamentId: f.tournamentId),
              ),
            ),
          ),
      ],
    );
  }
}
