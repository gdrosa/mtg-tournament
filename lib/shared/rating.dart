/// Glicko-2 ratings over tournament history.
///
/// Glicko-2 rather than Elo because it carries a **rating deviation** — an
/// explicit "how much do we actually know about this player" — which is exactly
/// the uncertainty a club with a handful of events per year needs shown next to
/// every number. A 1700 ± 300 and a 1700 ± 60 are not the same claim.
///
/// Reference: Mark Glickman, "Example of the Glicko-2 system" (2013). One
/// tournament is one rating period; byes contribute nothing (no opponent).
///
/// PURE DART, no clock, no RNG — deterministic and unit-testable on Windows.
library;

import 'dart:math' as math;

/// Glickman's scale factor between the display (1500) and internal scales.
const double _scale = 173.7178;

/// Default starting rating / deviation / volatility.
const double kDefaultRating = 1500.0;
const double kDefaultDeviation = 350.0;
const double kDefaultVolatility = 0.06;

/// System constant τ: how fast volatility may move. 0.3–1.2 per Glickman;
/// 0.5 is the usual choice and is conservative for small player pools.
const double kTau = 0.5;

/// A player's rating at a point in time.
class Rating {
  final double rating;
  final double deviation;
  final double volatility;
  const Rating({
    this.rating = kDefaultRating,
    this.deviation = kDefaultDeviation,
    this.volatility = kDefaultVolatility,
  });

  /// Half-width of the 95% interval around [rating].
  double get confidence95 => 1.96 * deviation;

  /// Conservative "you are at least this good" figure, the usual way to rank
  /// by Glicko without letting a 1-event player top the table.
  double get conservative => rating - 2 * deviation;

  /// True once the deviation is small enough for the rating to mean something.
  /// 100 is a common provisional cut-off; below it a rating is still a guess.
  bool get established => deviation < 100;

  @override
  String toString() =>
      '${rating.round()} ± ${confidence95.round()}'
      '${established ? '' : ' (provisional)'}';
}

/// One rated result: the opponent's rating at the start of the period, and the
/// score from the subject's point of view (1 win, 0.5 draw, 0 loss).
class RatedGame {
  final Rating opponent;
  final double score;
  const RatedGame(this.opponent, this.score);
}

double _g(double phi) => 1 / math.sqrt(1 + 3 * phi * phi / (math.pi * math.pi));

double _e(double mu, double muJ, double phiJ) =>
    1 / (1 + math.exp(-_g(phiJ) * (mu - muJ)));

/// Advance [current] by one rating period containing [games].
///
/// With no games the rating is unchanged but the deviation grows — not playing
/// makes us less certain, which is the whole point of the system.
Rating updateRating(
  Rating current,
  List<RatedGame> games, {
  double tau = kTau,
}) {
  final mu = (current.rating - kDefaultRating) / _scale;
  final phi = current.deviation / _scale;
  final sigma = current.volatility;

  if (games.isEmpty) {
    final phiPrime = math.sqrt(phi * phi + sigma * sigma);
    return Rating(
      rating: current.rating,
      // Cap at the default: an unrated player and one who has not played for a
      // decade are equally unknown, and letting RD run away breaks the maths.
      deviation: math.min(phiPrime * _scale, kDefaultDeviation),
      volatility: sigma,
    );
  }

  var vInv = 0.0;
  var deltaSum = 0.0;
  for (final game in games) {
    final muJ = (game.opponent.rating - kDefaultRating) / _scale;
    final phiJ = game.opponent.deviation / _scale;
    final gj = _g(phiJ);
    final ej = _e(mu, muJ, phiJ);
    vInv += gj * gj * ej * (1 - ej);
    deltaSum += gj * (game.score - ej);
  }
  // A player who beat (or lost to) only maximally-uncertain opponents can make
  // vInv vanish; fall back to a huge variance rather than dividing by zero.
  final v = vInv <= 0 ? 1e12 : 1 / vInv;
  final delta = v * deltaSum;

  final sigmaPrime = _newVolatility(
    phi: phi,
    v: v,
    delta: delta,
    sigma: sigma,
    tau: tau,
  );

  final phiStar = math.sqrt(phi * phi + sigmaPrime * sigmaPrime);
  final phiPrime = 1 / math.sqrt(1 / (phiStar * phiStar) + 1 / v);
  final muPrime = mu + phiPrime * phiPrime * deltaSum;

  return Rating(
    rating: muPrime * _scale + kDefaultRating,
    deviation: math.min(phiPrime * _scale, kDefaultDeviation),
    volatility: sigmaPrime,
  );
}

/// Glickman's Illinois-variant root finder for the new volatility.
double _newVolatility({
  required double phi,
  required double v,
  required double delta,
  required double sigma,
  required double tau,
}) {
  const epsilon = 0.000001;
  final a = math.log(sigma * sigma);
  final phiSq = phi * phi;
  final deltaSq = delta * delta;

  double f(double x) {
    final ex = math.exp(x);
    final denom = phiSq + v + ex;
    return (ex * (deltaSq - phiSq - v - ex)) / (2 * denom * denom) -
        (x - a) / (tau * tau);
  }

  var bigA = a;
  double bigB;
  if (deltaSq > phiSq + v) {
    bigB = math.log(deltaSq - phiSq - v);
  } else {
    var k = 1;
    while (f(a - k * tau) < 0 && k < 100) {
      k++;
    }
    bigB = a - k * tau;
  }

  var fa = f(bigA);
  var fb = f(bigB);
  var guard = 0;
  while ((bigB - bigA).abs() > epsilon && guard++ < 100) {
    final c = bigA + (bigA - bigB) * fa / (fb - fa);
    final fc = f(c);
    if (fc * fb <= 0) {
      bigA = bigB;
      fa = fb;
    } else {
      fa = fa / 2;
    }
    bigB = c;
    fb = fc;
  }
  return math.exp(bigA / 2);
}

/// One entry in a player's rating history: where they stood after an event.
class RatingPoint {
  final String tournamentId;
  final String tournamentName;
  final DateTime date;
  final Rating rating;

  /// Rated (non-bye) matches this player had in that event.
  final int matches;
  const RatingPoint({
    required this.tournamentId,
    required this.tournamentName,
    required this.date,
    required this.rating,
    required this.matches,
  });

  /// Change in displayed rating versus the previous point.
  double deltaFrom(RatingPoint? previous) =>
      rating.rating - (previous?.rating.rating ?? kDefaultRating);
}
