import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

import '../host/host_controller.dart';
import '../shared/models.dart';
import '../shared/stats.dart';
import 'app_scope.dart';
import 'card_prep.dart';
import 'deck_editor_screen.dart';

/// Decks tab — the device owner's named decks (FR-09/12) with their lifetime
/// record aggregated from real tournament history (FR-44/45). Real data only;
/// the "New deck" button registers a deck against the durable owner identity.
class DecksScreen extends StatelessWidget {
  const DecksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final ownerId = c.server.ownerPlayerId;
    final decks = ownerId == null ? <Deck>[] : c.server.decksOf(ownerId);
    final stats = c.server.stats;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text('Your decks', style: theme.textTheme.titleLarge),
        actions: [
          if (decks.isNotEmpty && c.canEditCards)
            IconButton(
              tooltip: 'Fetch all card images (for offline play)',
              icon: const Icon(Icons.cloud_download_outlined),
              onPressed: () => showImagePrepDialog(context, c),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openDeckForm(context, c),
        icon: const Icon(Icons.add),
        label: const Text('New deck'),
      ),
      body: decks.isEmpty
          ? const _EmptyDecks()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: decks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final d = decks[i];
                return _DeckCard(
                  deck: d,
                  record: stats.deckRecord(d.id),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DeckEditorScreen(deckId: d.id),
                    ),
                  ),
                  onDelete: () => _confirmDelete(context, c, d),
                );
              },
            ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    HostController c,
    Deck d,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${d.name}"?'),
        content: const Text(
          'This removes the deck and its card list from this device. '
          'Past tournament results are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (c.server.deleteDeck(d.id)) {
      await c.setDeckAvatar(d.id, null); // no orphaned picture files
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Can't delete a deck that's in the current event."),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _openDeckForm(BuildContext context, HostController c) async {
    final needsNick = c.server.owner == null;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _DeckFormScreen(
          needsNickname: needsNick,
          suggestedNick: c.server.owner?.nickname ?? '',
        ),
      ),
    );
  }
}

class _DeckCard extends StatelessWidget {
  final Deck deck;
  final Record record;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _DeckCard({
    required this.deck,
    required this.record,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final played = record.matches;
    final pct = (record.winRate * 100).round();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _DeckAvatar(deck: deck),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(deck.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      played == 0
                          ? 'No matches yet'
                          : '$record  ·  $pct% win rate',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (!deck.hasCards) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.image_outlined,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Tap to add card images',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                tooltip: 'Deck options',
                onSelected: (v) {
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline),
                      title: Text('Delete deck'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Deck profile picture: tap it to set one from the clipboard or the gallery.
/// Tapping here does not open the deck — the inner gesture wins the arena.
class _DeckAvatar extends StatelessWidget {
  final Deck deck;
  const _DeckAvatar({required this.deck});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppScope.of(context);
    final picture = c.deckAvatar(deck.id);
    return GestureDetector(
      onTap: () => _change(context, c, picture != null),
      child: Container(
        width: 44,
        height: 44,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: picture == null
            ? Icon(Icons.style, color: theme.colorScheme.primary)
            : Image.file(
                picture,
                fit: BoxFit.cover,
                cacheWidth: 132, // 44dp at 3x — never decode a full photo
                errorBuilder: (_, _, _) =>
                    Icon(Icons.style, color: theme.colorScheme.primary),
              ),
      ),
    );
  }

  Future<void> _change(
    BuildContext context,
    HostController c,
    bool hasPicture,
  ) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste copied image'),
              onTap: () => Navigator.pop(ctx, 'paste'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from device'),
              onTap: () => Navigator.pop(ctx, 'device'),
            ),
            if (hasPicture)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove picture'),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    List<int>? bytes;
    try {
      switch (choice) {
        case 'paste':
          bytes = await Pasteboard.image;
          if (bytes == null) {
            if (context.mounted) _toast(context, 'No image in the clipboard.');
            return;
          }
        case 'device':
          // maxWidth/Height downscales in the picker, so a 12MP photo never
          // reaches the device's storage as a 44px thumbnail.
          final picked = await ImagePicker().pickImage(
            source: ImageSource.gallery,
            maxWidth: 512,
            maxHeight: 512,
          );
          if (picked == null) return; // cancelled
          bytes = await picked.readAsBytes();
      }
    } catch (_) {
      if (context.mounted) _toast(context, 'Could not read that image.');
      return;
    }

    final file = c.deckAvatar(deck.id);
    await c.setDeckAvatar(deck.id, bytes);
    // Same path, new content: drop the decoded frame or the old one sticks.
    if (file != null) await FileImage(file).evict();
  }

  void _toast(BuildContext context, String message) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
}

class _EmptyDecks extends StatelessWidget {
  const _EmptyDecks();
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
              Icons.style_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('No decks yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Register a named deck to track its win rate across every '
              'tournament you play. Tap "New deck" to add one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen deck registration (mainboard + sideboard are multi-line text).
class _DeckFormScreen extends StatefulWidget {
  final bool needsNickname;
  final String suggestedNick;
  const _DeckFormScreen({
    required this.needsNickname,
    required this.suggestedNick,
  });
  @override
  State<_DeckFormScreen> createState() => _DeckFormScreenState();
}

class _DeckFormScreenState extends State<_DeckFormScreen> {
  late final nick = TextEditingController(text: widget.suggestedNick);
  final name = TextEditingController();
  final main = TextEditingController();
  final side = TextEditingController();

  @override
  void dispose() {
    for (final c in [nick, name, main, side]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New deck')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          if (widget.needsNickname) ...[
            const Text(
              'Pick the nickname your decks and stats are saved under.',
            ),
            const SizedBox(height: 12),
            _field('Your nickname', nick, hint: 'e.g. Giuseppe'),
          ],
          _field('Deck name', name, hint: 'e.g. Domain Zoo'),
          _field('Maindeck', main, lines: 5, hint: '4 Lightning Bolt\n...'),
          _field('Sideboard', side, lines: 3),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save deck')),
        ],
      ),
    );
  }

  void _save() {
    final c = AppScope.of(context);
    final nickname = nick.text.trim();
    if (name.text.trim().isEmpty) {
      _toast('Enter a deck name');
      return;
    }
    if (widget.needsNickname && nickname.isEmpty) {
      _toast('Enter a nickname');
      return;
    }
    c.registerDeck(
      nickname: nickname.isEmpty
          ? (c.server.owner?.nickname ?? 'Player')
          : nickname,
      name: name.text.trim(),
      main: main.text,
      side: side.text,
    );
    Navigator.of(context).pop();
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), duration: const Duration(seconds: 1)),
  );

  Widget _field(
    String label,
    TextEditingController ctrl, {
    String? hint,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: ctrl,
      maxLines: lines,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}
