/// Versioned import / export of tournament data.
///
/// Three properties this file exists to guarantee:
///
/// * **Cumulative.** Importing adds; it never clears. Bringing in a friend's
///   event does not cost you your own history, and re-importing your own backup
///   does not duplicate it.
/// * **Previewable and atomic.** [previewBundle] reports exactly what would
///   change before anything does, and [mergeBundle] builds the whole next state
///   before touching the live one, so a malformed file cannot half-apply.
/// * **Identity-safe.** Players are matched by stable id. A shared nickname is
///   only ever a *suggestion* surfaced in the preview; nothing is merged unless
///   the organizer says so.
///
/// Credentials never enter a bundle: no session tokens, no owner token, no
/// active join code. Raw questionnaire answers are private and travel only in a
/// [BundleScope.full] backup of your own device.
library;

import 'dart:convert';

import '../shared/deck_revision.dart';
import '../shared/models.dart';
import '../shared/questionnaire.dart';
import '../shared/stats_facts.dart';
import '../shared/stats_service.dart';
import '../shared/tournament_engine.dart';
import 'controller.dart';

/// Interchange format version. Bump when a field changes meaning; readers
/// refuse anything newer rather than dropping what they do not understand.
const int kInterchangeVersion = 1;

const String kBundleKind = 'mtg-tourney-bundle';
const String kAggregateKind = 'mtg-tourney-aggregate';

/// What a bundle carries.
enum BundleScope {
  /// Everything on this device, questionnaires included. Your private backup.
  full,

  /// One tournament plus the players, decks and revisions it references.
  tournament,

  /// Every tournament one player took part in, plus their decks.
  playerHistory,

  /// Decks and their revisions, with no results at all.
  deckLibrary,
}

/// Build an interchange bundle.
///
/// [tournamentId] is required for [BundleScope.tournament], [playerId] for
/// [BundleScope.playerHistory].
Map<String, dynamic> buildBundle(
  ServerController c, {
  required BundleScope scope,
  String? tournamentId,
  String? playerId,
  DateTime? now,
}) {
  final tournaments = <TournamentEngine>[];
  switch (scope) {
    case BundleScope.full:
      tournaments.addAll(c.archive);
    case BundleScope.tournament:
      final t = tournamentId == null ? null : c.tournamentById(tournamentId);
      if (t != null) tournaments.add(t);
    case BundleScope.playerHistory:
      for (final t in c.archive) {
        if (playerId != null && t.entryOf(playerId) != null) tournaments.add(t);
      }
    case BundleScope.deckLibrary:
      break; // decks only
  }

  // Only ship the identities the included tournaments (or the chosen player)
  // actually reference — a shared tournament should not leak the whole club.
  final playerIds = <String>{?playerId};
  final deckIds = <String>{};
  final revisionIds = <String>{};
  for (final t in tournaments) {
    for (final e in t.entries) {
      playerIds.add(e.playerId);
      deckIds.add(e.deckId);
      if (e.deckRevisionId != null) revisionIds.add(e.deckRevisionId!);
    }
  }
  if (scope == BundleScope.full || scope == BundleScope.deckLibrary) {
    final owner = scope == BundleScope.deckLibrary ? playerId : null;
    for (final d in c.decks.values) {
      if (owner != null && d.ownerId != owner) continue;
      deckIds.add(d.id);
      playerIds.add(d.ownerId);
    }
    for (final r in c.deckRevisions.values) {
      if (deckIds.contains(r.deckId)) revisionIds.add(r.id);
    }
  }
  if (scope == BundleScope.playerHistory && playerId != null) {
    for (final d in c.decks.values) {
      if (d.ownerId == playerId) deckIds.add(d.id);
    }
    for (final r in c.deckRevisions.values) {
      if (deckIds.contains(r.deckId)) revisionIds.add(r.id);
    }
  }

  return {
    'kind': kBundleKind,
    'version': kInterchangeVersion,
    'scope': scope.name,
    'schema': kSaveSchemaVersion,
    'createdAt': (now ?? c.clock()).toIso8601String(),
    'players': [
      for (final id in playerIds)
        if (c.players[id] != null) c.players[id]!.toJson(),
    ],
    'aliases': {
      for (final id in playerIds)
        if (c.playerAliases[id] != null) id: c.playerAliases[id],
    },
    'decks': [
      for (final id in deckIds)
        if (c.decks[id] != null) c.decks[id]!.toJson(),
    ],
    'revisions': [
      for (final id in revisionIds)
        if (c.deckRevisions[id] != null) c.deckRevisions[id]!.toJson(),
    ],
    'tournaments': [for (final t in tournaments) t.toJson()],
    // Self-reported answers are private to the device that collected them.
    if (scope == BundleScope.full)
      'surveys': [for (final s in c.surveys.values) s.toJson()],
  };
}

