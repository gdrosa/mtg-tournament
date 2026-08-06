import 'package:flutter/material.dart';

import '../host/host_controller.dart';
import '../server/interchange.dart';
import '../services/data_exchange.dart';
import 'app_scope.dart';

/// Import / export controls in the Profile tab.
///
/// Exports go out through the Android share sheet. Imports are **cumulative**:
/// they add players, decks, revisions and tournaments you do not have and leave
/// everything you do have alone, so bringing in a friend's event never costs you
/// your own history and re-importing the same file changes nothing.
class DataExchangeCard extends StatefulWidget {
  const DataExchangeCard({super.key});

  @override
  State<DataExchangeCard> createState() => _DataExchangeCardState();
}

class _DataExchangeCardState extends State<DataExchangeCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That did not work. Try again.')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final server = c.server;
    final owner = server.ownerPlayerId;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Data', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Share a backup, one tournament, your deck library or a '
              'spreadsheet. Importing adds to what you already have — it never '
              'replaces it.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),
                ),
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _action(
                    'Backup (everything)',
                    () => shareBundle(
                      server,
                      scope: BundleScope.full,
                      filenameHint: 'backup',
                    ),
                  ),
                  _action(
                    'My history',
                    owner == null
                        ? null
                        : () => shareBundle(
                            server,
                            scope: BundleScope.playerHistory,
                            playerId: owner,
                            filenameHint: 'history',
                          ),
                  ),
                  _action(
                    'Deck library',
                    () => shareBundle(
                      server,
                      scope: BundleScope.deckLibrary,
                      playerId: owner,
                      filenameHint: 'decks',
                    ),
                  ),
                  _action(
                    'Matches (CSV)',
                    () => shareCsv(matchesCsv(server), 'mtg-matches.csv'),
                  ),
                  _action(
                    'Players (CSV)',
                    () => shareCsv(playerSummaryCsv(server), 'mtg-players.csv'),
                  ),
                  _action('Anonymized stats', () => shareAggregate(server)),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => _run(_importFromFile),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Import from a file'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _run(_importFromClipboard),
                icon: const Icon(Icons.content_paste_outlined),
                label: const Text('Import from clipboard'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Open a bundle someone sent you, or paste one from a chat. '
                  'You see exactly what would change before anything is '
                  'applied.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _action(String label, Future<void> Function()? action) =>
      OutlinedButton(
        onPressed: action == null ? null : () => _run(action),
        child: Text(label),
      );

  Future<void> _importFromFile() async {
    final c = AppScope.of(context);
    final found = await previewFileBundle(c.server);
    if (found == null) return; // picker dismissed — not a failure
    if (!mounted) return;
    await _applyFound(c, found);
  }

  Future<void> _importFromClipboard() async {
    final c = AppScope.of(context);
    final found = await previewClipboardBundle(c.server);
    if (!mounted) return;
    await _applyFound(c, found);
  }

  Future<void> _applyFound(
    HostController c,
    ({Map<String, dynamic>? bundle, ImportPreview preview}) found,
  ) async {
    final preview = found.preview;
    final bundle = found.bundle;
    if (bundle == null || !preview.canImport) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            preview.errors.isEmpty
                ? 'Nothing to import.'
                : preview.errors.first,
          ),
        ),
      );
      return;
    }

    final identityMap = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _ImportPreviewDialog(preview: preview),
    );
    if (identityMap == null || !mounted) return;

    final result = importBundleText(c.server, bundle, identityMap: identityMap);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'Imported ${result.addedTournaments} tournament(s), '
                    '${result.addedPlayers} player(s), '
                    '${result.addedDecks} deck(s). '
                    '${result.skippedTournaments} already here.'
              : result.error ?? 'Import failed.',
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }
}

/// Shows what an import would change, and lets the organizer decide — one at a
/// time — whether an incoming player is really someone they already know. A
/// shared nickname is never enough on its own.
class _ImportPreviewDialog extends StatefulWidget {
  final ImportPreview preview;
  const _ImportPreviewDialog({required this.preview});

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  /// incoming player id → local player id the organizer confirmed.
  final Map<String, String> _merge = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.preview;
    return AlertDialog(
      title: const Text('Import this data?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (p.isNoOp)
              Text(
                'Everything in this bundle is already here. Importing it again '
                'changes nothing.',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Text('Will be added:', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('${p.newTournaments} tournament(s)'),
              Text('${p.newPlayers} player(s)'),
              Text('${p.newDecks} deck(s), ${p.newRevisions} exact list(s)'),
              if (p.duplicateTournaments > 0)
                Text('${p.duplicateTournaments} already here — skipped'),
            ],
            for (final w in p.warnings) ...[
              const SizedBox(height: 10),
              Text(w, style: theme.textTheme.bodySmall),
            ],
            if (p.identitySuggestions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Possible same person', style: theme.textTheme.titleSmall),
              Text(
                'Nothing is merged unless you tick it.',
                style: theme.textTheme.bodySmall,
              ),
              for (final s in p.identitySuggestions)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _merge[s.incomingId] == s.localId,
                  title: Text('${s.incomingNickname} → ${s.localNickname}'),
                  subtitle: Text(s.reason),
                  onChanged: (on) => setState(() {
                    if (on == true) {
                      _merge[s.incomingId] = s.localId;
                    } else {
                      _merge.remove(s.incomingId);
                    }
                  }),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, Map<String, String>.of(_merge)),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
