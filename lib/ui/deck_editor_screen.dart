import 'dart:async';

import 'package:flutter/material.dart';

import '../host/host_controller.dart';
import '../shared/cards.dart';
import '../shared/models.dart';
import 'app_scope.dart';

/// Card-format deck editor / viewer.
///
/// - Edit mode: see the deck as card images grouped by type (main + sideboard),
///   add cards via Scryfall search (image downloaded + cached with a progress
///   bar), and move/remove cards by drag-and-drop or the per-card menu.
/// - Read-only mode ([readOnly] = true): the same card grid with no controls —
///   used for the post-match opponent-deck confirmation.
class DeckEditorScreen extends StatefulWidget {
  final String deckId;
  final bool readOnly;
  final String? titleOverride;
  const DeckEditorScreen({
    super.key,
    required this.deckId,
    this.readOnly = false,
    this.titleOverride,
  });

  @override
  State<DeckEditorScreen> createState() => _DeckEditorScreenState();
}

class _DragData {
  final String cardId;
  final bool fromSide;
  const _DragData(this.cardId, this.fromSide);
}

class _DeckEditorScreenState extends State<DeckEditorScreen> {
  late HostController c;
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<String> _suggest = const [];
  bool _searching = false;

  // download progress (resolve-from-text / add)
  bool _busy = false;
  String _busyLabel = '';
  int _done = 0, _total = 0;