/// A local player who *might* be the same person as an incoming one. Shown to
/// the organizer; never acted on automatically.
class IdentitySuggestion {
  final String incomingId;
  final String incomingNickname;
  final String localId;
  final String localNickname;
  final String reason;
  const IdentitySuggestion({
    required this.incomingId,
    required this.incomingNickname,
    required this.localId,
    required this.localNickname,
    required this.reason,
  });
}

/// What importing a bundle would do, computed without changing anything.
class ImportPreview {
  final int version;
  final BundleScope? scope;
  final DateTime? createdAt;
  final List<String> errors;
  final List<String> warnings;
  final int newPlayers;
  final int newDecks;
  final int newRevisions;
  final int newTournaments;
  final int duplicateTournaments;
  final int newSurveys;
  final List<IdentitySuggestion> identitySuggestions;

  const ImportPreview({
    required this.version,
    required this.scope,
    required this.createdAt,
    this.errors = const [],
    this.warnings = const [],
    this.newPlayers = 0,
    this.newDecks = 0,
    this.newRevisions = 0,
    this.newTournaments = 0,
    this.duplicateTournaments = 0,
    this.newSurveys = 0,
    this.identitySuggestions = const [],
  });

  bool get canImport => errors.isEmpty;

  /// True when the bundle would change nothing — the idempotent re-import case.
  bool get isNoOp =>
      newPlayers == 0 &&
      newDecks == 0 &&
      newRevisions == 0 &&
      newTournaments == 0 &&
      newSurveys == 0;

  factory ImportPreview.error(String message) => ImportPreview(
    version: 0,
    scope: null,
    createdAt: null,
    errors: [message],
  );
}

/// Outcome of an applied import.
class ImportResult {
  final bool ok;
  final String? error;
  final int addedPlayers;
  final int addedDecks;
  final int addedRevisions;
  final int addedTournaments;
  final int skippedTournaments;
  final int addedSurveys;

  const ImportResult({
    required this.ok,
    this.error,
    this.addedPlayers = 0,
    this.addedDecks = 0,
    this.addedRevisions = 0,
    this.addedTournaments = 0,
    this.skippedTournaments = 0,
    this.addedSurveys = 0,
  });

  factory ImportResult.failure(String message) =>
      ImportResult(ok: false, error: message);
}

/// Validated, id-remapped view of a bundle. Building one cannot fail halfway:
/// either it throws (and nothing was touched) or it is ready to apply.
class _Staged {
  final List<Player> players = [];
  final Map<String, List<String>> aliases = {};
  final List<Deck> decks = [];
  final List<DeckRevision> revisions = [];
  final List<TournamentEngine> tournaments = [];
  final List<MatchSurvey> surveys = [];
  BundleScope? scope;
  DateTime? createdAt;
  int version = 0;
}

