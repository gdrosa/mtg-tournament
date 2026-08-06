/// The optional post-match questionnaire.
///
/// Rules this file enforces, all of them product invariants:
///
/// * It only ever asks for **facts the app cannot derive** — per-game results,
///   mulligans, who was on the play, whether anyone sideboarded. Never opinions
///   ("was the matchup good?", "did you misplay?"): those would be noise wearing
///   the costume of data.
/// * It **never changes the confirmed result**. Answers are stored beside the
///   match as self-reported data and nothing reads them back into standings.
/// * It **expires** ([surveyWindow]) and can be closed early when the round
///   advances, so it can never gate the tournament.
/// * Each player's raw answers stay **private from the opponent** — see
///   [MatchSurvey.viewFor], the only shape a player-facing snapshot may carry.
/// * When both players answer, compatible facts are **cross-checked and
///   conflicts preserved**, never silently reconciled to one side.
///
/// PURE DART (no I/O, no Flutter, no implicit clock — `now` is always passed in)
/// so the whole lifecycle is deterministic and unit-testable on Windows.
library;

import 'models.dart';

/// How long a questionnaire stays answerable after the match is confirmed.
/// Long enough to fill in between rounds, short enough that nobody is answering
/// about a match they played an hour ago.
const Duration surveyWindow = Duration(minutes: 20);

/// A player's own result for one game.
enum GameOutcome { win, loss, draw, unknown }

/// Mulligans taken in one game, bucketed to keep it to one tap.
enum MulliganCount { zero, one, two, threePlus, unknown }

/// Yes / no / "don't remember" — the answer shape for every non-game question.
enum TriState { yes, no, unknown }

/// Thrown when a submitted questionnaire does not fit the match it answers.
class SurveyError implements Exception {
  final String message;
  SurveyError(this.message);
  @override
  String toString() => 'SurveyError: $message';
}

/// What to ask for one match: derived purely from how many games were played,
/// so a 2-0 asks about two games and a 2-1 about three.
class SurveyPrompt {
  final int gameCount;
  const SurveyPrompt(this.gameCount);

  /// Sideboarding is only a question once there was a game after game 1.
  bool get asksSideboard => gameCount > 1;

  /// Roughly how many taps this is — the 30-to-40-second budget in numbers.
  int get questionCount => gameCount * 2 + 1 + (asksSideboard ? 1 : 0);

  /// Build the prompt for a confirmed, non-bye match.
  static SurveyPrompt? forMatch(Match m) {
    final s = m.accepted;
    if (m.isBye || s == null || m.state != MatchState.confirmed) return null;
    final games = s.totalGames;
    if (games < 1 || games > 3) return null;
    return SurveyPrompt(games);
  }
}

/// One player's answers. Immutable once submitted; a re-submission replaces it
/// wholesale while the window is open.
class SurveyResponse {
  final String playerId;
  final DateTime submittedAt;

  /// Per-game outcome **from this player's own point of view**, game 1 first.
  final List<GameOutcome> games;

  /// Mulligans this player took, one entry per game, game 1 first.
  final List<MulliganCount> mulligans;

  /// Was this player on the play in game 1?
  final TriState onThePlayGame1;

  /// Did this player change cards between games?
  final TriState sideboarded;

  const SurveyResponse({
    required this.playerId,
    required this.submittedAt,
    required this.games,
    required this.mulligans,
    this.onThePlayGame1 = TriState.unknown,
    this.sideboarded = TriState.unknown,
  });

  /// Always true, and always carried into exports: nothing here was observed by
  /// the app, so no consumer may treat it as authoritative.
  bool get selfReported => true;

  /// True when the player skipped every question — kept as a distinct signal
  /// from "never opened it", which is simply the absence of a response.
  bool get isBlank =>
      games.every((g) => g == GameOutcome.unknown) &&
      mulligans.every((m) => m == MulliganCount.unknown) &&
      onThePlayGame1 == TriState.unknown &&
      sideboarded == TriState.unknown;

  /// Games this player says they won / lost / drew, ignoring "don't remember".
  int get reportedWins => games.where((g) => g == GameOutcome.win).length;
  int get reportedLosses => games.where((g) => g == GameOutcome.loss).length;
  int get reportedDraws => games.where((g) => g == GameOutcome.draw).length;

  Map<String, dynamic> toJson() => {
    'playerId': playerId,
    'at': submittedAt.toIso8601String(),
    'games': games.map((g) => g.name).toList(),
    'mulls': mulligans.map((m) => m.name).toList(),
    'play1': onThePlayGame1.name,
    'sb': sideboarded.name,
    'selfReported': true,
  };