  // true while a card is being long-press-dragged → reveal the floating trash.
  bool _dragging = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    c = AppScope.of(context);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Deck? get _deck => c.server.decks[widget.deckId];

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
  );

  // ---- mutations (each persists via setDeckCards) ----

  void _commit(List<DeckCardEntry> main, List<DeckCardEntry> side) {
    main.removeWhere((e) => e.qty <= 0);
    side.removeWhere((e) => e.qty <= 0);
    c.server.setDeckCards(deckId: widget.deckId, main: main, side: side);
    setState(() {});
  }

  List<DeckCardEntry> _copy(List<DeckCardEntry> src) => [
    for (final e in src) DeckCardEntry(e.cardId, e.qty),
  ];

  void _bump(String cardId, bool side, int delta) {
    final d = _deck;
    if (d == null) return;
    final main = _copy(d.mainCards), sideL = _copy(d.sideCards);
    final list = side ? sideL : main;
    final i = list.indexWhere((e) => e.cardId == cardId);
    if (i >= 0) {
      list[i] = list[i].copyWith(qty: list[i].qty + delta);
    } else if (delta > 0) {
      list.add(DeckCardEntry(cardId, delta));
    }
    _commit(main, sideL);
  }

  void _move(String cardId, {required bool toSide}) {
    final d = _deck;
    if (d == null) return;
    final main = _copy(d.mainCards), side = _copy(d.sideCards);
    final from = toSide ? main : side;
    final to = toSide ? side : main;
    final i = from.indexWhere((e) => e.cardId == cardId);
    if (i < 0) return;
    from[i] = from[i].copyWith(qty: from[i].qty - 1);
    final j = to.indexWhere((e) => e.cardId == cardId);
    if (j >= 0) {
      to[j] = to[j].copyWith(qty: to[j].qty + 1);
    } else {
      to.add(DeckCardEntry(cardId, 1));
    }
    _commit(main, side);
  }

  void _removeAll(String cardId, bool side) {
    final d = _deck;
    if (d == null) return;
    final main = _copy(d.mainCards), sideL = _copy(d.sideCards);
    (side ? sideL : main).removeWhere((e) => e.cardId == cardId);
    _commit(main, sideL);
  }

  // ---- add via Scryfall search ----

  int _searchGeneration = 0;

  void _onSearchChanged(String q) {
    final generation = ++_searchGeneration;
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _suggest = const [];
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _searching = true);
      List<String> res;
      try {
        res = await c.autocompleteCards(q);
      } catch (_) {
        res = const [];
      }
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _suggest = res.take(12).toList();
        _searching = false;
      });
    });
  }

  Future<void> _addCard(String name) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _busyLabel = 'Downloading $name…';
      _done = 0;
      _total = 1;
      _suggest = const [];
      _searchCtrl.clear();
    });
    CardInfo? info;
    try {
      info = await c.resolveAndCacheCard(name);
    } catch (_) {
      info = null; // offline / DNS failure
    }
    // Gate both the state mutation and the rebuild on mounted: the await above is
    // a real network round-trip the user can navigate away from mid-flight.
    if (mounted) {
      if (info != null) _bump(info.id, false, 1);
      setState(() => _busy = false);
      if (info == null) _toast('Not found (or offline): $name');
    }
  }

  /// Resolve the deck's text list against Scryfall, caching images. Also used as
  /// a retry: re-running fills in any cards/images that failed earlier (already
  /// cached cards resolve instantly from the catalog, no network). The original
  /// typed list is preserved on any failure, so nothing is lost offline.
  Future<void> _syncFromScryfall() async {
    setState(() {
      _busy = true;
      _busyLabel = 'Fetching card images…';
      _done = 0;
      _total = 0;
    });
    final r = await c.resolveDeckFromText(
      widget.deckId,
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            _done = done;
            _total = total;
          });
        }
      },
    );
    if (mounted) {
      setState(() => _busy = false);
      if (r.failed > 0) {
        _toast(
          r.resolved > 0
              ? 'Fetched ${r.resolved} cards · ${r.failed} need internet — tap ↻ to retry'
              : "Couldn't reach Scryfall. Connect to the internet and retry.",
        );
      } else if (r.resolved > 0) {
        _toast('Card images ready · ${r.resolved} cards.');
      }
    }
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _deck;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Deck not found.')),
      );
    }
    final editable = !widget.readOnly && c.canEditCards;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.titleOverride ?? d.name),
        actions: [
          if (editable &&
              (d.hasCards ||
                  d.mainboardText.trim().isNotEmpty ||
                  d.sideboardText.trim().isNotEmpty))
            IconButton(
              tooltip: 'Re-fetch images from Scryfall',
              icon: const Icon(Icons.cloud_sync_outlined),
              onPressed: _busy ? null : _syncFromScryfall,
            ),
          if (widget.readOnly)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                label: const Text('Read-only'),
                visualDensity: VisualDensity.compact,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_busy) _progressBar(theme),
              if (editable) _searchField(theme),
              Expanded(child: _content(theme, d, editable)),
            ],
          ),
          // Floating trash: only catches pointers (and is only visible) while a
          // card is being dragged, so it's reachable without scrolling.
          if (editable)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24 + MediaQuery.viewPaddingOf(context).bottom,
              child: IgnorePointer(
                ignoring: !_dragging,
                child: AnimatedOpacity(
                  opacity: _dragging ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Center(child: _floatingTrash(theme)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _progressBar(ThemeData theme) {
    final value = _total > 0 ? _done / _total : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _total > 0 ? '$_busyLabel  ($_done/$_total)' : _busyLabel,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: value, minHeight: 6),
          ),
        ],
      ),
    );
  }

  Widget _searchField(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          TextField(
            controller: _searchCtrl,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Add a card — search Scryfall',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
              isDense: true,
            ),
          ),
          if (_suggest.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(top: 4),
              child: Column(
                children: [
                  for (final name in _suggest)
                    ListTile(
                      dense: true,
                      title: Text(name),
                      trailing: const Icon(Icons.add, size: 18),
                      onTap: () => _addCard(name),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _content(ThemeData theme, Deck d, bool editable) {
    // Legacy text-only deck: offer to build the card view.
    if (!d.hasCards) {
      final hasText =
          d.mainboardText.trim().isNotEmpty ||
          d.sideboardText.trim().isNotEmpty;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_outlined,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                hasText ? 'No card images yet' : 'This deck is empty',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                hasText
                    ? 'Fetch images from Scryfall to view this list in card format. '
                          'Needs internet now; images are cached for offline play.'
                    : editable
                    ? 'Use the search box above to add cards.'
                    : 'Nothing to show.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (hasText && editable) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _syncFromScryfall,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('Fetch card images'),
                ),
              ],
              if (hasText) ...[
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Maindeck', style: theme.textTheme.labelLarge),
                ),
                const SizedBox(height: 4),
                Text(d.mainboardText, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        32 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        _board(theme, d, side: false, editable: editable),
        const SizedBox(height: 16),
        _board(theme, d, side: true, editable: editable),
      ],
    );
  }

  Widget _board(
    ThemeData theme,
    Deck d, {
    required bool side,
    required bool editable,
  }) {
    final entries = side ? d.sideCards : d.mainCards;
    final count = deckCount(entries);
    final header = Row(
      children: [
        Text(
          side ? 'Sideboard' : 'Maindeck',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(width: 8),
        Text('$count cards', style: theme.textTheme.bodySmall),
      ],
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final cat in CardCategory.values)
          ..._categorySection(theme, entries, cat, side),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              side ? 'No sideboard cards' : 'No maindeck cards',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );

    if (!editable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [header, const SizedBox(height: 8), body],
      );
    }
    // The whole board is a drop target: dropping a card here moves it to this board.
    return DragTarget<_DragData>(
      onWillAcceptWithDetails: (d) => d.data.fromSide != side,
      onAcceptWithDetails: (det) => _move(det.data.cardId, toSide: side),
      builder: (context, candidate, _) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: candidate.isNotEmpty
                ? theme.colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [header, const SizedBox(height: 8), body],
        ),
      ),
    );
  }

  List<Widget> _categorySection(
    ThemeData theme,
    List<DeckCardEntry> entries,
    CardCategory cat,
    bool side,
  ) {
    final inCat = [
      for (final e in entries)
        if ((c.server.card(e.cardId)?.category ?? CardCategory.other) == cat) e,
    ];
    if (inCat.isEmpty) return const [];
    final n = deckCount(inCat);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
        child: Text(
          '${cat.label} ($n)',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [for (final e in inCat) _cardTile(theme, e, side)],
      ),
    ];
  }

  Widget _cardTile(ThemeData theme, DeckCardEntry e, bool side) {
    final info = c.server.card(e.cardId);
    final name = info?.name ?? '?';
    const w = 104.0, h = 145.0;
    final tile = SizedBox(
      width: w,
      height: h,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _cardImage(e.cardId, name, w, h),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '×${e.qty}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // Double-tap zooms the card full-screen (read its text) in every mode,
    // including the read-only opponent-deck view shown during a tournament.
    if (widget.readOnly || !c.canEditCards) {
      return GestureDetector(
        onDoubleTap: () => _zoomCard(e.cardId, name),
        child: tile,
      );
    }

    return GestureDetector(
      onTap: () => _cardActions(e, side),
      onDoubleTap: () => _zoomCard(e.cardId, name),
      child: LongPressDraggable<_DragData>(
        data: _DragData(e.cardId, side),
        onDragStarted: () => setState(() => _dragging = true),
        onDragEnd: (_) => setState(() => _dragging = false),
        feedback: Opacity(opacity: 0.85, child: tile),
        childWhenDragging: Opacity(opacity: 0.3, child: tile),
        child: tile,
      ),
    );
  }

  // Full-screen card zoom over a dark scrim. Tap (or double-tap) anywhere to
  // dismiss; pinch/drag to inspect details. Mirrors MTG Arena's card zoom.
  void _zoomCard(String id, String name) {
    final file = c.imageCache?.fileFor(id);
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        onDoubleTap: () => Navigator.pop(ctx),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: InteractiveViewer(
              child: (file != null && file.existsSync())
                  ? Image.file(file, fit: BoxFit.contain)
                  : _placeholder(name, 280, 391),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardImage(String id, String name, double w, double h) {
    final cache = c.imageCache;
    final file = cache?.fileFor(id);
    if (file != null && file.existsSync()) {
      return Image.file(
        file,
        width: w,
        height: h,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(name, w, h),
      );
    }
    return _placeholder(name, w, h);
  }

  Widget _placeholder(String name, double w, double h) {
    final theme = Theme.of(context);
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(6),
      child: Center(
        child: Text(
          name,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }

  Widget _floatingTrash(ThemeData theme) {
    return DragTarget<_DragData>(
      onAcceptWithDetails: (det) =>
          _bump(det.data.cardId, det.data.fromSide, -1),
      builder: (context, candidate, _) {
        final hot = candidate.isNotEmpty;
        return Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(16),
          color: hot
              ? theme.colorScheme.error
              : theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.delete_outline,
                  color: hot
                      ? theme.colorScheme.onError
                      : theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Text(
                  'Drop here to remove one',
                  style: TextStyle(
                    color: hot
                        ? theme.colorScheme.onError
                        : theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _cardActions(DeckCardEntry e, bool side) {
    final info = c.server.card(e.cardId);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(info?.name ?? '?'),
              subtitle: Text(
                '${info?.typeLine ?? ''} · ×${e.qty} in ${side ? 'sideboard' : 'maindeck'}',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add one'),
              onTap: () {
                Navigator.pop(ctx);
                _bump(e.cardId, side, 1);
              },
            ),
            ListTile(
              leading: const Icon(Icons.remove),
              title: const Text('Remove one'),
              onTap: () {
                Navigator.pop(ctx);
                _bump(e.cardId, side, -1);
              },
            ),
            ListTile(
              leading: Icon(side ? Icons.arrow_upward : Icons.arrow_downward),
              title: Text(
                side ? 'Move one to maindeck' : 'Move one to sideboard',
              ),
              onTap: () {
                Navigator.pop(ctx);
                _move(e.cardId, toSide: !side);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove all'),
              onTap: () {
                Navigator.pop(ctx);
                _removeAll(e.cardId, side);
              },
            ),
          ],
        ),
      ),
    );
  }
}