/// Parse + validate + remap, or throw [FormatException].
_Staged _stage(Map bundle, Map<String, String> identityMap) {
  final s = _Staged();
  if (bundle['kind'] != kBundleKind) {
    throw const FormatException('This file is not a tournament data bundle.');
  }
  final version = (bundle['version'] as num?)?.toInt() ?? 0;
  if (version < 1) throw const FormatException('Missing bundle version.');
  if (version > kInterchangeVersion) {
    throw FormatException(
      'This bundle was made by a newer version of the app (format $version). '
      'Update before importing it.',
    );
  }
  s.version = version;
  s.scope = BundleScope.values
      .where((x) => x.name == bundle['scope'])
      .firstOrNull;
  final created = bundle['createdAt'];
  s.createdAt = created is String ? DateTime.tryParse(created) : null;

  String remap(String id) => identityMap[id] ?? id;

  for (final p in (bundle['players'] as List? ?? const [])) {
    final player = Player.fromJson(p as Map);
    s.players.add(Player(id: remap(player.id), nickname: player.nickname));
  }
  (bundle['aliases'] as Map? ?? const {}).forEach((k, v) {
    s.aliases[remap(k as String)] = [for (final a in (v as List)) a as String];
  });
  for (final d in (bundle['decks'] as List? ?? const [])) {
    final deck = Deck.fromJson(d as Map);
    s.decks.add(
      Deck(
        id: deck.id,
        ownerId: remap(deck.ownerId),
        name: deck.name,
        archetype: deck.archetype,
        mainboardText: deck.mainboardText,
        sideboardText: deck.sideboardText,
        mainCards: deck.mainCards,
        sideCards: deck.sideCards,
      ),
    );
  }
  for (final r in (bundle['revisions'] as List? ?? const [])) {
    final json = Map<String, dynamic>.of((r as Map).cast<String, dynamic>());
    json['ownerId'] = remap((json['ownerId'] as String?) ?? '');
    s.revisions.add(DeckRevision.fromJson(json));
  }
  for (final t in (bundle['tournaments'] as List? ?? const [])) {
    s.tournaments.add(
      TournamentEngine.fromJson(_remapTournament(t as Map, remap)),
    );
  }
  for (final x in (bundle['surveys'] as List? ?? const [])) {
    s.surveys.add(MatchSurvey.fromJson(_remapSurvey(x as Map, remap)));
  }
  return s;
}

/// Rewrite every player id inside a serialized tournament.
Map<String, dynamic> _remapTournament(Map json, String Function(String) remap) {
  final out = Map<String, dynamic>.of(json.cast<String, dynamic>());
  out['entries'] = [
    for (final e in (json['entries'] as List? ?? const []))
      {
        ...(e as Map).cast<String, dynamic>(),
        'playerId': remap(e['playerId'] as String),
      },
  ];
  out['rounds'] = [
    for (final r in (json['rounds'] as List? ?? const []))
      {
        ...(r as Map).cast<String, dynamic>(),
        'matches': [
          for (final m in (r['matches'] as List? ?? const []))
            {
              ...(m as Map).cast<String, dynamic>(),
              'p1': remap(m['p1'] as String),
              if (m['p2'] != null) 'p2': remap(m['p2'] as String),
              'subs': {
                for (final e in (m['subs'] as Map? ?? const {}).entries)
                  remap(e.key as String): e.value,
              },
              'infr': {
                for (final e in (m['infr'] as Map? ?? const {}).entries)
                  remap(e.key as String): e.value,
              },
            },
        ],
      },
  ];
  return out;
}

Map<String, dynamic> _remapSurvey(Map json, String Function(String) remap) {
  final out = Map<String, dynamic>.of(json.cast<String, dynamic>());
  out['players'] = [
    for (final p in (json['players'] as List? ?? const [])) remap(p as String),
  ];
  out['p1'] = remap(json['p1'] as String);
  out['responses'] = [
    for (final r in (json['responses'] as List? ?? const []))
      {
        ...(r as Map).cast<String, dynamic>(),
        'playerId': remap(r['playerId'] as String),
      },
  ];
  return out;
}

