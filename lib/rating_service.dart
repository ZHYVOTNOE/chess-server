import 'dart:math';
import 'supabase_service.dart';

class RatingService {
  final SupabaseService _supabaseService;

  // Glicko-2 constants
  static const double _defaultRating = 1500;
  static const double _defaultRd = 350;
  static const double _defaultVolatility = 0.06;
  static const double _tau = 0.5; // system constant (controls volatility change speed)
  static const double _epsilon = 0.000001; // convergence tolerance

  RatingService(this._supabaseService);

  /// Calculate new ratings after a game using full Glicko-2 algorithm
  Future<Map<String, dynamic>> calculateRatings({
    required String whiteId,
    required String blackId,
    required String variantKey,
    required String timeControlType,
    required String result, // 'white', 'black', 'draw'
  }) async {
    final whiteRatingData = await _supabaseService.getRating(whiteId, variantKey, timeControlType);
    final blackRatingData = await _supabaseService.getRating(blackId, variantKey, timeControlType);

    final whiteRating = (whiteRatingData?['rating'] as int? ?? _defaultRating.toInt()).toDouble();
    final blackRating = (blackRatingData?['rating'] as int? ?? _defaultRating.toInt()).toDouble();

    final whiteRd = (whiteRatingData?['rd'] as num? ?? _defaultRd).toDouble();
    final blackRd = (blackRatingData?['rd'] as num? ?? _defaultRd).toDouble();
    final whiteVolatility = (whiteRatingData?['volatility'] as num? ?? _defaultVolatility).toDouble();
    final blackVolatility = (blackRatingData?['volatility'] as num? ?? _defaultVolatility).toDouble();

    final whiteLastUpdated = whiteRatingData?['last_updated_at'] != null
        ? DateTime.parse(whiteRatingData!['last_updated_at'] as String)
        : DateTime.now();
    final blackLastUpdated = blackRatingData?['last_updated_at'] != null
        ? DateTime.parse(blackRatingData!['last_updated_at'] as String)
        : DateTime.now();

    final whiteRdAfterInactivity = _applyInactivity(whiteRd, whiteLastUpdated);
    final blackRdAfterInactivity = _applyInactivity(blackRd, blackLastUpdated);

    double actualWhite;
    double actualBlack;

    switch (result.toLowerCase()) {
      case 'white':
        actualWhite = 1.0;
        actualBlack = 0.0;
        break;
      case 'black':
        actualWhite = 0.0;
        actualBlack = 1.0;
        break;
      default: // draw
        actualWhite = 0.5;
        actualBlack = 0.5;
    }

    final whiteResult = _calculateNewRating(
      rating: whiteRating,
      rd: whiteRdAfterInactivity,
      volatility: whiteVolatility,
      actualScore: actualWhite,
      opponentRating: blackRating,
      opponentRd: blackRdAfterInactivity,
    );

    final blackResult = _calculateNewRating(
      rating: blackRating,
      rd: blackRdAfterInactivity,
      volatility: blackVolatility,
      actualScore: actualBlack,
      opponentRating: whiteRating,
      opponentRd: whiteRdAfterInactivity,
    );

    return {
      'white_rating': whiteResult['rating']!.round(),
      'white_rd': whiteResult['rd']!,
      'white_volatility': whiteResult['volatility']!,
      'black_rating': blackResult['rating']!.round(),
      'black_rd': blackResult['rd']!,
      'black_volatility': blackResult['volatility']!,
    };
  }

  Future<void> updateRatings({
    required String gameId,
    required String whiteId,
    required String blackId,
    required String variantKey,
    required String timeControlType,
    required String result,
  }) async {
    final newRatings = await calculateRatings(
      whiteId: whiteId,
      blackId: blackId,
      variantKey: variantKey,
      timeControlType: timeControlType,
      result: result,
    );

    final whiteRatingData = await _supabaseService.getRating(whiteId, variantKey, timeControlType);
    final blackRatingData = await _supabaseService.getRating(blackId, variantKey, timeControlType);

    final oldWhiteRating = (whiteRatingData?['rating'] as int? ?? _defaultRating.toInt());
    final oldBlackRating = (blackRatingData?['rating'] as int? ?? _defaultRating.toInt());

    await _supabaseService.updateRating(
      userId: whiteId,
      variantKey: variantKey,
      timeControlType: timeControlType,
      rating: newRatings['white_rating'] as int,
      rd: newRatings['white_rd'] as double,
      volatility: newRatings['white_volatility'] as double,
    );

    await _supabaseService.updateRating(
      userId: blackId,
      variantKey: variantKey,
      timeControlType: timeControlType,
      rating: newRatings['black_rating'] as int,
      rd: newRatings['black_rd'] as double,
      volatility: newRatings['black_volatility'] as double,
    );

    await _supabaseService.addRatingHistory(
      userId: whiteId,
      gameId: gameId,
      oldRating: oldWhiteRating,
      newRating: newRatings['white_rating'] as int,
      variantKey: variantKey,
      timeControlType: timeControlType,
    );

    await _supabaseService.addRatingHistory(
      userId: blackId,
      gameId: gameId,
      oldRating: oldBlackRating,
      newRating: newRatings['black_rating'] as int,
      variantKey: variantKey,
      timeControlType: timeControlType,
    );
  }

