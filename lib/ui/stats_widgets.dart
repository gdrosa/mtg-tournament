/// Presentation-only pieces shared by the statistics screens.
///
/// These widgets *render* numbers that `stats_service.dart` already computed —
/// none of them aggregates anything. The one piece of judgement they carry is
/// how to show uncertainty: every rate is drawn with its sample size, and a
/// small sample is labelled as one instead of being dressed up as a finding.
library;

import 'package:flutter/material.dart';

import '../shared/stats_facts.dart';

/// "54%" — a rate as a whole percentage.
String percent(double value) => '${(value * 100).round()}%';

/// "54% · n=37" — never a rate without the sample behind it.
String rateWithSample(ConfidenceInterval ci) =>
    ci.n == 0 ? '—' : '${percent(ci.point)} · n=${ci.n}';

/// "95% CI 38–70%" — how much that number could still move.
String intervalLabel(ConfidenceInterval ci) =>
    ci.n == 0 ? 'no data yet' : '95% CI ${percent(ci.low)}–${percent(ci.high)}';

/// "12–4–1"
String recordLabel(Record r) =>
    '${r.wins}–${r.losses}${r.draws > 0 ? '–${r.draws}' : ''}';

/// A rate with its interval and an explicit small-sample caveat.
class RateLine extends StatelessWidget {
  final String label;
  final ConfidenceInterval interval;
  const RateLine({super.key, required this.label, required this.interval});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: theme.textTheme.bodyMedium),
              Text(
                rateWithSample(interval),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (interval.n > 0)
            Text(
              interval.reliable
                  ? intervalLabel(interval)
                  : '${intervalLabel(interval)} · too few matches to rely on',
              style: theme.textTheme.bodySmall?.copyWith(
                color: interval.reliable
                    ? theme.textTheme.bodySmall?.color
                    : theme.colorScheme.tertiary,
              ),
            ),
        ],
      ),
    );
  }
}

/// The standing caveat every aggregate screen carries.
class SampleCaveat extends StatelessWidget {
  final int sampleSize;
  const SampleCaveat({super.key, required this.sampleSize});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thin = sampleSize < kReliableSample;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            thin ? Icons.info_outline : Icons.query_stats,
            size: 16,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              thin
                  ? 'Based on $sampleSize matches — treat these as hints, not '
                        'conclusions.'
                  : 'Based on $sampleSize matches. These are associations, not '
                        'causes.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled card wrapping a block of rows.
class StatSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? trailing;
  const StatSection({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                ?trailing,
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A big number with a caption.
class StatValue extends StatelessWidget {
  final String value;
  final String label;
  const StatValue({super.key, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
        child: Column(
          children: [
            Text(
              value,
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

/// Label / value line.
class StatRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;
  const StatRow(this.label, this.value, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (onTap != null)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.chevron_right, size: 18),
            ),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// Win / loss / draw as a proportional bar, with the counts spelled out.
class RecordBar extends StatelessWidget {
  final Record record;
  const RecordBar({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = record.matches;
    if (total == 0) {
      return Text('No matches yet', style: theme.textTheme.bodySmall);
    }
    Widget seg(int n, Color color) => Expanded(
      flex: n,
      child: Container(height: 8, color: color),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              if (record.wins > 0) seg(record.wins, theme.colorScheme.primary),
              if (record.draws > 0)
                seg(record.draws, theme.colorScheme.outlineVariant),
              if (record.losses > 0)
                seg(record.losses, theme.colorScheme.error),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${record.wins}W · ${record.losses}L'
          '${record.draws > 0 ? ' · ${record.draws}D' : ''}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Recent results as coloured chips, newest first.
class FormStrip extends StatelessWidget {
  final List<Outcome> form;
  const FormStrip({super.key, required this.form});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (form.isEmpty) {
      return Text('No matches yet', style: theme.textTheme.bodySmall);
    }
    Color colorOf(Outcome o) => switch (o) {
      Outcome.win => theme.colorScheme.primary,
      Outcome.loss => theme.colorScheme.error,
      Outcome.draw => theme.colorScheme.outline,
    };
    String letterOf(Outcome o) => switch (o) {
      Outcome.win => 'W',
      Outcome.loss => 'L',
      Outcome.draw => 'D',
    };
    return Wrap(
      spacing: 6,
      children: [
        for (final o in form)
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colorOf(o).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              letterOf(o),
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorOf(o),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

/// A list of "name → record + rate" rows, sorted by sample size so the
/// best-evidenced lines are on top rather than the flukiest 1-0.
class TallyList extends StatelessWidget {
  final Map<String, Tally> tallies;
  final String Function(String key) labelOf;
  final void Function(String key)? onTap;
  final int max;
  const TallyList({
    super.key,
    required this.tallies,
    required this.labelOf,
    this.onTap,
    this.max = 12,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (tallies.isEmpty) {
      return Text('Nothing recorded yet', style: theme.textTheme.bodySmall);
    }
    final keys = tallies.keys.toList()
      ..sort((a, b) {
        final byN = tallies[b]!.sampleSize.compareTo(tallies[a]!.sampleSize);
        return byN != 0 ? byN : labelOf(a).compareTo(labelOf(b));
      });
    return Column(
      children: [
        for (final key in keys.take(max))
          StatRow(
            labelOf(key),
            '${recordLabel(tallies[key]!.match)}  '
            '(${rateWithSample(tallies[key]!.matchWin)})',
            onTap: onTap == null ? null : () => onTap!(key),
          ),
        if (keys.length > max)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '+ ${keys.length - max} more',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// Archetype-vs-archetype grid. Horizontally scrollable — a matchup table is
/// wide by nature and squeezing it makes it unreadable.
class MatchupTable extends StatelessWidget {
  final Map<String, Map<String, Tally>> rows;
  final List<String> labels;
  final int max;
  const MatchupTable({
    super.key,
    required this.rows,
    required this.labels,
    this.max = 8,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (labels.isEmpty) {
      return Text('No matchups recorded yet', style: theme.textTheme.bodySmall);
    }
    final shown = labels.take(max).toList();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 34,
        dataRowMaxHeight: 46,
        columnSpacing: 18,
        columns: [
          const DataColumn(label: Text('vs')),
          for (final l in shown)
            DataColumn(
              label: SizedBox(
                width: 68,
                child: Text(
                  l,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
        ],
        rows: [
          for (final row in shown)
            DataRow(
              cells: [
                DataCell(
                  SizedBox(
                    width: 110,
                    child: Text(
                      row,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                ),
                for (final col in shown)
                  DataCell(
                    Builder(
                      builder: (_) {
                        final cell = rows[row]?[col];
                        if (cell == null || cell.sampleSize == 0) {
                          return Text('—', style: theme.textTheme.bodySmall);
                        }
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              recordLabel(cell.match),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'n=${cell.sampleSize}',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