/// Report what importing [bundle] would change. Never mutates [c].
ImportPreview previewBundle(
  ServerController c,
  Map bundle, {
  Map<String, String> identityMap = const {},
}) {
  final _Staged staged;
  try {
    staged = _stage(bundle, identityMap);
  } on FormatException catch (e) {
    return ImportPreview.error(e.message);
  } catch (_) {
    return ImportPreview.error('This file could not be read.');
  }

  final warnings = <String>[];
  final suggestions = <IdentitySuggestion>[];

  // Nickname collisions are *suggestions*. Two people called "Mike" are two
  // people until the organizer says otherwise.
  final localByNickname = <String, List<Player>>{};
  for (final p in c.players.values) {
    localByNickname
        .putIfAbsent(p.nickname.toLowerCase().trim(), () => [])
        .add(p);
  }
  for (final incoming in staged.players) {
    if (c.players.containsKey(incoming.id)) continue;
    final key = incoming.nickname.toLowerCase().trim();
    for (final local in localByNickname[key] ?? const <Player>[]) {
      suggestions.add(
        IdentitySuggestion(
          incomingId: incoming.id,
          incomingNickname: incoming.nickname,
          localId: local.id,
          localNickname: local.nickname,
          reason: 'Same nickname — confirm before merging.',
        ),
      );
    }
    final aliases = staged.aliases[incoming.id] ?? const <String>[];
    for (final alias in aliases) {
      for (final local
          in localByNickname[alias.toLowerCase().trim()] ?? const <Player>[]) {
        suggestions.add(
          IdentitySuggestion(
            incomingId: incoming.id,
            incomingNickname: incoming.nickname,
            localId: local.id,
            localNickname: local.nickname,
            reason: 'Previously known as "$alias" — confirm before merging.',
          ),
        );
      }
    }
  }

  var duplicates = 0;
  var newTournaments = 0;
  for (final t in staged.tournaments) {
    if (c.archive.any((a) => a.id == t.id) || c.engine?.id == t.id) {
      duplicates++;
    } else {
      newTournaments++;
    }
  }

  final newDecks = staged.decks.where((d) => !c.decks.containsKey(d.id)).length;
  final conflictingDecks = staged.decks
      .where(
        (d) =>
            c.decks.containsKey(d.id) &&
            c.decks[d.id]!.mainboardText != d.mainboardText,
      )
      .length;
  if (conflictingDecks > 0) {
    warnings.add(
      '$conflictingDecks deck(s) already exist here with a different list. '
      'Your copy is kept; the imported history still points at the exact '
      'revision it was played with.',
    );
  }
  if (duplicates > 0) {
    warnings.add(
      '$duplicates tournament(s) are already in your history and will be '
      'skipped.',
    );
  }

  return ImportPreview(
    version: staged.version,
    scope: staged.scope,
    createdAt: staged.createdAt,
    warnings: warnings,
    newPlayers: staged.players
        .where((p) => !c.players.containsKey(p.id))
        .length,
    newDecks: newDecks,
    newRevisions: staged.revisions
        .where((r) => !c.deckRevisions.containsKey(r.id))
        .length,
    newTournaments: newTournaments,
    duplicateTournaments: duplicates,
    newSurveys: staged.surveys
        .where((s) => !c.surveys.containsKey(s.key))
        .length,
    identitySuggestions: suggestions,
  );
}