  // Apply inactivity RD increase (Glicko-2 step 6)
  double _applyInactivity(double rd, DateTime lastUpdated) {
    final daysSinceUpdate = DateTime.now().difference(lastUpdated).inDays;
    if (daysSinceUpdate <= 0) return rd;

    // c ≈ 20 per period — standard Glicko-2 inactivity increase
    const double c = 20.0;
    final newRd = sqrt(pow(rd, 2) + pow(c, 2) * daysSinceUpdate);
    return newRd.clamp(0.0, 350.0);
  }

  // g(RD) function from Glicko-2
  double _gFactor(double rd) {
    return 1.0 / sqrt(1.0 + 3.0 * pow(rd / 400.0, 2) / pow(pi, 2));
  }

  // Expected score E(s|µ,µj,φj)
  double _expectedScore(double rating, double opponentRating, double opponentRd) {
    final g = _gFactor(opponentRd);
    return 1.0 / (1.0 + exp(-g * (rating - opponentRating) / 400.0));
  }

  /// Full Glicko-2 new rating calculation (single opponent version)
  Map<String, double> _calculateNewRating({
    required double rating,
    required double rd,
    required double volatility,
    required double actualScore,
    required double opponentRating,
    required double opponentRd,
  }) {
    final g = _gFactor(opponentRd);
    final e = _expectedScore(rating, opponentRating, opponentRd);

    // Step 3: Compute variance v
    final v = 1.0 / (pow(g, 2) * e * (1.0 - e));

    // Step 4: Compute delta
    final delta = v * g * (actualScore - e);

    // Step 5: Compute new volatility using Illinois algorithm
    final newVolatility = _computeNewVolatility(
      volatility: volatility,
      delta: delta,
      v: v,
      rd: rd,
    );

    // Step 6: Update RD
    final rdStar = sqrt(pow(rd, 2) + pow(newVolatility, 2));

    // Step 7: Update RD with new information
    final newRd = 1.0 / sqrt(1.0 / pow(rdStar, 2) + 1.0 / v);

    // Step 8: Update rating
    final newRating = rating + pow(newRd, 2) * g * (actualScore - e);

    return {
      'rating': newRating,
      'rd': newRd,
      'volatility': newVolatility,
    };
  }

  /// ✅ Correct Glicko-2 volatility via Illinois algorithm (RFC 5905 / Glickman 2012)
  double _computeNewVolatility({
    required double volatility,
    required double delta,
    required double v,
    required double rd,
  }) {
    final a = log(pow(volatility, 2));

    // f(x) as defined in Glicko-2 paper
    double f(double x) {
      final ex = exp(x);
      final rdSq = pow(rd, 2);
      final num1 = ex * (pow(delta, 2) - rdSq - v - ex);
      final den1 = 2.0 * pow(rdSq + v + ex, 2);
      return num1 / den1 - (x - a) / pow(_tau, 2);
    }

    // Illinois method bracketing
    double A = a;
    double B;

    if (pow(delta, 2) > pow(rd, 2) + v) {
      B = log(pow(delta, 2) - pow(rd, 2) - v);
    } else {
      double k = 1;
      while (f(a - k * _tau) < 0) {
        k += 1;
      }
      B = a - k * _tau;
    }

    double fA = f(A);
    double fB = f(B);

    // Iterative bisection
    for (int i = 0; i < 1000; i++) {
      final C = A + (A - B) * fA / (fB - fA);
      final fC = f(C);

      if (fC * fB <= 0) {
        A = B;
        fA = fB;
      } else {
        fA /= 2.0;
      }

      B = C;
      fB = fC;

      if ((B - A).abs() < _epsilon) break;
    }

    return exp(A / 2.0);
  }
}