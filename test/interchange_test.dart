import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/interchange.dart';
import 'package:mtg_tourney/services/export_data.dart';
import 'package:mtg_tourney/shared/questionnaire.dart';

import 'stats_fixture.dart';

/// Import/export has three promises: it adds without deleting, it does nothing
/// twice, and it never carries credentials or another player's private answers.
void main() {
  group('round trip', () {
    test('a full bundle rebuilds the same statistics on a fresh device', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      final ids = runLeagueEvent(
        source,
        name: 'Friday',
        nicknames: ['Ana', 'Bo', 'Cy'],
        format: 'Modern',
        series: 'Spring',
      );

      final bundle = buildBundle(source, scope: BundleScope.full);
      final target = controllerWith(clock, seed: 99);
      final result = mergeBundle(target, bundle);

      expect(result.ok, isTrue);
      expect(target.archive, hasLength(1));
      expect(target.archive.single.format, 'Modern');
      expect(target.archive.single.series, 'Spring');

      final ana = ids.players['Ana']!;
      final before = source.statistics.playerReport(ana);
      final after = target.statistics.playerReport(ana);
      expect(after.overall.match.wins, before.overall.match.wins);
      expect(after.tournamentsWon, before.tournamentsWon);
      expect(after.averageFinish, before.averageFinish);
    });

    test(
      'the exact revision travels, so the shared list is the played one',
      () {
        final clock = TestClock();
        final source = controllerWith(clock);
        final ids = runTwoPlayerEvent(source, name: 'Friday');
        final played = source.revisionsOf(ids.aDeck).single;

        final target = controllerWith(clock, seed: 5);
        mergeBundle(
          target,
          buildBundle(
            source,
            scope: BundleScope.tournament,
            tournamentId: ids.tournamentId,
          ),
        );

        final entry = target.archive.single.entryOf(ids.aId)!;
        final revision = target.revisionOf(entry)!;
        expect(revision.id, played.id);
        expect(revision.mainboardText, played.mainboardText);
        expect(revision.migrated, isFalse);
      },
    );

    test('a JSON encode/decode cycle survives intact', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      runTwoPlayerEvent(source, name: 'Friday');
      final text = encodeBundle(buildBundle(source, scope: BundleScope.full));
      final decoded = decodeBundle(text)!;

      final target = controllerWith(clock, seed: 3);
      expect(mergeBundle(target, decoded).ok, isTrue);
      expect(target.archive, hasLength(1));
    });
  });

  group('cumulative and idempotent', () {
    test('importing keeps everything already on the device', () {
      final clock = TestClock();
      final mine = controllerWith(clock);
      final myIds = runTwoPlayerEvent(
        mine,
        name: 'My event',
        aNick: 'Me',
        bNick: 'Neighbour',
      );

      final theirs = controllerWith(clock, seed: 42);
      runTwoPlayerEvent(
        theirs,
        name: 'Their event',
        aNick: 'Zed',
        bNick: 'Yan',
      );

      mergeBundle(mine, buildBundle(theirs, scope: BundleScope.full));

      expect(mine.archive, hasLength(2));
      expect(
        mine.archive.map((t) => t.name),
        containsAll(['My event', 'Their event']),
      );
      // My own history is untouched.
      expect(mine.statistics.playerReport(myIds.aId).tournamentsPlayed, 1);
      expect(mine.decks.containsKey(myIds.aDeck), isTrue);
    });

    test('importing the same bundle twice changes nothing', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      runTwoPlayerEvent(source, name: 'Friday');
      final bundle = buildBundle(source, scope: BundleScope.full);

      final target = controllerWith(clock, seed: 8);
      final first = mergeBundle(target, bundle);
      final snapshot = jsonEncode(target.toJson());

      final preview = previewBundle(target, bundle);
      expect(preview.isNoOp, isTrue);

      final second = mergeBundle(target, bundle);
      expect(second.addedTournaments, 0);
      expect(second.skippedTournaments, first.addedTournaments);
      expect(second.addedPlayers, 0);
      expect(second.addedDecks, 0);
      expect(jsonEncode(target.toJson()), snapshot);
    });

    test('a local deck with the same id is never overwritten', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      final ids = runTwoPlayerEvent(source, name: 'Friday');
      final bundle = buildBundle(source, scope: BundleScope.full);

      final target = controllerWith(clock, seed: 11);
      mergeBundle(target, bundle);
      // Edit the deck locally, then re-import.
      target.saveDeck(
        ownerId: ids.aId,
        deckId: ids.aDeck,
        name: 'Domain Zoo',
        mainboard: '4 Psychic Frog',
        sideboard: '',
      );
      mergeBundle(target, bundle);
      expect(target.decks[ids.aDeck]!.mainboardText, '4 Psychic Frog');
      // …and the history still points at the list that was actually played.
      final revision = target.revisionOf(
        target.archive.single.entryOf(ids.aId)!,
      )!;
      expect(revision.mainboardText, isNot(contains('Psychic Frog')));
    });
  });

  group('player identity', () {
    test('a shared nickname is suggested, never merged on its own', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      runTwoPlayerEvent(source, name: 'Theirs', aNick: 'Mike', bNick: 'Zed');

      final target = controllerWith(clock, seed: 21);
      runTwoPlayerEvent(target, name: 'Mine', aNick: 'Mike', bNick: 'Yan');

      final bundle = buildBundle(source, scope: BundleScope.full);
      final preview = previewBundle(target, bundle);
      expect(preview.identitySuggestions, isNotEmpty);
      expect(preview.identitySuggestions.first.incomingNickname, 'Mike');

      mergeBundle(target, bundle); // no identity map supplied
      final mikes = target.players.values.where((p) => p.nickname == 'Mike');
      expect(mikes, hasLength(2), reason: 'two Mikes stay two people');
    });

    test('a confirmed merge rewrites every reference to that player', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      final theirIds = runTwoPlayerEvent(
        source,
        name: 'Theirs',
        aNick: 'Mike',
        bNick: 'Zed',
      );

      final target = controllerWith(clock, seed: 22);
      final myIds = runTwoPlayerEvent(
        target,
        name: 'Mine',
        aNick: 'Mike',
        bNick: 'Yan',
      );

      final bundle = buildBundle(source, scope: BundleScope.full);
      mergeBundle(target, bundle, identityMap: {theirIds.aId: myIds.aId});

      expect(
        target.players.values.where((p) => p.nickname == 'Mike'),
        hasLength(1),
      );
      // Both events now belong to the one Mike.
      expect(target.statistics.playerReport(myIds.aId).tournamentsPlayed, 2);
      final imported = target.archive.firstWhere((t) => t.name == 'Theirs');
      expect(imported.entryOf(myIds.aId), isNotNull);
      expect(imported.entryOf(theirIds.aId), isNull);
      for (final round in imported.rounds) {
        for (final m in round.matches) {
          expect(m.p1Id, isNot(theirIds.aId));
          expect(m.p2Id, isNot(theirIds.aId));
          expect(m.submissions.keys, isNot(contains(theirIds.aId)));
        }
      }
    });

    test('a previous nickname is offered as a suggestion too', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      final mikey = enrol(source, 'Mikey', deckName: 'Zoo', main: '4 Ragavan');
      source.resolveSession('Michael', mikey.token); // renamed since
      expect(source.playerAliases[mikey.playerId], contains('Mikey'));

      final zed = enrol(source, 'Zed', deckName: 'Burn');
      source.createTournament(name: 'Theirs', hostPlayerId: mikey.playerId);
      source.joinTournament(playerId: mikey.playerId, deckId: mikey.deckId);
      source.joinTournament(playerId: zed.playerId, deckId: zed.deckId);
      source.startTournament();
      confirmMatch(source, firstRealMatch(source), 2, 0);
      source.clearTournament();

      final target = controllerWith(clock, seed: 23);
      target.resolveSession('Mikey', null);

      final preview = previewBundle(
        target,
        buildBundle(source, scope: BundleScope.full),
      );
      expect(
        preview.identitySuggestions.map((s) => s.reason).join(),
        contains('Previously known as'),
      );
    });
  });

  group('validation and atomicity', () {
    test('a file that is not a bundle is refused', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final preview = previewBundle(c, {'hello': 'world'});
      expect(preview.canImport, isFalse);
      expect(mergeBundle(c, {'hello': 'world'}).ok, isFalse);
    });

    test('a bundle from a newer app is refused rather than half-read', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      runTwoPlayerEvent(source, name: 'Friday');
      final bundle = buildBundle(source, scope: BundleScope.full)
        ..['version'] = kInterchangeVersion + 1;

      final target = controllerWith(clock, seed: 31);
      final preview = previewBundle(target, bundle);
      expect(preview.canImport, isFalse);
      expect(preview.errors.single, contains('newer version'));
      expect(mergeBundle(target, bundle).ok, isFalse);
      expect(target.archive, isEmpty);
    });

    test('a malformed bundle leaves existing data untouched', () {
      final clock = TestClock();
      final target = controllerWith(clock);
      runTwoPlayerEvent(target, name: 'Mine');
      final before = jsonEncode(target.toJson());

      final broken = buildBundle(target, scope: BundleScope.full);
      broken['tournaments'] = [
        {'id': 'x'}, // missing every required field
      ];
      expect(mergeBundle(target, broken).ok, isFalse);
      expect(jsonEncode(target.toJson()), before);
    });

    test('previewing never mutates the controller', () {
      final clock = TestClock();
      final source = controllerWith(clock);
      runTwoPlayerEvent(source, name: 'Theirs');
      final target = controllerWith(clock, seed: 33);
      final before = jsonEncode(target.toJson());
      previewBundle(target, buildBundle(source, scope: BundleScope.full));
      expect(jsonEncode(target.toJson()), before);
    });
  });

  group('privacy', () {
    test('no bundle ever carries session credentials', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      runTwoPlayerEvent(c, name: 'Friday', archive: false);
      for (final scope in BundleScope.values) {
        final text = encodeBundle(
          buildBundle(
            c,
            scope: scope,
            tournamentId: c.engine?.id,
            playerId: c.ownerPlayerId,
          ),
        );
        expect(text, isNot(contains('"tokens"')));
        expect(text, isNot(contains('"ownerToken"')));
        expect(text, isNot(contains('"joinCode"')));
        if (c.ownerToken != null) {
          expect(text, isNot(contains(c.ownerToken!)));
        }
      }
    });

    test('questionnaire answers only travel in a private full backup', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ana = enrol(c, 'Ana', deckName: 'Zoo');
      final bo = enrol(c, 'Bo', deckName: 'Burn');
      c.createTournament(name: 'Friday', hostPlayerId: ana.playerId);
      c.joinTournament(playerId: ana.playerId, deckId: ana.deckId);
      c.joinTournament(playerId: bo.playerId, deckId: bo.deckId);
      c.startTournament();
      final m = firstRealMatch(c);
      confirmMatch(c, m, 2, 0);
      c.submitSurvey(
        playerId: ana.playerId,
        matchId: m.id,
        games: const [GameOutcome.win, GameOutcome.win],
        mulligans: const [MulliganCount.threePlus, MulliganCount.zero],
      );
      final tournamentId = c.engine!.id;
      c.clearTournament();

      final shared = encodeBundle(
        buildBundle(
          c,
          scope: BundleScope.tournament,
          tournamentId: tournamentId,
        ),
      );
      expect(shared, isNot(contains('threePlus')));
      expect(shared, isNot(contains('"surveys"')));

      final private = encodeBundle(buildBundle(c, scope: BundleScope.full));
      expect(private, contains('threePlus'));
    });

    test('the share-sheet export strips tokens and questionnaires', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ana = enrol(c, 'Ana', deckName: 'Zoo');
      final bo = enrol(c, 'Bo', deckName: 'Burn');
      c.createTournament(name: 'Friday', hostPlayerId: ana.playerId);
      c.joinTournament(playerId: ana.playerId, deckId: ana.deckId);
      c.joinTournament(playerId: bo.playerId, deckId: bo.deckId);
      c.startTournament();
      final m = firstRealMatch(c);
      confirmMatch(c, m, 2, 0);
      c.submitSurvey(
        playerId: ana.playerId,
        matchId: m.id,
        games: const [GameOutcome.win, GameOutcome.win],
        mulligans: const [MulliganCount.threePlus, MulliganCount.zero],
      );

      final export = buildExport(c, clock.now);
      final text = utf8.decode(gzip.decode(export.bytes));
      expect(text, isNot(contains('"tokens"')));
      expect(text, isNot(contains('"surveys"')));
      expect(text, isNot(contains('threePlus')));
      expect(text, isNot(contains(c.joinCode!)));
    });

    test('the aggregate export carries no identities at all', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      runLeagueEvent(
        c,
        name: 'Friday',
        nicknames: ['Ana', 'Bo'],
        archetypes: {'Ana': 'Zoo', 'Bo': 'Burn'},
      );
      final text = jsonEncode(buildAggregateExport(c));
      expect(text, contains('Zoo'));
      expect(text, isNot(contains('Ana')));
      expect(text, isNot(contains('Bo')));
      expect(text, isNot(contains('Ragavan')));
      expect(text, isNot(contains(c.players.keys.first)));
      // It is not importable, by design.
      expect(previewBundle(c, jsonDecode(text) as Map).canImport, isFalse);
    });
  });

  group('CSV', () {
    test('matches export has a header and one row per settled match', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      runLeagueEvent(c, name: 'Friday', nicknames: ['Ana', 'Bo', 'Cy']);
      final csv = matchesCsv(c);
      final lines = csv.split('\n');
      expect(lines.first, startsWith('date,tournament,format'));
      expect(lines.length - 1, c.statistics.facts.length);
      expect(csv, contains('Ana'));
    });

    test('fields containing a comma or a quote are escaped', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      runTwoPlayerEvent(c, name: 'Friday, the "big" one');
      final csv = matchesCsv(c);
      expect(csv, contains('"Friday, the ""big"" one"'));
    });

    test('standings and player summaries export', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runLeagueEvent(
        c,
        name: 'Friday',
        nicknames: ['Ana', 'Bo', 'Cy'],
      );
      final standings = standingsCsv(c, ids.tournamentId);
      expect(standings.split('\n').first, startsWith('rank,player'));
      expect(standings.split('\n').length, 4); // header + three players

      final players = playerSummaryCsv(c);
      expect(players.split('\n').first, contains('rating'));
      expect(players, contains('Ana'));
    });
  });

  group('scopes', () {
    test('a tournament bundle carries only that event and its people', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final first = runTwoPlayerEvent(
        c,
        name: 'One',
        aNick: 'Ana',
        bNick: 'Bo',
      );
      clock.advance(const Duration(days: 7));
      runTwoPlayerEvent(c, name: 'Two', aNick: 'Cy', bNick: 'Di');

      final bundle = buildBundle(
        c,
        scope: BundleScope.tournament,
        tournamentId: first.tournamentId,
      );
      expect((bundle['tournaments'] as List), hasLength(1));
      final text = encodeBundle(bundle);
      expect(text, contains('Ana'));
      expect(text, isNot(contains('Cy')));
    });

    test('a deck library carries lists but no results', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runTwoPlayerEvent(c, name: 'One');
      final bundle = buildBundle(
        c,
        scope: BundleScope.deckLibrary,
        playerId: ids.aId,
      );
      expect(bundle['tournaments'], isEmpty);
      expect((bundle['decks'] as List), isNotEmpty);

      final target = controllerWith(clock, seed: 44);
      final result = mergeBundle(target, bundle);
      expect(result.addedDecks, greaterThan(0));
      expect(target.archive, isEmpty);
    });
  });
}
