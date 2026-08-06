/// Immutable deck revisions: a frozen copy of a decklist at the moment it was
/// brought to a tournament.
///
/// The problem this solves: a [Deck] is editable forever, so pointing history at
/// a deck id means editing a deck silently rewrites what you played six months
/// ago. Every tournament entry therefore references a [DeckRevision], which is
/// never mutated and never deleted while any entry references it.
///
/// PURE DART (no I/O, no Flutter) so it is unit-testable on Windows.
library;

import 'cards.dart';
import 'models.dart';

/// Content-addressed fingerprint of a decklist.
///
/// ponytail: two FNV-1a passes with different offset bases give a 64-bit hex
/// digest without pulling in `crypto` — this identifies content, it does not
/// authenticate it, and a 64-bit space is far past collision risk for the few
/// hundred revisions one device ever holds.
String contentDigest(String canonical) {
  int fnv(int hash) {
    for (final unit in canonical.codeUnits) {
      hash = (hash ^ unit) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  final a = fnv(0x811C9DC5).toRadixString(16).padLeft(8, '0');
  final b = fnv(0x9E3779B1).toRadixString(16).padLeft(8, '0');
  return '$a$b';
}

/// Canonical, order-independent text for a board, used for the digest.
///
/// Structured card entries win when the deck has been resolved (ids are stable
/// across spelling and printing), otherwise the parsed free text is used so an
/// unresolved list still gets a meaningful fingerprint.
String canonicalBoard(List<DeckCardEntry> cards, String text) {
  final counts = <String, int>{};
  if (cards.isNotEmpty) {
    for (final c in cards) {
      counts[c.cardId] = (counts[c.cardId] ?? 0) + c.qty;
    }
  } else {
    for (final line in parseDecklist(text)) {
      final key = line.name.toLowerCase();
      counts[key] = (counts[key] ?? 0) + line.qty;
    }
  }
  final keys = counts.keys.toList()..sort();
  return [for (final k in keys) '${counts[k]} $k'].join('\n');
}

/// Name → quantity for a board, from the free text (human-readable, so it is
/// what [DeckDiff] reports). Falls back to an empty map for an empty list.
Map<String, int> boardCounts(String text) {
  final counts = <String, int>{};
  for (final line in parseDecklist(text)) {
    counts[line.name] = (counts[line.name] ?? 0) + line.qty;
  }
  return counts;
}

/// A frozen decklist. Immutable by contract: nothing in the app updates a
/// revision in place, and [id] is derived from the content so two devices that
/// registered the same list agree on the same revision id (which is what makes
/// importing someone else's tournament idempotent).
class DeckRevision {
  final String id; // "<deckId>:<contentHash>"
  final String deckId;
  final String ownerId;
  final String name; // deck name at the time
  final String archetype; // archetype at the time ('' → fall back to [name])
  final int revision; // 1-based ordinal within the deck
  final DateTime createdAt;
  final String contentHash;
  final String mainboardText;
  final String sideboardText;
  final List<DeckCardEntry> mainCards;
  final List<DeckCardEntry> sideCards;

  /// True when this revision was synthesized during the migration of a save
  /// written before revisions existed, so it is the deck's *current* list, not
  /// provably the list actually played. Statistics label it as such.
  final bool migrated;

  const DeckRevision({
    required this.id,
    required this.deckId,
    required this.ownerId,
    required this.name,
    required this.archetype,
    required this.revision,
    required this.createdAt,
    required this.contentHash,
    required this.mainboardText,
    required this.sideboardText,
    this.mainCards = const [],
    this.sideCards = const [],
    this.migrated = false,
  });

  /// Freeze [deck] as revision number [revision], taken at [at].
  factory DeckRevision.of(
    Deck deck, {
    required int revision,
    required DateTime at,
    bool migrated = false,
  }) {
    final canonical = [
      deck.name.trim(),
      deck.effectiveArchetype,
      'MAIN',
      canonicalBoard(deck.mainCards, deck.mainboardText),
      'SIDE',
      canonicalBoard(deck.sideCards, deck.sideboardText),
    ].join('\n');
    final hash = contentDigest(canonical);
    return DeckRevision(
      id: '${deck.id}:$hash',
      deckId: deck.id,
      ownerId: deck.ownerId,
      name: deck.name,
      archetype: deck.archetype,
      revision: revision,
      createdAt: at,
      contentHash: hash,
      mainboardText: deck.mainboardText,
      sideboardText: deck.sideboardText,
      mainCards: List.unmodifiable(deck.mainCards),
      sideCards: List.unmodifiable(deck.sideCards),
      migrated: migrated,
    );
  }

  /// Archetype for grouping — the explicit archetype, else the deck name.
  String get effectiveArchetype =>
      archetype.trim().isEmpty ? name.trim() : archetype.trim();

  int get mainCount => mainCards.isNotEmpty
      ? deckCount(mainCards)
      : boardCounts(mainboardText).values.fold(0, (a, b) => a + b);

  int get sideCount => sideCards.isNotEmpty
      ? deckCount(sideCards)
      : boardCounts(sideboardText).values.fold(0, (a, b) => a + b);

  Map<String, dynamic> toJson() => {
    'id': id,
    'deckId': deckId,
    'ownerId': ownerId,
    'name': name,
    'archetype': archetype,
    'revision': revision,
    'createdAt': createdAt.toIso8601String(),
    'hash': contentHash,
    'main': mainboardText,
    'side': sideboardText,
    'mainCards': mainCards.map((e) => e.toJson()).toList(),
    'sideCards': sideCards.map((e) => e.toJson()).toList(),
    'migrated': migrated,
  };

  factory DeckRevision.fromJson(Map j) => DeckRevision(
    id: j['id'] as String,
    deckId: j['deckId'] as String,
    ownerId: (j['ownerId'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    archetype: (j['archetype'] as String?) ?? '',
    revision: (j['revision'] as num?)?.toInt() ?? 1,
    createdAt: DateTime.parse(j['createdAt'] as String),
    contentHash: (j['hash'] as String?) ?? '',
    mainboardText: (j['main'] as String?) ?? '',
    sideboardText: (j['side'] as String?) ?? '',
    mainCards: [
      for (final e in (j['mainCards'] as List? ?? const []))
        DeckCardEntry.fromJson(e as Map),
    ],
    sideCards: [
      for (final e in (j['sideCards'] as List? ?? const []))
        DeckCardEntry.fromJson(e as Map),
    ],
    migrated: j['migrated'] == true,
  );
}

/// What changed between two revisions of the same deck, per board.
class BoardDiff {
  /// name → how many copies were added (positive) …
  final Map<String, int> added;

  /// … and removed (positive count of copies taken out).
  final Map<String, int> removed;
  const BoardDiff(this.added, this.removed);

  bool get isEmpty => added.isEmpty && removed.isEmpty;

  /// Total cards swapped, counting an N-for-N swap as N.
  int get changedCards {
    final a = added.values.fold(0, (s, v) => s + v);
    final r = removed.values.fold(0, (s, v) => s + v);
    return a > r ? a : r;
  }

  static BoardDiff between(String fromText, String toText) {
    final from = boardCounts(fromText);
    final to = boardCounts(toText);
    final added = <String, int>{};
    final removed = <String, int>{};
    for (final name in {...from.keys, ...to.keys}) {
      final delta = (to[name] ?? 0) - (from[name] ?? 0);
      if (delta > 0) added[name] = delta;
      if (delta < 0) removed[name] = -delta;
    }
    return BoardDiff(added, removed);
  }
}

/// Full comparison of two revisions — the "what did I change" view.
class DeckDiff {
  final DeckRevision from;
  final DeckRevision to;
  final BoardDiff main;
  final BoardDiff side;
  const DeckDiff(this.from, this.to, this.main, this.side);

  bool get isEmpty => main.isEmpty && side.isEmpty;
  int get changedCards => main.changedCards + side.changedCards;

  factory DeckDiff.between(DeckRevision from, DeckRevision to) => DeckDiff(
    from,
    to,
    BoardDiff.between(from.mainboardText, to.mainboardText),
    BoardDiff.between(from.sideboardText, to.sideboardText),
  );
}
