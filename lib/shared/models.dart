/// Core domain types for the MTG tournament manager.
///
/// Pure Dart, no I/O — safe to unit-test on any platform and to share between
/// the UI isolate, the server isolate, and (via codegen) the web client.
library;

import 'cards.dart';

/// Lifecycle of a tournament.
enum TournamentStatus { lobby, running, finished }

/// How rounds are paired.
///
/// [swiss] plays a fixed number of rounds and pairs on record; everyone plays
/// every round. [singleElimination] pairs only the winners of the previous
/// round, so the field halves each time and the bracket length is fixed by the
/// entrant count.
enum TournamentKind {
  swiss,
  singleElimination;

  String get label =>
      this == TournamentKind.swiss ? 'Swiss' : 'Single elimination';
}

/// Per-match lifecycle. See ARCHITECTURE.md §4.2.
///
/// ```
/// pending --p1 submits--> awaitingSecond --match--> resultAccepted --both 👍--> confirmed
///                                        --mismatch--> needsReview(resultMismatch)
/// resultAccepted --any 👎--> needsReview(infractionReported)
/// needsReview --host resolves--> confirmed
/// bye --> confirmed (auto)
/// ```
enum MatchState {
  pending,
  awaitingSecond,
  resultAccepted,
  needsReview,
  confirmed,
}

/// Why a match was escalated to the host.
enum ReviewReason { none, resultMismatch, infractionReported }

/// A durable player identity, stable across tournaments (see REQUIREMENTS Q1).
class Player {
  final String id; // stable id; never the display name
  final String nickname;
  const Player({required this.id, required this.nickname});
  Map<String, dynamic> toJson() => {'id': id, 'nickname': nickname};
  factory Player.fromJson(Map j) =>
      Player(id: j['id'] as String, nickname: j['nickname'] as String);
}

/// A named, durable deck owned by a player (e.g. "Domain Zoo").
///
/// Carries both the legacy free-text lists ([mainboardText]/[sideboardText]) and
/// the structured card lists ([mainCards]/[sideCards]) that back the card-format
/// editor and reveal. The structured lists are authoritative once non-empty; the
/// text is kept in sync for back-compat and as a plain-text fallback.
class Deck {
  final String id; // stable id independent of [name] so renames keep history
  final String ownerId;
  final String name;

  /// Optional archetype label ("Domain Zoo", "Izzet Murktide") used to group
  /// different players' decks in matchup statistics. Empty → use [name].
  final String archetype;
  final String mainboardText;
  final String sideboardText;
  final List<DeckCardEntry> mainCards;
  final List<DeckCardEntry> sideCards;
  const Deck({
    required this.id,
    required this.ownerId,
    required this.name,
    this.archetype = '',
    required this.mainboardText,
    required this.sideboardText,
    this.mainCards = const [],
    this.sideCards = const [],
  });

  /// True once the deck has been resolved into structured cards (so it can be
  /// shown in card format rather than as plain text).
  bool get hasCards => mainCards.isNotEmpty || sideCards.isNotEmpty;

  /// Archetype for grouping — the explicit label, else the deck name.
  String get effectiveArchetype =>
      archetype.trim().isEmpty ? name.trim() : archetype.trim();

  Deck copyWith({
    String? name,
    String? archetype,
    String? mainboardText,
    String? sideboardText,
    List<DeckCardEntry>? mainCards,
    List<DeckCardEntry>? sideCards,
  }) => Deck(
    id: id,
    ownerId: ownerId,
    name: name ?? this.name,
    archetype: archetype ?? this.archetype,
    mainboardText: mainboardText ?? this.mainboardText,
    sideboardText: sideboardText ?? this.sideboardText,
    mainCards: mainCards ?? this.mainCards,
    sideCards: sideCards ?? this.sideCards,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'ownerId': ownerId,
    'name': name,
    if (archetype.isNotEmpty) 'archetype': archetype,
    'main': mainboardText,
    'side': sideboardText,
    'mainCards': mainCards.map((e) => e.toJson()).toList(),
    'sideCards': sideCards.map((e) => e.toJson()).toList(),
  };
  factory Deck.fromJson(Map j) => Deck(
    id: j['id'] as String,
    ownerId: j['ownerId'] as String,
    name: j['name'] as String,
    archetype: j['archetype'] as String? ?? '',
    mainboardText: j['main'] as String? ?? '',
    sideboardText: j['side'] as String? ?? '',
    mainCards: [
      for (final e in (j['mainCards'] as List? ?? const []))
        DeckCardEntry.fromJson(e as Map),
    ],
    sideCards: [
      for (final e in (j['sideCards'] as List? ?? const []))
        DeckCardEntry.fromJson(e as Map),
    ],
  );
}

