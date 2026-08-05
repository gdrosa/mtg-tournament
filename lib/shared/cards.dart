/// Structured decklist model: parsing free-text lists, Scryfall card metadata,
/// and grouping cards by type for the card-format editor / reveal.
///
/// PURE DART (no I/O, no Flutter) so it is unit-testable on Windows. The network
/// (Scryfall) and the image cache live in `lib/services/`; this file only models
/// the data and the rules for categorising and parsing it.
library;

/// Broad MTG card categories used to group a decklist in the editor and reveal.
enum CardCategory {
  creature,
  planeswalker,
  instant,
  sorcery,
  artifact,
  enchantment,
  land,
  other,
}

extension CardCategoryX on CardCategory {
  /// Plural section label shown as a group header.
  String get label => switch (this) {
    CardCategory.creature => 'Creatures',
    CardCategory.planeswalker => 'Planeswalkers',
    CardCategory.instant => 'Instants',
    CardCategory.sorcery => 'Sorceries',
    CardCategory.artifact => 'Artifacts',
    CardCategory.enchantment => 'Enchantments',
    CardCategory.land => 'Lands',
    CardCategory.other => 'Other',
  };

  /// Stable display order for the section headers.
  int get order => index;
}

/// Map a Scryfall `type_line` to a [CardCategory]. Precedence follows the usual
/// decklist convention: a card that is several types at once is filed under the
/// first match here — e.g. an "Artifact Creature" is a Creature, an "Artifact
/// Land" is a Land.
CardCategory categorize(String typeLine) {
  final t = typeLine.toLowerCase();
  if (t.contains('creature')) return CardCategory.creature;
  if (t.contains('planeswalker')) return CardCategory.planeswalker;
  if (t.contains('land')) return CardCategory.land;
  if (t.contains('instant')) return CardCategory.instant;
  if (t.contains('sorcery')) return CardCategory.sorcery;
  if (t.contains('artifact')) return CardCategory.artifact;
  if (t.contains('enchantment')) return CardCategory.enchantment;
  return CardCategory.other;
}

/// Resolved Scryfall card metadata we cache locally (one entry per printing we
/// have seen). Keyed by the Scryfall [id]; the image is cached under that id.
class CardInfo {
  final String id; // Scryfall card id (uuid)
  final String name; // canonical card name
  final String typeLine; // Scryfall type_line, drives [category]
  final String setCode; // e.g. "2x2"
  final String collector; // collector number (may be empty)
  final String imageUrl; // Scryfall image to download (front face)

  const CardInfo({
    required this.id,
    required this.name,
    required this.typeLine,
    required this.setCode,
    this.collector = '',
    required this.imageUrl,
  });

  CardCategory get category => categorize(typeLine);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': typeLine,
    'set': setCode,
    'cn': collector,
    'img': imageUrl,
  };

  factory CardInfo.fromJson(Map j) => CardInfo(
    id: j['id'] as String,
    name: j['name'] as String,
    typeLine: (j['type'] as String?) ?? '',
    setCode: (j['set'] as String?) ?? '',
    collector: (j['cn'] as String?) ?? '',
    imageUrl: (j['img'] as String?) ?? '',
  );
}

/// Select the front-face "normal" image URL from a Scryfall card JSON object,
/// handling double-faced / transform / MDFC / split / adventure layouts (whose
/// images live under `card_faces[0].image_uris`). Returns null if none present.
String? scryfallImageUrl(Map j) {
  final uris = j['image_uris'];
  if (uris is Map && uris['normal'] is String) return uris['normal'] as String;
  final faces = j['card_faces'];
  if (faces is List && faces.isNotEmpty) {
    final f = faces.first;
    if (f is Map && f['image_uris'] is Map) {
      final n = (f['image_uris'] as Map)['normal'];
      if (n is String) return n;
    }
  }
  return null;
}

/// Build [CardInfo] from a Scryfall card JSON object. Returns null only when the
/// JSON has no usable card `id`. A card with no resolvable image is still
/// returned with an empty [CardInfo.imageUrl] so it stays in the decklist (shown
/// as a text placeholder) instead of vanishing — the cache layer already treats
/// an empty url as "no image to download".
CardInfo? cardInfoFromScryfall(Map j) {
  final id = j['id'];
  if (id is! String || id.isEmpty) return null;
  return CardInfo(
    id: id,
    name: (j['name'] as String?) ?? id,
    typeLine: (j['type_line'] as String?) ?? '',
    setCode: (j['set'] as String?) ?? '',
    collector: (j['collector_number'] as String?) ?? '',
    imageUrl: scryfallImageUrl(j) ?? '',
  );
}

/// One stack of identical cards in a deck (a quantity of one [cardId]).
class DeckCardEntry {
  final String cardId; // references a CardInfo.id in the catalog
  final int qty;
  const DeckCardEntry(this.cardId, this.qty);

  DeckCardEntry copyWith({int? qty}) => DeckCardEntry(cardId, qty ?? this.qty);

  Map<String, dynamic> toJson() => {'id': cardId, 'q': qty};
  factory DeckCardEntry.fromJson(Map j) =>
      DeckCardEntry(j['id'] as String, (j['q'] as num).toInt());
}

/// A line parsed from a free-text decklist: a quantity and a card name.
class ParsedLine {
  final int qty;
  final String name;
  const ParsedLine(this.qty, this.name);
}

final _qtyName = RegExp(r'^\s*(\d+)\s*[xX]?\s+(.+?)\s*$');
final _setTag = RegExp(r'\s*\([A-Za-z0-9]{2,6}\)\s*[A-Za-z0-9]+\s*$');

/// Parse a free-text decklist into (qty, name) lines. Accepts the common
/// formats "4 Lightning Bolt", "4x Lightning Bolt", and "4 x Lightning Bolt".
/// Every card line must begin with a positive numeric quantity; blanks,
/// comments, section headers, unquantified names, and other metadata are
/// ignored. Trailing "(SET) 123" printing tags are stripped from valid lines.
List<ParsedLine> parseDecklist(String text) {
  final out = <ParsedLine>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#') || line.startsWith('//')) continue;
    final m = _qtyName.firstMatch(line);
    if (m == null) continue;

    final qty = int.tryParse(m.group(1)!);
    if (qty == null || qty <= 0) continue;

    final name = m.group(2)!.replaceFirst(_setTag, '').trim();
    if (name.isNotEmpty) out.add(ParsedLine(qty, name));
  }
  return out;
}

/// Render structured entries back to a canonical "N Name" decklist text, using
/// [nameOf] to look a card name up from its id. Unknown ids are skipped.
String renderDecklist(
  Iterable<DeckCardEntry> entries,
  String? Function(String id) nameOf,
) {
  final lines = <String>[];
  for (final e in entries) {
    final n = nameOf(e.cardId);
    if (n != null) lines.add('${e.qty} $n');
  }
  return lines.join('\n');
}

/// Total card count across [entries].
int deckCount(Iterable<DeckCardEntry> entries) =>
    entries.fold(0, (sum, e) => sum + e.qty);
