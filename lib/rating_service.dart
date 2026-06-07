import 'dart:math';
import 'supabase_service.dart';

class RatingService {
  final SupabaseService _supabaseService;
  
  // Glicko-2 constants
  static const double _defaultRating = 1500;
  static const double _defaultRd = 350;
  static const double _defaultVolatility = 0.06;
  static const double _tau = 0.5; // volatility parameter
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

    // Get last updated time for inactivity calculation
    final whiteLastUpdated = whiteRatingData?['last_updated_at'] != null 
        ? DateTime.parse(whiteRatingData!['last_updated_at'] as String)
        : DateTime.now();
    final blackLastUpdated = blackRatingData?['last_updated_at'] != null
        ? DateTime.parse(blackRatingData!['last_updated_at'] as String)
        : DateTime.now();

    // Apply inactivity RD increase
    final whiteRdAfterInactivity = _applyInactivity(whiteRd, whiteLastUpdated);
    final blackRdAfterInactivity = _applyInactivity(blackRd, blackLastUpdated);

    // Calculate expected scores
    final expectedWhite = _expectedScore(whiteRating, blackRating, whiteRdAfterInactivity);
    final expectedBlack = _expectedScore(blackRating, whiteRating, blackRdAfterInactivity);

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

    // Calculate new ratings using full Glicko-2
    final whiteResult = _calculateNewRating(
      rating: whiteRating,
      rd: whiteRdAfterInactivity,
      volatility: whiteVolatility,
      expectedScore: expectedWhite,
      actualScore: actualWhite,
      opponentRating: blackRating,
      opponentRd: blackRdAfterInactivity,
    );
    final blackResult = _calculateNewRating(
      rating: blackRating,
      rd: blackRdAfterInactivity,
      volatility: blackVolatility,
      expectedScore: expectedBlack,
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

  /// Apply inactivity RD increase
  double _applyInactivity(double rd, DateTime lastUpdated) {
    final daysSinceUpdate = DateTime.now().difference(lastUpdated).inDays;
    if (daysSinceUpdate <= 0) return rd;
    
    // RD increases with inactivity: c = sqrt(rd^2 + c^2) where c is based on time
    // Standard formula: new_rd = min(350, sqrt(rd^2 + (c * days)^2))
    // where c is typically around 20-30 per period
    final c = 20.0; // RD increase constant per day
    final newRd = sqrt(pow(rd, 2) + pow(c * daysSinceUpdate, 2));
    
    // Cap RD at 350 (Glicko-2 standard)
    return newRd > 350 ? 350 : newRd;
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

  /// Calculate new rating using full Glicko-2 algorithm with iterative volatility
  Map<String, double> _calculateNewRating({
    required double rating,
    required double rd,
    required double volatility,
    required double expectedScore,
    required double actualScore,
    required double opponentRating,
    required double opponentRd,
  }) {
    final g = _gFactor(opponentRd);
    final e = _expectedScore(rating, opponentRating, rd);
    final s = actualScore;

    // Step 1: Compute variance
    final variance = 1.0 / (pow(g, 2) * e * (1.0 - e));

    // Step 2: Compute delta
    final delta = variance * g * (s - e);

    // Step 3: Compute new volatility (iterative process)
    final newVolatility = _computeNewVolatility(
      volatility: volatility,
      delta: delta,
      variance: variance,
      rd: rd,
    );

    // Step 4: Compute new RD
    final newRd = sqrt(pow(rd, 2) + pow(newVolatility, 2));

    // Step 5: Compute new rating
    final newRating = rating + pow(newRd, 2) * g * (s - e);

    return {
      'rating': newRating,
      'rd': newRd,
      'volatility': newVolatility,
    };
  }

  /// Compute new volatility using iterative process (Glicko-2 step 3)
  double _computeNewVolatility({
    required double volatility,
    required double delta,
    required double variance,
    required double rd,
  }) {
    double a = log(pow(volatility, 2));
    double newVolatility = volatility;
    
    // Iterative process to find new volatility
    for (int i = 0; i < 100; i++) { // max 100 iterations
      final x = a + i * _tau;
      
      if (x < a - _tau || x > a + _tau) continue;
      
      final d1 = _computeD1(x, delta, variance, volatility, rd);
      final d2 = _computeD2(x, delta, variance, volatility, rd);
      
      if (d2 == 0) break;
      
      final xNew = x - d1 / d2;
      
      if ((xNew - x).abs() < _epsilon) {
        newVolatility = exp(xNew / 2);
        break;
      }
      
      if (xNew < a - _tau) {
        newVolatility = exp((a - _tau) / 2);
        break;
      }
      
      if (xNew > a + _tau) {
        newVolatility = exp((a + _tau) / 2);
        break;
      }
    }
    
    return newVolatility;
  }

  /// Compute D1 for volatility iteration
  double _computeD1(double x, double delta, double variance, double volatility, double rd) {
    final expX = exp(x);
    final d1 = (expX * (pow(delta, 2) - pow(rd, 2) - variance - expX)) / 
               (2 * pow(pow(rd, 2) + variance + expX, 2)) - 
               (x - log(pow(volatility, 2))) / pow(_tau, 2);
    return d1;
  }

  /// Compute D2 for volatility iteration
  double _computeD2(double x, double delta, double variance, double volatility, double rd) {
    final expX = exp(x);
    final d2 = (expX * (pow(rd, 2) + variance + expX) * (1 - expX)) / 
               (2 * pow(pow(rd, 2) + variance + expX, 3)) - 
               expX * (pow(delta, 2) - pow(rd, 2) - variance - expX) / 
               (2 * pow(pow(rd, 2) + variance + expX, 2)) - 
               1 / pow(_tau, 2);
    return d2;
  }
}