/// A player's enrollment in one tournament (which deck they brought).
///
/// [deckRevisionId] pins the exact, immutable list played at this event. It is
/// null only in saves written before revisions existed; the controller
/// back-fills those on load, so treat null as "unknown historical list".
class Entry {
  final String playerId;
  final String deckId;
  String? deckRevisionId;
  bool dropped;

  /// The organizer disqualified this player. Implies [dropped], but is kept
  /// separately because history must not read a disqualification as "they went
  /// home early".
  bool disqualified;

  Entry({
    required this.playerId,
    required this.deckId,
    this.deckRevisionId,
    this.dropped = false,
    this.disqualified = false,
  });
  Map<String, dynamic> toJson() => {
    'playerId': playerId,
    'deckId': deckId,
    if (deckRevisionId != null) 'revisionId': deckRevisionId,
    'dropped': dropped,
    if (disqualified) 'disqualified': true,
  };
  factory Entry.fromJson(Map j) => Entry(
    playerId: j['playerId'] as String,
    deckId: j['deckId'] as String,
    deckRevisionId: j['revisionId'] as String?,
    dropped: j['dropped'] as bool? ?? false,
    disqualified: j['disqualified'] == true,
  );
}

/// Best-of-three game tally, always in the canonical (p1, p2) orientation.
class GameScore {
  final int p1Wins;
  final int p2Wins;
  final int draws;
  const GameScore(this.p1Wins, this.p2Wins, [this.draws = 0]);

  bool get p1IsWinner => p1Wins > p2Wins;
  bool get p2IsWinner => p2Wins > p1Wins;

  /// 0-0 with no draws: nobody won and nobody drew. The only way to reach it is
  /// the organizer disqualifying both players, so it is a double loss rather
  /// than a 0-0 draw — see [isDraw].
  bool get isDoubleLoss => p1Wins == 0 && p2Wins == 0 && draws == 0;
  bool get isDraw => p1Wins == p2Wins && !isDoubleLoss;
  int get totalGames => p1Wins + p2Wins + draws;

  /// Flip orientation (used when a result is reported from p2's point of view).
  GameScore get flipped => GameScore(p2Wins, p1Wins, draws);

  @override
  bool operator ==(Object other) =>
      other is GameScore &&
      other.p1Wins == p1Wins &&
      other.p2Wins == p2Wins &&
      other.draws == draws;

  @override
  int get hashCode => Object.hash(p1Wins, p2Wins, draws);

  @override
  String toString() => draws > 0 ? '$p1Wins-$p2Wins-$draws' : '$p1Wins-$p2Wins';

  Map<String, dynamic> toJson() => {'a': p1Wins, 'b': p2Wins, 'd': draws};
  factory GameScore.fromJson(Map j) =>
      GameScore(j['a'] as int, j['b'] as int, (j['d'] as int?) ?? 0);
}

/// One pairing in a round. [p2Id] is null for a bye.
class Match {
  final String id;
  final String p1Id;
  final String? p2Id;

  /// Result submitted by each player, keyed by submitter id, in (p1, p2) orientation.
  final Map<String, GameScore> submissions = {};

  /// The reconciled / host-set authoritative result (null until known).
  GameScore? accepted;

  /// Infraction confirmation per player: true = "no infractions" (👍), false = reported (👎).
  final Map<String, bool> infraction = {};

  MatchState state;
  ReviewReason reviewReason;
  String? hostNote;

  /// True once the host set the result by hand (adjudication). Sticky: the
  /// statistics layer reports adjudicated results separately from player-agreed
  /// ones, so this must survive the match reaching [MatchState.confirmed].
  bool adjudicated = false;

