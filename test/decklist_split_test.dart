import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/shared/cards.dart';

/// A real 60 + 15 export, with printing tags and a `// SIDEBOARD` marker.
const _pasted = '''
1 Chromatic Star (TSR) 263
1 Emry, Lurker of the Loch (EOC) 71
4 Goblin Engineer (MH1) 128
2 Island (SOS) 274
4 Kappa Cannoneer (EOC) 74
3 Memnite (SOM) 174
3 Metallic Rebuke (2XM) 59
4 Mishra's Bauble (2XM) 274
1 Mountain (SOS) 278
4 Mox Opal (2XM) 275
4 Ornithopter (DMR) 233
1 Otawara, Soaring City (NEO) 271
4 Pinnacle Emissary (EOE) 223
1 Shadowspear (THB) 236
3 Shivan Reef (SOC) 404
1 Sokenzan, Crucible of Defiance (NEO) 276
4 Spirebluff Canal (OTJ) 270
3 Springleaf Drum (ECL) 260
2 Steam Vents (ECL) 267
1 The Ten Rings (MSH) 251
4 Trash for Treasure (2XM) 148
4 Urza's Saga (MH2) 259
1 Welding Jar (2XM) 307

// SIDEBOARD
2 Abrade (SOC) 234
1 Aether Spellbomb (MMA) 196
3 Consign to Memory (MH3) 54
2 Damping Sphere (DMR) 219
2 Galvanic Blast (2XM) 125
1 Pithing Needle (RVR) 463
2 Tormod's Crypt (DMR) 235
2 Whipflare (CM2) 130
''';

int _count(String text) =>
    parseDecklist(text).fold(0, (sum, line) => sum + line.qty);

void main() {
  test('a SIDEBOARD marker splits the paste and keeps printing tags', () {
    final split = splitDecklistText(_pasted);

    expect(_count(split.main), 60);
    expect(_count(split.side), 15);
    // Lines survive verbatim — the set and collector number are not rewritten.
    expect(split.main, contains('1 Chromatic Star (TSR) 263'));
    expect(split.side, contains('2 Whipflare (CM2) 130'));
    expect(split.side, isNot(contains('Welding Jar')));
    expect(split.main, isNot(contains('Abrade')));

    // Names with commas, apostrophes and printing tags still parse.
    final names = parseDecklist(split.main).map((l) => l.name);
    expect(names, contains('Otawara, Soaring City'));
    expect(names, contains("Urza's Saga"));
    expect(names, contains('The Ten Rings'));
  });

  test('a 75-card list with no marker splits into the last 15', () {
    final unmarked = _pasted.replaceAll('// SIDEBOARD\n', '');
    final split = splitDecklistText(unmarked);

    expect(_count(split.main), 60);
    expect(_count(split.side), 15);
    expect(split.side, contains('2 Abrade (SOC) 234'));
    expect(split.main, isNot(contains('Abrade')));
  });

  test('a stack straddling the 60/15 boundary is divided', () {
    final split = splitDecklistText('56 Island\n4 Mountain\n15 Forest');
    expect(_count(split.main), 60);
    expect(_count(split.side), 15);

    // 16 Forest: 1 stays in the maindeck, 15 move across.
    final straddle = splitDecklistText('44 Island\n15 Mountain\n16 Forest');
    expect(_count(straddle.main), 60);
    expect(straddle.main, contains('1 Forest'));
    expect(straddle.side, '15 Forest');
  });

  test('any other size stays in the maindeck rather than being guessed', () {
    final split = splitDecklistText('4 Lightning Bolt\n56 Mountain');
    expect(_count(split.main), 60);
    expect(split.side, isEmpty);

    final commander = splitDecklistText('1 Sol Ring\n99 Island');
    expect(_count(commander.main), 100);
    expect(commander.side, isEmpty);
  });

  test('other sideboard spellings are recognised', () {
    for (final marker in ['Sideboard', 'SIDEBOARD:', '# Side', 'SB:']) {
      final split = splitDecklistText('4 Island\n$marker\n2 Abrade');
      expect(_count(split.main), 4, reason: marker);
      expect(_count(split.side), 2, reason: marker);
    }
  });
}