  factory SurveyResponse.fromJson(Map j) => SurveyResponse(
    playerId: j['playerId'] as String,
    submittedAt: DateTime.parse(j['at'] as String),
    games: [
      for (final g in (j['games'] as List? ?? const []))
        GameOutcome.values.byName(g as String),
    ],
    mulligans: [
      for (final m in (j['mulls'] as List? ?? const []))
        MulliganCount.values.byName(m as String),
    ],
    onThePlayGame1: TriState.values.byName(
      (j['play1'] as String?) ?? 'unknown',
    ),
    sideboarded: TriState.values.byName((j['sb'] as String?) ?? 'unknown'),
  );
}

/// A disagreement between the two players' answers, or between an answer and
/// the confirmed result. Recorded, shown, and never auto-resolved.
enum ConflictKind {
  /// Both named a game 1 result that cannot both be true.
  gameResult,

  /// Both claim to have been on the play (or both on the draw) in game 1.
  playDraw,

  /// A player's own game tally contradicts the confirmed match result.
  resultTally,
}

class SurveyConflict {
  final ConflictKind kind;

  /// 1-based game number, or 0 when the conflict is about the match.
  final int game;
  final String detail;
  const SurveyConflict(this.kind, this.game, this.detail);

  @override
  String toString() => detail;
}

/// The questionnaire attached to one confirmed match: who may answer, until
/// when, what they said, and where their accounts disagree.
class MatchSurvey {
  final String tournamentId;
  final String matchId;
  final int gameCount;

  /// The two seated players. A bye never gets a survey.
  final List<String> playerIds;
  final DateTime openedAt;
  final DateTime expiresAt;

  /// The authoritative result in canonical (p1, p2) orientation, kept so the
  /// tally cross-check can run without reaching back into the engine.
  final GameScore accepted;
  final String p1Id;

  final Map<String, SurveyResponse> responses = {};

  /// Set when the round advanced: closed early, but answers already given stay.
  bool closed;

  MatchSurvey({
    required this.tournamentId,
    required this.matchId,
    required this.gameCount,
    required this.playerIds,
    required this.openedAt,
    required this.expiresAt,
    required this.accepted,
    required this.p1Id,
    this.closed = false,
  });

  SurveyPrompt get prompt => SurveyPrompt(gameCount);

  String get key => surveyKey(tournamentId, matchId);

  bool isOpen(DateTime now) => !closed && now.isBefore(expiresAt);

  bool hasAnswered(String playerId) => responses.containsKey(playerId);

  bool get bothAnswered => playerIds.every(responses.containsKey);

  /// Open a survey for a confirmed, non-bye match. Returns null when the match
  /// is not eligible (bye, unconfirmed, or an impossible game count).
  static MatchSurvey? open({
    required String tournamentId,
    required Match match,
    required DateTime now,
    Duration window = surveyWindow,
  }) {
    final p = SurveyPrompt.forMatch(match);
    if (p == null) return null;
    return MatchSurvey(
      tournamentId: tournamentId,
      matchId: match.id,
      gameCount: p.gameCount,
      playerIds: [match.p1Id, match.p2Id!],
      openedAt: now,
      expiresAt: now.add(window),
      accepted: match.accepted!,
      p1Id: match.p1Id,
    );
  }

  /// Record [response]. Throws [SurveyError] if the window has closed, the
  /// player is not in this match, or the answer shape does not fit the match.
  ///
  /// Deliberately has no side effect on the match: submitting, skipping and
  /// never answering are all identical as far as the tournament is concerned.
  void submit(SurveyResponse response, DateTime now) {
    if (!isOpen(now)) {
      throw SurveyError('This questionnaire has closed.');
    }
    if (!playerIds.contains(response.playerId)) {
      throw SurveyError('You did not play this match.');
    }
    if (response.games.length != gameCount ||
        response.mulligans.length != gameCount) {
      throw SurveyError('Expected answers for $gameCount games.');
    }
    responses[response.playerId] = response;
  }

