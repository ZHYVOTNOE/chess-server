import 'dart:math';
import 'supabase_service.dart';

class RatingService {
  final SupabaseService _supabaseService;
  
  // Glicko-2 constants
  static const double _defaultRating = 1500;
  static const double _defaultVolatility = 0.06;
  
  // Volatility stored in memory (lost on server restart)
  final Map<String, double> _volatilityCache = {};

  RatingService(this._supabaseService);

  /// Calculate new ratings after a game using Glicko-2 algorithm
  Future<Map<String, int>> calculateRatings({
    required String whiteId,
    required String blackId,
    required String variantKey,
    required String timeControlType,
    required String result, // 'white', 'black', 'draw'
    required int ratingRange, // RD parameter from matchmaking
  }) async {
    // Get current ratings
    final whiteRatingData = await _supabaseService.getRating(whiteId, variantKey, timeControlType);
    final blackRatingData = await _supabaseService.getRating(blackId, variantKey, timeControlType);

    final whiteRating = (whiteRatingData?['rating'] as int? ?? _defaultRating.toInt()).toDouble();
    final blackRating = (blackRatingData?['rating'] as int? ?? _defaultRating.toInt()).toDouble();

    // Get volatility from cache or use default
    final whiteVolatility = _volatilityCache['$whiteId-$variantKey-$timeControlType'] ?? _defaultVolatility;
    final blackVolatility = _volatilityCache['$blackId-$variantKey-$timeControlType'] ?? _defaultVolatility;

    // Use ratingRange as RD parameter
    final whiteRd = ratingRange.toDouble();
    final blackRd = ratingRange.toDouble();

    // Calculate expected scores
    final expectedWhite = _expectedScore(whiteRating, blackRating, whiteRd);
    final expectedBlack = _expectedScore(blackRating, whiteRating, blackRd);

    // Determine actual scores
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
      case 'draw':
        actualWhite = 0.5;
        actualBlack = 0.5;
        break;
      default:
        actualWhite = 0.5;
        actualBlack = 0.5;
    }

    // Calculate new ratings using Glicko-2
    final newWhiteRating = _calculateNewRating(
      rating: whiteRating,
      rd: whiteRd,
      volatility: whiteVolatility,
      expectedScore: expectedWhite,
      actualScore: actualWhite,
    );
    final newBlackRating = _calculateNewRating(
      rating: blackRating,
      rd: blackRd,
      volatility: blackVolatility,
      expectedScore: expectedBlack,
      actualScore: actualBlack,
    );

    // Update volatility cache
    _volatilityCache['$whiteId-$variantKey-$timeControlType'] = whiteVolatility;
    _volatilityCache['$blackId-$variantKey-$timeControlType'] = blackVolatility;

    return {
      'white': newWhiteRating.round(),
      'black': newBlackRating.round(),
    };
  }

  /// Update ratings in Supabase and record history
  Future<void> updateRatings({
    required String gameId,
    required String whiteId,
    required String blackId,
    required String variantKey,
    required String timeControlType,
    required String result,
    required int ratingRange,
  }) async {
    // Calculate new ratings
    final newRatings = await calculateRatings(
      whiteId: whiteId,
      blackId: blackId,
      variantKey: variantKey,
      timeControlType: timeControlType,
      result: result,
      ratingRange: ratingRange,
    );

    // Get old ratings for history
    final whiteRatingData = await _supabaseService.getRating(whiteId, variantKey, timeControlType);
    final blackRatingData = await _supabaseService.getRating(blackId, variantKey, timeControlType);

    final oldWhiteRating = (whiteRatingData?['rating'] as int? ?? _defaultRating.toInt()).toDouble();
    final oldBlackRating = (blackRatingData?['rating'] as int? ?? _defaultRating.toInt()).toDouble();

    // Update ratings in Supabase
    await _supabaseService.updateRating(
      userId: whiteId,
      variantKey: variantKey,
      timeControlType: timeControlType,
      rating: newRatings['white']!.toInt(),
    );

    await _supabaseService.updateRating(
      userId: blackId,
      variantKey: variantKey,
      timeControlType: timeControlType,
      rating: newRatings['black']!.toInt(),
    );

    // Record rating history
    await _supabaseService.addRatingHistory(
      userId: whiteId,
      gameId: gameId,
      oldRating: oldWhiteRating.toInt(),
      newRating: newRatings['white']!.toInt(),
      variantKey: variantKey,
      timeControlType: timeControlType,
    );

    await _supabaseService.addRatingHistory(
      userId: blackId,
      gameId: gameId,
      oldRating: oldBlackRating.toInt(),
      newRating: newRatings['black']!.toInt(),
      variantKey: variantKey,
      timeControlType: timeControlType,
    );
  }

  /// Calculate expected score in Glicko-2
  double _expectedScore(double rating1, double rating2, double rd) {
    final g = _gFactor(rd);
    final diff = (rating2 - rating1) / 400.0;
    return 1.0 / (1.0 + exp(-g * diff));
  }

  /// Calculate g factor in Glicko-2
  double _gFactor(double rd) {
    return 1.0 / sqrt(1.0 + 3.0 * pow(rd, 2) / pow(pi, 2));
  }

  /// Calculate new rating using Glicko-2 algorithm
  double _calculateNewRating({
    required double rating,
    required double rd,
    required double volatility,
    required double expectedScore,
    required double actualScore,
  }) {
    final g = _gFactor(rd);
    final e = expectedScore;
    final s = actualScore;

    // Calculate new volatility (simplified)
    final newVolatility = volatility;

    // Calculate new RD
    final newRd = sqrt(pow(rd, 2) + pow(newVolatility, 2));

    // Calculate new rating
    final newRating = rating + pow(newRd, 2) * g * (s - e);

    return newRating;
  }
}