/// Merge [bundle] into [c]. Additive and idempotent: existing records win, new
/// ones are appended, and nothing local is deleted.
///
/// [identityMap] maps an incoming player id to a local one — the organizer's
/// answer to the suggestions from [previewBundle].
ImportResult mergeBundle(
  ServerController c,
  Map bundle, {
  Map<String, String> identityMap = const {},
}) {
  final _Staged staged;
  try {
    staged = _stage(bundle, identityMap);
  } on FormatException catch (e) {
    return ImportResult.failure(e.message);
  } catch (_) {
    return ImportResult.failure('This file could not be read.');
  }

  // Stage the whole next state first; only swap once nothing can throw.
  final players = Map<String, Player>.of(c.players);
  final aliases = {
    for (final e in c.playerAliases.entries) e.key: [...e.value],
  };
  final decks = Map<String, Deck>.of(c.decks);
  final revisions = Map<String, DeckRevision>.of(c.deckRevisions);
  final surveys = Map<String, MatchSurvey>.of(c.surveys);
  final archive = [...c.archive];

  var addedPlayers = 0;
  var addedDecks = 0;
  var addedRevisions = 0;
  var addedTournaments = 0;
  var skippedTournaments = 0;
  var addedSurveys = 0;

  for (final p in staged.players) {
    if (players.containsKey(p.id)) continue; // your name for them wins
    players[p.id] = p;
    addedPlayers++;
  }
  staged.aliases.forEach((id, list) {
    final target = aliases.putIfAbsent(id, () => []);
    for (final alias in list) {
      if (!target.contains(alias)) target.add(alias);
    }
  });
  for (final d in staged.decks) {
    if (decks.containsKey(d.id)) continue; // never overwrite a live deck
    decks[d.id] = d;
    addedDecks++;
  }
  for (final r in staged.revisions) {
    if (revisions.containsKey(r.id)) continue; // immutable: identical by id
    revisions[r.id] = r;
    addedRevisions++;
  }
  for (final t in staged.tournaments) {
    if (archive.any((a) => a.id == t.id) || c.engine?.id == t.id) {
      skippedTournaments++;
      continue;
    }
    archive.add(t);
    addedTournaments++;
  }
  for (final s in staged.surveys) {
    if (surveys.containsKey(s.key)) continue;
    surveys[s.key] = s;
    addedSurveys++;
  }

  archive.sort((a, b) => a.createdAt.compareTo(b.createdAt));

  c.players
    ..clear()
    ..addAll(players);
  c.playerAliases
    ..clear()
    ..addAll(aliases);
  c.decks
    ..clear()
    ..addAll(decks);
  c.deckRevisions
    ..clear()
    ..addAll(revisions);
  c.surveys
    ..clear()
    ..addAll(surveys);
  c.archive
    ..clear()
    ..addAll(archive);
  // Imported history from an older app has no revisions; reconstruct what we
  // can so it still shows a decklist, flagged as reconstructed.
  c.migrateMissingRevisions();
  c.persistAndNotify();

  return ImportResult(
    ok: true,
    addedPlayers: addedPlayers,
    addedDecks: addedDecks,
    addedRevisions: addedRevisions,
    addedTournaments: addedTournaments,
    skippedTournaments: skippedTournaments,
    addedSurveys: addedSurveys,
  );
}

/// Anonymized aggregate statistics: archetype and matchup records with no
/// player ids, no nicknames and no decklists. Export-only by design — there is
/// nothing here to import back, which is the point.
Map<String, dynamic> buildAggregateExport(
  ServerController c, {
  StatFilter filter = const StatFilter(),
  DateTime? now,
}) {
  final service = StatsService(c.matchFacts());
  final facts = service.where(filter);
  final matrix = MatchupMatrix.from(facts);

  return {
    'kind': kAggregateKind,
    'version': kInterchangeVersion,
    'createdAt': (now ?? c.clock()).toIso8601String(),
    'tournaments': facts.map((f) => f.tournamentId).toSet().length,
    'matches': facts.length,
    'note':
        'Aggregate counts only. Associations, not causes; check the sample '
        'size before drawing a conclusion.',
    'archetypes': [
      for (final label in matrix.labels)
        () {
          final total = matrix.total(label);
          return {
            'archetype': label,
            'matches': total.match.matches,
            'wins': total.match.wins,
            'losses': total.match.losses,
            'draws': total.match.draws,
            'gameWins': total.game.wins,
            'gameLosses': total.game.losses,
          };
        }(),
    ],
    'matchups': [
      for (final row in matrix.labels)
        for (final e in matrix.rows[row]!.entries)
          {
            'archetype': row,
            'opponent': e.key,
            'matches': e.value.match.matches,
            'wins': e.value.match.wins,
            'losses': e.value.match.losses,
            'draws': e.value.match.draws,
          },
    ],
  };
}

