import 'dart:math';
import 'supabase_service.dart';

class RatingService {
  final SupabaseService _supabaseService;
  
  // Glicko-2 constants
  static const double _defaultRating = 1500;
  static const double _defaultRd = 350;
  static const double _defaultVolatility = 0.06;

  RatingService(this._supabaseService);

  /// Calculate new ratings after a game using Glicko-2 algorithm
  Future<Map<String, dynamic>> calculateRatings({
    required String whiteId,
    required String blackId,
    required String variantKey,
    required String timeControlType,
    required String result, // 'white', 'black', 'draw'
  }) async {
    // Get current ratings
    final whiteRatingData = await _supabaseService.getRating(whiteId, variantKey, timeControlType);
    final blackRatingData = await _supabaseService.getRating(blackId, variantKey, timeControlType);

    final whiteRating = (whiteRatingData?['rating'] as int? ?? _defaultRating.toInt()).toDouble();
    final blackRating = (blackRatingData?['rating'] as int? ?? _defaultRating.toInt()).toDouble();

    // Get RD and volatility from database or use defaults
    final whiteRd = (whiteRatingData?['rd'] as num? ?? _defaultRd).toDouble();
    final blackRd = (blackRatingData?['rd'] as num? ?? _defaultRd).toDouble();
    final whiteVolatility = (whiteRatingData?['volatility'] as num? ?? _defaultVolatility).toDouble();
    final blackVolatility = (blackRatingData?['volatility'] as num? ?? _defaultVolatility).toDouble();

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
    final whiteResult = _calculateNewRating(
      rating: whiteRating,
      rd: whiteRd,
      volatility: whiteVolatility,
      expectedScore: expectedWhite,
      actualScore: actualWhite,
    );
    final blackResult = _calculateNewRating(
      rating: blackRating,
      rd: blackRd,
      volatility: blackVolatility,
      expectedScore: expectedBlack,
      actualScore: actualBlack,
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

  /// Update ratings in Supabase and record history
  Future<void> updateRatings({
    required String gameId,
    required String whiteId,
    required String blackId,
    required String variantKey,
    required String timeControlType,
    required String result,
  }) async {
    // Calculate new ratings
    final newRatings = await calculateRatings(
      whiteId: whiteId,
      blackId: blackId,
      variantKey: variantKey,
      timeControlType: timeControlType,
      result: result,
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

    // Record rating history
    await _supabaseService.addRatingHistory(
      userId: whiteId,
      gameId: gameId,
      oldRating: oldWhiteRating.toInt(),
      newRating: newRatings['white_rating'] as int,
      variantKey: variantKey,
      timeControlType: timeControlType,
    );

    await _supabaseService.addRatingHistory(
      userId: blackId,
      gameId: gameId,
      oldRating: oldBlackRating.toInt(),
      newRating: newRatings['black_rating'] as int,
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
  Map<String, double> _calculateNewRating({
    required double rating,
    required double rd,
    required double volatility,
    required double expectedScore,
    required double actualScore,
  }) {
    final g = _gFactor(rd);
    final e = expectedScore;
    final s = actualScore;

    // Calculate new volatility (simplified - using current volatility)
    final newVolatility = volatility;

    // Calculate new RD
    final newRd = sqrt(pow(rd, 2) + pow(newVolatility, 2));

    // Calculate new rating
    final newRating = rating + pow(newRd, 2) * g * (s - e);

    return {
      'rating': newRating,
      'rd': newRd,
      'volatility': newVolatility,
    };
  }
}
