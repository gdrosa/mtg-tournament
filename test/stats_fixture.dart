/// Shared helpers for the statistics / revision / questionnaire / interchange
/// tests. Not a test file itself (no `_test.dart` suffix), so `flutter test`
/// does not try to run it.
library;

import 'dart:math';

import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/persistence.dart';
import 'package:mtg_tourney/shared/models.dart';

/// A clock the tests move by hand, so questionnaire windows and revision
/// timestamps are exact instead of "whenever the test ran".
class TestClock {
  DateTime now;
  TestClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 1, 5, 12);

  void advance(Duration d) => now = now.add(d);
  DateTime call() => now;
}

ServerController controllerWith(
  TestClock clock, {
  int seed = 7,
  Persistence? store,
}) => ServerController(rng: Random(seed), clock: clock.call)..store = store;

/// Register a player with one deck. Returns the ids the tests drive.
({String playerId, String token, String deckId}) enrol(
  ServerController c,
  String nickname, {
  required String deckName,
  String archetype = '',
  String main = '',
  String side = '',
}) {
  final session = c.resolveSession(nickname, null);
  final deck = c.saveDeck(
    ownerId: session.playerId,
    name: deckName,
    archetype: archetype,
    mainboard: main,
    sideboard: side,
  );
  return (playerId: session.playerId, token: session.token, deckId: deck.id);
}

/// Both players report the same score, then both confirm no infraction —
/// the normal path to [MatchState.confirmed].
void confirmMatch(
  ServerController c,
  Match m,
  int p1Wins,
  int p2Wins, {
  int draws = 0,
}) {
  c.submitResult(
    playerId: m.p1Id,
    matchId: m.id,
    mineWon: p1Wins,
    oppWon: p2Wins,
    draws: draws,
  );
  c.submitResult(
    playerId: m.p2Id!,
    matchId: m.id,
    mineWon: p2Wins,
    oppWon: p1Wins,
    draws: draws,
  );
  c.confirmInfraction(playerId: m.p1Id, matchId: m.id, ok: true);
  c.confirmInfraction(playerId: m.p2Id!, matchId: m.id, ok: true);
}

/// The current round's first real (non-bye) match.
Match firstRealMatch(ServerController c) =>
    c.engine!.currentRound.matches.firstWhere((m) => !m.isBye);

/// Play every unresolved match of the current round. The player with the
/// higher [strength] wins 2-0, so a multi-round event is fully deterministic
/// whatever order the pairing engine seats people in.
void playRound(ServerController c, Map<String, int> strength) {
  for (final m in [...c.engine!.currentRound.matches]) {
    if (m.isBye || m.state == MatchState.confirmed) continue;
    final s1 = strength[m.p1Id] ?? 0;
    final s2 = strength[m.p2Id] ?? 0;
    confirmMatch(c, m, s1 >= s2 ? 2 : 0, s1 >= s2 ? 0 : 2);
  }
}

/// Enrol [nicknames] (one deck each) and run a full Swiss event to its end.
({String tournamentId, Map<String, String> players, Map<String, String> decks})
runLeagueEvent(
  ServerController c, {
  required String name,
  required List<String> nicknames,
  String format = 'Modern',
  String series = '',
  Map<String, String> archetypes = const {},
  bool archive = true,
}) {
  final players = <String, String>{};
  final decks = <String, String>{};
  for (final nick in nicknames) {
    final existing = c.players.values.where((p) => p.nickname == nick);
    if (existing.isNotEmpty) {
      players[nick] = existing.first.id;
      decks[nick] = c.decksOf(existing.first.id).first.id;
      continue;
    }
    final e = enrol(
      c,
      nick,
      deckName: '$nick deck',
      archetype: archetypes[nick] ?? '',
      main: '4 Ragavan',
    );
    players[nick] = e.playerId;
    decks[nick] = e.deckId;
  }

  c.createTournament(
    name: name,
    hostPlayerId: players[nicknames.first]!,
    format: format,
    series: series,
  );
  for (final nick in nicknames) {
    c.joinTournament(playerId: players[nick]!, deckId: decks[nick]!);
  }
  // Earlier in the list = stronger, so standings are predictable.
  final strength = {
    for (var i = 0; i < nicknames.length; i++)
      players[nicknames[i]]!: nicknames.length - i,
  };

  c.startTournament();
  playRound(c, strength);
  while (c.engine!.status == TournamentStatus.running &&
      c.engine!.rounds.length < c.engine!.plannedRounds) {
    c.advanceRound();
    if (c.engine!.status != TournamentStatus.running) break;
    playRound(c, strength);
  }

  final id = c.engine!.id;
  if (archive) c.clearTournament();
  return (tournamentId: id, players: players, decks: decks);
}

/// Run a complete one-round, two-player event and archive it.
///
/// [p1Wins]/[p2Wins] are from the *first-seated* player's point of view; the
/// engine may seat them either way round, so the helper orients the score.
({String tournamentId, String aId, String bId, String aDeck, String bDeck})
runTwoPlayerEvent(
  ServerController c, {
  required String name,
  String format = 'Modern',
  String series = '',
  String aNick = 'Ana',
  String bNick = 'Bo',
  String aDeck = 'Domain Zoo',
  String bDeck = 'Mono-Red',
  String aArchetype = '',
  String bArchetype = '',
  int aWins = 2,
  int bWins = 1,
  int draws = 0,
  bool archive = true,
}) {
  final a = enrol(
    c,
    aNick,
    deckName: aDeck,
    archetype: aArchetype,
    main: '4 Ragavan',
  );
  final b = enrol(
    c,
    bNick,
    deckName: bDeck,
    archetype: bArchetype,
    main: '4 Goblin Guide',
  );
  c.createTournament(
    name: name,
    hostPlayerId: a.playerId,
    format: format,
    series: series,
  );
  c.joinTournament(playerId: a.playerId, deckId: a.deckId);
  c.joinTournament(playerId: b.playerId, deckId: b.deckId);
  c.startTournament();

  final m = firstRealMatch(c);
  final aIsP1 = m.p1Id == a.playerId;
  confirmMatch(
    c,
    m,
    aIsP1 ? aWins : bWins,
    aIsP1 ? bWins : aWins,
    draws: draws,
  );

  final id = c.engine!.id;
  if (archive) c.clearTournament();
  return (
    tournamentId: id,
    aId: a.playerId,
    bId: b.playerId,
    aDeck: a.deckId,
    bDeck: b.deckId,
  );
}