  /// Cross-checks over compatible facts, run only once both sides answered.
  /// Every disagreement is returned; none of them is resolved here.
  List<SurveyConflict> get conflicts {
    final out = <SurveyConflict>[];
    for (final pid in playerIds) {
      final r = responses[pid];
      if (r == null) continue;
      out.addAll(_tallyConflicts(pid, r));
    }
    if (!bothAnswered) return out;

    final a = responses[playerIds[0]]!;
    final b = responses[playerIds[1]]!;
    for (var i = 0; i < gameCount; i++) {
      final x = a.games[i];
      final y = b.games[i];
      if (x == GameOutcome.unknown || y == GameOutcome.unknown) continue;
      final compatible =
          (x == GameOutcome.win && y == GameOutcome.loss) ||
          (x == GameOutcome.loss && y == GameOutcome.win) ||
          (x == GameOutcome.draw && y == GameOutcome.draw);
      if (!compatible) {
        out.add(
          SurveyConflict(
            ConflictKind.gameResult,
            i + 1,
            'Game ${i + 1}: both players reported ${x.name} / ${y.name}.',
          ),
        );
      }
    }
    if (a.onThePlayGame1 != TriState.unknown &&
        b.onThePlayGame1 != TriState.unknown &&
        a.onThePlayGame1 == b.onThePlayGame1) {
      out.add(
        SurveyConflict(
          ConflictKind.playDraw,
          1,
          a.onThePlayGame1 == TriState.yes
              ? 'Both players say they were on the play in game 1.'
              : 'Neither player says they were on the play in game 1.',
        ),
      );
    }
    return out;
  }

  /// A player's own tally versus the confirmed match result.
  List<SurveyConflict> _tallyConflicts(String pid, SurveyResponse r) {
    if (r.games.any((g) => g == GameOutcome.unknown)) return const [];
    final isP1 = pid == p1Id;
    final myWins = isP1 ? accepted.p1Wins : accepted.p2Wins;
    final myLosses = isP1 ? accepted.p2Wins : accepted.p1Wins;
    if (r.reportedWins == myWins &&
        r.reportedLosses == myLosses &&
        r.reportedDraws == accepted.draws) {
      return const [];
    }
    return [
      SurveyConflict(
        ConflictKind.resultTally,
        0,
        'Reported games (${r.reportedWins}-${r.reportedLosses}'
        '${r.reportedDraws > 0 ? '-${r.reportedDraws}' : ''}) do not match the '
        'confirmed result ($myWins-$myLosses'
        '${accepted.draws > 0 ? '-${accepted.draws}' : ''}).',
      ),
    ];
  }

  /// The **only** survey shape a player-facing snapshot may contain.
  ///
  /// A viewer sees their own answers and nothing but the bare fact that the
  /// opponent has or has not responded — never the opponent's answers, and
  /// never the conflicts (which would leak them by inference).
  Map<String, dynamic>? viewFor(String viewerId, DateTime now) {
    if (!playerIds.contains(viewerId)) return null;
    final opponent = playerIds.firstWhere((p) => p != viewerId);
    return {
      'matchId': matchId,
      'games': gameCount,
      'asksSideboard': prompt.asksSideboard,
      'open': isOpen(now),
      'expiresAt': expiresAt.toIso8601String(),
      'answered': hasAnswered(viewerId),
      'opponentAnswered': hasAnswered(opponent),
      'yours': responses[viewerId]?.toJson(),
      'selfReported': true,
    };
  }

  Map<String, dynamic> toJson() => {
    'tournamentId': tournamentId,
    'matchId': matchId,
    'games': gameCount,
    'players': playerIds,
    'openedAt': openedAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    'accepted': accepted.toJson(),
    'p1': p1Id,
    'closed': closed,
    'responses': responses.values.map((r) => r.toJson()).toList(),
  };

  factory MatchSurvey.fromJson(Map j) {
    final s = MatchSurvey(
      tournamentId: j['tournamentId'] as String,
      matchId: j['matchId'] as String,
      gameCount: (j['games'] as num).toInt(),
      playerIds: [for (final p in (j['players'] as List)) p as String],
      openedAt: DateTime.parse(j['openedAt'] as String),
      expiresAt: DateTime.parse(j['expiresAt'] as String),
      accepted: GameScore.fromJson(j['accepted'] as Map),
      p1Id: j['p1'] as String,
      closed: j['closed'] == true,
    );
    for (final r in (j['responses'] as List? ?? const [])) {
      final resp = SurveyResponse.fromJson(r as Map);
      s.responses[resp.playerId] = resp;
    }
    return s;
  }
}

/// Match ids are only unique inside a tournament, so surveys are keyed by both.
String surveyKey(String tournamentId, String matchId) =>
    '$tournamentId/$matchId';