  /// True if this match was ever escalated for review (mismatch or infraction),
  /// even after it was resolved. Also sticky, for the same reason.
  bool disputed = false;

  Match({
    required this.id,
    required this.p1Id,
    this.p2Id,
    this.state = MatchState.pending,
    this.reviewReason = ReviewReason.none,
  });

  bool get isBye => p2Id == null;

  /// The two seated player ids (one for a bye).
  List<String> get playerIds => isBye ? [p1Id] : [p1Id, p2Id!];

  bool involves(String playerId) => p1Id == playerId || p2Id == playerId;

  /// The opponent of [playerId] in this match, or null (bye / not involved).
  String? opponentOf(String playerId) {
    if (isBye) return null;
    if (playerId == p1Id) return p2Id;
    if (playerId == p2Id) return p1Id;
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'p1': p1Id,
    'p2': p2Id,
    'state': state.name,
    'review': reviewReason.name,
    'hostNote': hostNote,
    if (adjudicated) 'adjudicated': true,
    if (disputed) 'disputed': true,
    'accepted': accepted?.toJson(),
    'subs': submissions.map((k, v) => MapEntry(k, v.toJson())),
    'infr': infraction,
  };

  factory Match.fromJson(Map j) {
    final m = Match(
      id: j['id'] as String,
      p1Id: j['p1'] as String,
      p2Id: j['p2'] as String?,
      state: MatchState.values.byName(j['state'] as String),
      reviewReason: ReviewReason.values.byName(j['review'] as String),
    );
    m.hostNote = j['hostNote'] as String?;
    m.adjudicated = j['adjudicated'] == true;
    // Pre-adjudication saves: a note only ever came from the host resolving it.
    if (!m.adjudicated && m.hostNote != null) m.adjudicated = true;
    m.disputed =
        j['disputed'] == true ||
        m.reviewReason != ReviewReason.none ||
        m.adjudicated;
    m.accepted = j['accepted'] == null
        ? null
        : GameScore.fromJson(j['accepted'] as Map);
    (j['subs'] as Map).forEach(
      (k, v) => m.submissions[k as String] = GameScore.fromJson(v as Map),
    );
    (j['infr'] as Map).forEach((k, v) => m.infraction[k as String] = v as bool);
    return m;
  }
}

/// A round: an ordered set of matches.
class Round {
  final int number; // 1-based
  final List<Match> matches;

  /// Wall-clock deadline when the organizer runs a round timer, else null.
  ///
  /// Display only. Nothing in the state machine reads it: a round that runs out
  /// of time still needs the organizer to resolve and advance it, exactly as
  /// before. Set at pairing time and re-settable by the host.
  DateTime? endsAt;

  Round(this.number, this.matches, {this.endsAt});

  bool get isComplete => matches.every((m) => m.state == MatchState.confirmed);

  Match? matchFor(String playerId) {
    for (final m in matches) {
      if (m.involves(playerId)) return m;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'number': number,
    if (endsAt != null) 'endsAt': endsAt!.toIso8601String(),
    'matches': matches.map((m) => m.toJson()).toList(),
  };
  factory Round.fromJson(Map j) => Round(
    j['number'] as int,
    [for (final m in (j['matches'] as List)) Match.fromJson(m as Map)],
    endsAt: j['endsAt'] == null ? null : DateTime.parse(j['endsAt'] as String),
  );
}

/// A flattened result used by the standings/tiebreaker engine.
class MatchRecord {
  final String p1;
  final String? p2; // null => bye
  final GameScore score; // for a bye, treat as 2-0 (GameScore(2,0))
  const MatchRecord(this.p1, this.p2, this.score);
  bool get isBye => p2 == null;
}

/// One row of computed standings, fully sortable by the MTR tiebreaker order.
class StandingRow {
  final String playerId;
  final int matchPoints;
  final int roundsPlayed;
  final double omw; // opponents' match-win %
  final double gw; //  game-win %
  final double ogw; // opponents' game-win %
  final int byes;

  const StandingRow({
    required this.playerId,
    required this.matchPoints,
    required this.roundsPlayed,
    required this.omw,
    required this.gw,
    required this.ogw,
    required this.byes,
  });
}