// ---- CSV -----------------------------------------------------------------

String _csvCell(Object? value) {
  final s = value?.toString() ?? '';
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _csv(List<List<Object?>> rows) =>
    rows.map((r) => r.map(_csvCell).join(',')).join('\n');

/// One row per settled match — the export people actually open in a spreadsheet.
String matchesCsv(
  ServerController c, {
  StatFilter filter = const StatFilter(),
}) {
  final facts = StatsService(c.matchFacts()).where(filter);
  String nick(String? id) => id == null ? '' : (c.players[id]?.nickname ?? id);
  return _csv([
    [
      'date',
      'tournament',
      'format',
      'series',
      'round',
      'player1',
      'deck1',
      'archetype1',
      'player2',
      'deck2',
      'archetype2',
      'games1',
      'games2',
      'gameDraws',
      'result',
      'bye',
      'disputed',
      'adjudicated',
    ],
    for (final f in facts)
      [
        f.date.toIso8601String().split('T').first,
        f.tournamentName,
        f.format,
        f.series,
        f.round,
        nick(f.p1.playerId),
        f.p1.deckName,
        f.p1.archetypeLabel,
        nick(f.p2?.playerId),
        f.p2?.deckName ?? '',
        f.p2?.archetypeLabel ?? '',
        f.score.p1Wins,
        f.score.p2Wins,
        f.score.draws,
        f.isBye
            ? 'bye'
            : (f.score.isDraw
                  ? 'draw'
                  : (f.score.p1IsWinner ? 'player1' : 'player2')),
        f.isBye,
        f.disputed,
        f.adjudicated,
      ],
  ]);
}

/// Final standings of one tournament, with the MTR tiebreakers.
String standingsCsv(ServerController c, String tournamentId) {
  final report = c.statistics.tournamentReport(
    tournamentId,
    roster: c.rosterOf(tournamentId),
    dropped: c.droppedIn(tournamentId),
  );
  return _csv([
    ['rank', 'player', 'matchPoints', 'record', 'omw', 'gw', 'ogw', 'byes'],
    for (var i = 0; i < report.standings.length; i++)
      () {
        final row = report.standings[i];
        final tally = report.playerTallies[row.playerId];
        return [
          i + 1,
          c.players[row.playerId]?.nickname ?? row.playerId,
          row.matchPoints,
          tally?.match.toString() ?? '0-0',
          (row.omw * 100).toStringAsFixed(1),
          (row.gw * 100).toStringAsFixed(1),
          (row.ogw * 100).toStringAsFixed(1),
          row.byes,
        ];
      }(),
  ]);
}

/// Lifetime summary, one row per player.
String playerSummaryCsv(
  ServerController c, {
  StatFilter filter = const StatFilter(),
}) {
  final service = c.statistics;
  return _csv([
    [
      'player',
      'tournaments',
      'won',
      'matches',
      'wins',
      'losses',
      'draws',
      'matchWinPct',
      'gameWinPct',
      'rating',
      'ratingDeviation',
      'ratingEstablished',
    ],
    for (final id in service.playerIds)
      () {
        final r = service.playerReport(id, filter: filter);
        return [
          c.players[id]?.nickname ?? id,
          r.tournamentsPlayed,
          r.tournamentsWon,
          r.overall.match.matches,
          r.overall.match.wins,
          r.overall.match.losses,
          r.overall.match.draws,
          (r.overall.matchWin.point * 100).toStringAsFixed(1),
          (r.overall.gameWin.point * 100).toStringAsFixed(1),
          r.rating.rating.round(),
          r.rating.deviation.round(),
          r.rating.established,
        ];
      }(),
  ]);
}

/// Encode a bundle for sharing. Plain JSON so it stays inspectable.
String encodeBundle(Map<String, dynamic> bundle) => jsonEncode(bundle);

/// Decode a bundle, returning null when the text is not JSON object.
Map<String, dynamic>? decodeBundle(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}
